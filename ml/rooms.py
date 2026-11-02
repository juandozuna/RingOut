"""Build a pool of PA -> mic feedback paths for training.

Each room is an FIR `h` (PA EQ * acoustic path, 48 kHz, LH taps) plus a loop
delay D (converter latency + flight time) and `g_lim`, the console gain at
which the bypassed loop reaches the stability limit (Nyquist: largest
open-loop magnitude at a zero-phase crossing, same rule as Sim.cpp).

Two kinds, mixed:
  modal    the engine simulator's model (direct path + 4 high-Q modes), so
           the network sees the rooms the C++ sim evaluates it on
  shoebox  image-source RIRs from pyroomacoustics (rooms 4-30 m, RT60
           0.3-1.6 s) plus 0-3 extra resonances for mic/wedge colour

Usage: python rooms.py --count 600 --out ~/ringout-data/rooms.npz
"""
from __future__ import annotations

import argparse
import math
import os
from concurrent.futures import ProcessPoolExecutor
from pathlib import Path

import numpy as np
from scipy.signal import lfilter

FS = 48000
LH = 16384          # 341 ms of path; longer tails matter little for ringing
MIN_DELAY = 160     # >= training chunk (128) so the loop can run block-wise
CAL_FFT = 1 << 20


def rbj(kind: str, f: float, q: float, gain_db: float = 0.0):
    w0 = 2 * math.pi * min(f, FS * 0.49) / FS
    cw, alpha = math.cos(w0), math.sin(w0) / (2 * q)
    if kind == "peak":
        A = 10 ** (gain_db / 40)
        a0 = 1 + alpha / A
        b = [(1 + alpha * A) / a0, -2 * cw / a0, (1 - alpha * A) / a0]
        a = [1, -2 * cw / a0, (1 - alpha / A) / a0]
    elif kind == "hp":
        a0 = 1 + alpha
        b = [(1 + cw) / 2 / a0, -(1 + cw) / a0, (1 + cw) / 2 / a0]
        a = [1, -2 * cw / a0, (1 - alpha) / a0]
    elif kind == "lp":
        a0 = 1 + alpha
        b = [(1 - cw) / 2 / a0, (1 - cw) / a0, (1 - cw) / 2 / a0]
        a = [1, -2 * cw / a0, (1 - alpha) / a0]
    elif kind == "bp":
        a0 = 1 + alpha
        b = [alpha / a0, 0.0, -alpha / a0]
        a = [1, -2 * cw / a0, (1 - alpha) / a0]
    else:
        raise ValueError(kind)
    return np.array(b), np.array(a)


def impulse(n: int = LH) -> np.ndarray:
    x = np.zeros(n)
    x[0] = 1.0
    return x


def pa_eq(rng: np.random.Generator, x: np.ndarray) -> np.ndarray:
    x = lfilter(*rbj("hp", rng.uniform(70, 140), 0.7071), x)
    x = lfilter(*rbj("lp", rng.uniform(7000, 14000), 0.7071), x)
    for _ in range(rng.integers(1, 4)):
        x = lfilter(*rbj("peak", 300 * (12000 / 300) ** rng.uniform(), rng.uniform(0.7, 2.5), rng.uniform(-6, 6)), x)
    return x


def modes(rng: np.random.Generator, count: int, base_gain: float = 1.0) -> np.ndarray:
    y = np.zeros(LH)
    gains = [1.0, rng.uniform(0.6, 0.8), rng.uniform(0.45, 0.65), rng.uniform(0.35, 0.5)]
    for m in range(count):
        f = 200 * (6000 / 200) ** rng.uniform()
        y += base_gain * gains[m % 4] * lfilter(*rbj("bp", f, rng.uniform(40, 120)), impulse())
    return y


def shoebox(rng: np.random.Generator) -> np.ndarray:
    import pyroomacoustics as pra

    dims = np.array([rng.uniform(4, 30), rng.uniform(4, 25), rng.uniform(2.6, 12)])
    rt60 = rng.uniform(0.3, 1.6)
    try:
        absorption, max_order = pra.inverse_sabine(rt60, dims)
    except ValueError:
        absorption, max_order = 0.5, 20
    room = pra.ShoeBox(dims, fs=FS, materials=pra.Material(absorption), max_order=min(max_order, 14))
    spk = dims * rng.uniform(0.15, 0.85, 3)
    spk[2] = rng.uniform(1.5, min(4.0, dims[2] - 0.3))
    for _ in range(50):
        offset = rng.normal(size=3)
        offset[2] *= 0.2
        offset *= rng.uniform(1.5, 10) / np.linalg.norm(offset)
        mic = spk + offset
        mic[2] = rng.uniform(1.2, 1.9)
        if np.all(mic > 0.3) and np.all(mic < dims - 0.3):
            break
    else:
        mic = dims / 2
    room.add_source(spk)
    room.add_microphone(mic)
    room.compute_rir()
    rir = np.asarray(room.rir[0][0], dtype=np.float64)
    # Drop the flight-time lead-in (it goes into D) and fit to LH.
    lead = max(0, int(np.argmax(np.abs(rir) > 0.05 * np.abs(rir).max())) - 8)
    rir = rir[lead:lead + LH]
    out = np.zeros(LH)
    out[:len(rir)] = rir
    out[-2048:] *= np.linspace(1, 0, 2048)
    flight = lead
    return out / (np.abs(out).max() + 1e-9) * 0.25, flight


def stability_limit(h: np.ndarray, delay: int) -> float:
    H = np.fft.rfft(h, CAL_FFT)
    f = np.arange(len(H)) / CAL_FFT * FS
    L = H * np.exp(-2j * np.pi * f / FS * delay)
    band = (f > 40) & (f < FS * 0.45)
    L = L[band]
    cross = (np.sign(L.imag[:-1]) != np.sign(L.imag[1:])) & ((L.real[:-1] + L.real[1:]) > 0)
    mag = np.abs(L)
    if not cross.any():
        return float(mag.max())
    idx = np.nonzero(cross)[0]
    return float(np.maximum(mag[idx], mag[idx + 1]).max())


def make_room(seed: int):
    rng = np.random.default_rng(seed)
    latency = rng.integers(MIN_DELAY, 480)  # 3.3-10 ms of converters + buffers
    if rng.uniform() < 0.45:
        kind = 0
        h = 0.12 * impulse() + modes(rng, 4)
        flight = int(rng.uniform(0, 0.008) * FS)
    else:
        kind = 1
        h, flight = shoebox(rng)
        h = h + modes(rng, int(rng.integers(0, 4)), base_gain=rng.uniform(0.2, 0.6))
    h = pa_eq(rng, h)
    delay = int(min(latency + flight, 1400))
    peak = stability_limit(h, delay)
    return h.astype(np.float32), delay, 1.0 / max(peak, 1e-9), kind


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--count", type=int, default=600)
    ap.add_argument("--out", type=Path, default=Path.home() / "ringout-data/rooms.npz")
    ap.add_argument("--seed", type=int, default=1000)
    args = ap.parse_args()
    with ProcessPoolExecutor(max_workers=os.cpu_count()) as ex:
        rooms = list(ex.map(make_room, range(args.seed, args.seed + args.count), chunksize=4))
    h = np.stack([r[0] for r in rooms])
    np.savez(args.out, h=h, delay=np.array([r[1] for r in rooms]), g_lim=np.array([r[2] for r in rooms]),
             kind=np.array([r[3] for r in rooms]))
    print(f"{len(rooms)} rooms -> {args.out}; delay {np.min([r[1] for r in rooms])}..{np.max([r[1] for r in rooms])}")


if __name__ == "__main__":
    main()

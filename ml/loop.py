"""Closed-loop PA feedback simulation for training (batched, PyTorch).

    mic[t] = clip(voice[t] + noise[t] + G * (h * spk)[t - D])
    spk    = model(mic)            (closed loop, the model's own output)
           | voice                 (teacher-forced rows: an ideal suppressor)

The loop runs in P-sample blocks. D >= P, so each block's feedback only needs
speaker samples from earlier blocks. The FIR h (up to 16384 taps) is applied
with a uniformly partitioned overlap-save convolution.

Generation runs without gradients. Training then re-runs the model over the
whole recorded mic signal in parallel (the model is causal, so this gives the
same output) and fits that output to the clean voice: recursive training with
the feedback path detached.
"""
from __future__ import annotations

import numpy as np
import torch

from model import StreamingTCN, TCN

FS = 48000
P = 128


def soft_clip(x: torch.Tensor) -> torch.Tensor:
    """Converter: linear to 0.5, tanh knee to a 1.0 ceiling (Sim.cpp adcClip)."""
    a = x.abs()
    knee = 0.5 + 0.5 * torch.tanh((a.clamp(max=1e6) - 0.5) * 2.0)
    return torch.where(a <= 0.5, x, torch.sign(x) * knee)


class Rooms:
    def __init__(self, path: str):
        z = np.load(path)
        self.h = torch.from_numpy(z["h"]).float()
        self.delay = torch.from_numpy(z["delay"]).long()
        self.g_lim = torch.from_numpy(z["g_lim"]).float()
        self.n = len(self.h)


def sustained_tones(rng: np.random.Generator, length: int) -> np.ndarray:
    """Held notes: pure sines and harmonic tones with optional vibrato.
    Steady tones are not feedback by themselves; these teach the model to
    leave them alone unless the loop is actually building them up."""
    out = np.zeros(length)
    t = 0
    while t < length:
        dur = int(rng.uniform(0.25, 1.5) * FS)
        gap = int(rng.uniform(0.0, 0.3) * FS)
        n = min(dur, length - t)
        tt = np.arange(n) / FS
        f0 = 80 * (1200 / 80) ** rng.uniform()
        vib = rng.uniform(0, 0.012) * (rng.uniform() < 0.6)
        phase = 2 * np.pi * np.cumsum(f0 * (1 + vib * np.sin(2 * np.pi * rng.uniform(4, 6.5) * tt))) / FS
        harmonics = 1 if rng.uniform() < 0.35 else int(rng.integers(2, 13))
        roll = rng.uniform(0.3, 1.0)
        x = sum(roll ** (k - 1) * np.sin(k * phase + rng.uniform(0, 6.3)) for k in range(1, harmonics + 1)
                if k * f0 < 16000)
        att, rel = int(rng.uniform(0.005, 0.12) * FS), int(rng.uniform(0.02, 0.2) * FS)
        env = np.ones(n)
        env[:min(att, n)] = np.linspace(0, 1, min(att, n))
        if n > rel:
            env[-rel:] *= np.linspace(1, 0, rel)
        x = x * env
        out[t:t + n] = x / (np.sqrt(np.mean(x ** 2)) + 1e-9) * 0.1
        t += n + gap
    return (out * 10 ** (rng.uniform(-14, 4) / 20)).astype(np.float32)


class Voice:
    """Random segments from packed corpora (plus optional synthetic held
    notes) at random level."""

    def __init__(self, paths_weights: list[tuple[str, float]], tones: float = 0.0):
        self.arrays = [np.load(p, mmap_mode="r") for p, _ in paths_weights]
        w = np.array([w for _, w in paths_weights], dtype=np.float64)
        self.w = w / w.sum()
        self.tones = tones

    def sample(self, rng: np.random.Generator, n: int, length: int) -> torch.Tensor:
        out = np.zeros((n, length), np.float32)
        for i in range(n):
            if rng.uniform() < self.tones:
                out[i] = sustained_tones(rng, length)
                continue
            a = self.arrays[rng.choice(len(self.arrays), p=self.w)]
            start = rng.integers(0, len(a) - length)
            seg = np.asarray(a[start:start + length], dtype=np.float32)
            level = 10 ** (rng.uniform(-14, 4) / 20)  # active RMS -34..-16 dBFS
            out[i] = seg * level
        return torch.from_numpy(out)


def partition_spectra(h: torch.Tensor) -> torch.Tensor:
    """h: (B, LH) -> (B, K, P+1) spectra of P-sample partitions, 2P-point FFTs."""
    B, LH = h.shape
    K = LH // P
    parts = h[:, : K * P].reshape(B, K, P)
    return torch.fft.rfft(torch.cat([parts, torch.zeros_like(parts)], dim=2), n=2 * P)


@torch.no_grad()
def simulate(model: TCN | None, voice: torch.Tensor, rooms: Rooms, idx: torch.Tensor, gain_db: torch.Tensor,
             teacher: torch.Tensor, rng: np.random.Generator, noise_db: tuple[float, float] = (-75, -50)):
    """Returns (mic, spk, dry) all (B, T). `teacher` rows play the clean
    voice; `dry` is what the mic would pick up with no feedback at all
    (voice + room noise), the training target."""
    B, T = voice.shape
    assert T % P == 0
    H = partition_spectra(rooms.h[idx])
    K = H.shape[1]
    D = rooms.delay[idx]
    G = (rooms.g_lim[idx] * 10 ** (gain_db / 20)).view(B, 1)

    noise = torch.from_numpy(rng.standard_normal((B, T)).astype(np.float32))
    noise *=torch.from_numpy(10 ** (rng.uniform(*noise_db, (B, 1)) / 20).astype(np.float32))

    stream = StreamingTCN(model, batch=B) if model is not None else None
    maxD = int(D.max())
    spk = torch.zeros(B, maxD + T)  # spk[maxD + t] is the speaker sample at time t
    mic = torch.zeros(B, T)
    fdl = torch.zeros(B, K, P + 1, dtype=torch.complex64)
    prev = torch.zeros(B, P)
    ar = torch.arange(P)
    tf = teacher.view(B, 1)
    for j in range(T // P):
        t0 = j * P
        # Speaker samples that reach the room during this block: spk[t - D].
        cols = (maxD + t0 - D).view(B, 1) + ar.view(1, P)
        v = torch.gather(spk, 1, cols) * G
        X = torch.fft.rfft(torch.cat([prev, v], dim=1), n=2 * P)
        prev = v
        fdl = torch.roll(fdl, 1, dims=1)
        fdl[:, 0] = X
        fb = torch.fft.irfft((fdl * H).sum(1), n=2 * P)[:, P:]
        s = voice[:, t0:t0 + P]
        m = soft_clip(s + noise[:, t0:t0 + P] + fb)
        mic[:, t0:t0 + P] = m
        y = stream.process(m) if stream is not None else m
        out = torch.where(tf, s, soft_clip(y))
        spk[:, maxD + t0:maxD + t0 + P] = out
    return mic, spk[:, maxD:], soft_clip(voice + noise)


def howl_fraction(x: torch.Tensor, ref: torch.Tensor, frame: int = 4800, margin_db: float = 10.0) -> torch.Tensor:
    """Per row: share of 100 ms frames where output exceeds the clean voice by
    margin_db and sits above -30 dBFS (i.e. the loop is ringing)."""
    B, T = x.shape
    n = T // frame
    ex = x[:, : n * frame].reshape(B, n, frame).pow(2).mean(2)
    er = ref[:, : n * frame].reshape(B, n, frame).pow(2).mean(2)
    ring = (10 * torch.log10(ex + 1e-12) > 10 * torch.log10(er + 1e-12) + margin_db) & (ex > 1e-3)
    return ring.float().mean(1)

"""Closed-loop evaluation on held-out rooms (Python side, model alone).

For each validation room: the highest loop gain (dB over the bypass limit)
that stays free of howl, for the bypass and for the model. Also transparency:
SI-SDR of model output vs clean voice with no feedback at all.

Usage: python evaluate.py ~/ringout-data/runs/v1/latest.pt [--rooms 32]
"""
from __future__ import annotations

import argparse
from pathlib import Path

import numpy as np
import torch

from loop import FS, P, Rooms, Voice, howl_fraction, simulate
from model import TCN

DATA = Path.home() / "ringout-data"


def si_sdr(y: torch.Tensor, s: torch.Tensor) -> torch.Tensor:
    a = (y * s).sum(1, keepdim=True) / (s.pow(2).sum(1, keepdim=True) + 1e-9)
    t = a * s
    return 10 * torch.log10(t.pow(2).sum(1) / ((y - t).pow(2).sum(1) + 1e-9))


def margins(model, voice, rooms, n, gains, rng, seconds=4.0):
    T = int(seconds * FS) // P * P
    v = voice.sample(rng, n, T)
    idx = torch.arange(n)
    best = torch.full((n,), float(gains[0]) - 1)
    alive = torch.ones(n, dtype=torch.bool)
    for g in gains:
        _, spk, _ = simulate(model, v, rooms, idx, torch.full((n,), float(g)), torch.zeros(n, dtype=torch.bool), rng)
        ok = howl_fraction(spk[:, FS:], v[:, FS:]) < 0.05
        alive &= ok
        best = torch.where(alive, torch.tensor(float(g)), best)
    return best


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("ckpt", type=Path)
    ap.add_argument("--rooms", type=int, default=32)
    args = ap.parse_args()
    torch.set_num_threads(8)
    model = TCN()
    model.load_state_dict(torch.load(args.ckpt, map_location="cpu")["model"])
    model.eval()
    rooms = Rooms(str(DATA / "rooms_val.npz"))
    corpora = [(str(DATA / "vctk.npy"), 1.0)]
    voice = Voice(corpora)
    gains = [-2, 0, 1, 2, 3, 4, 5, 6, 8, 10, 12]
    n = min(args.rooms, rooms.n)
    base = margins(None, voice, rooms, n, gains, np.random.default_rng(5))
    mod = margins(model, voice, rooms, n, gains, np.random.default_rng(5))
    added = mod - base
    print(f"bypass stable gain median {base.median():.1f} dB; model {mod.median():.1f} dB")
    print(f"added stable gain: median {added.median():.1f} dB, min {added.min():.1f}, max {added.max():.1f}")

    rng = np.random.default_rng(9)
    T = 4 * FS // P * P
    v = voice.sample(rng, 32, T)
    with torch.no_grad():
        y = model(v)
    print(f"transparency (no feedback): SI-SDR median {si_sdr(y, v).median():.1f} dB, "
          f"level change {10 * torch.log10(y.pow(2).mean() / v.pow(2).mean()):.2f} dB")

    t = torch.arange(3 * FS) / FS
    with torch.no_grad():
        for f in (220.0, 1000.0, 3000.0):
            x = (0.1 * torch.sin(2 * torch.pi * f * t)).unsqueeze(0)
            y = model(x)[:, FS:]
            print(f"held {f:.0f} Hz tone at -20 dBFS: {10 * torch.log10(y.pow(2).mean() / x[:, FS:].pow(2).mean()):+.2f} dB")
        quiet = model(torch.randn(1, 2 * FS) * 10 ** (-70 / 20))
        print(f"room noise -70 dBFS in -> out {20 * torch.log10(quiet.pow(2).mean().sqrt()):.1f} dBFS, "
              f"DC {quiet.mean():.2e}")


if __name__ == "__main__":
    main()

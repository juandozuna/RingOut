"""Train the RingOut isolator with on-policy closed-loop data.

Worker processes run the PA loop (loop.py) with the latest weights on CPU and
stream (mic, clean voice, gain, teacher) batches to the trainer, which fits the
model's parallel forward pass on MPS to the clean voice.

Usage: python train.py --steps 6000 --out ~/ringout-data/runs/v1
"""
from __future__ import annotations

import argparse
import json
import math
import os
import time
from pathlib import Path

import numpy as np
import torch
import torch.multiprocessing as mp
import torch.nn.functional as F

from loop import FS, P, Rooms, Voice, howl_fraction, simulate
from model import TCN, param_count

DATA = Path.home() / "ringout-data"


def gain_ceiling(step: int, ramp: int, top: float) -> float:
    return min(top, 0.0 + top * step / max(ramp, 1))


def worker(rank: int, q, args, weights_path: str, step_val):
    torch.set_num_threads(1)
    rng = np.random.default_rng(1000 + rank)
    rooms = Rooms(str(DATA / "rooms.npz"))
    corpora = [(str(DATA / "vctk.npy"), 1.0)]
    if (DATA / "vocalset.npy").exists():
        corpora.append((str(DATA / "vocalset.npy"), args.singing))
    voice = Voice(corpora, tones=args.tones)
    model = TCN()
    model.eval()
    mtime = 0.0
    T = int(args.seconds * FS) // P * P
    while True:
        try:
            m = os.path.getmtime(weights_path)
            if m != mtime:
                model.load_state_dict(torch.load(weights_path, map_location="cpu"))
                mtime = m
        except (FileNotFoundError, RuntimeError, EOFError):
            pass
        B = args.worker_batch
        top = gain_ceiling(step_val.value, args.ramp, args.max_gain)
        gain = torch.from_numpy(rng.uniform(args.min_gain, top, B).astype(np.float32))
        quiet = torch.from_numpy(rng.uniform(size=B) < args.quiet)
        gain[quiet] = -30.0
        teacher = torch.from_numpy(rng.uniform(size=B) < args.teacher)
        idx = torch.from_numpy(rng.integers(0, rooms.n, B))
        v = voice.sample(rng, B, T)
        mic, spk, dry = simulate(model, v, rooms, idx, gain, teacher, rng)
        hf = howl_fraction(spk[:, FS // 2:], v[:, FS // 2:])
        q.put((mic, dry, gain, teacher, hf))


def stft_mag(x: torch.Tensor, n_fft: int) -> torch.Tensor:
    win = torch.hann_window(n_fft, device=x.device)
    return torch.stft(x, n_fft, hop_length=n_fft // 4, window=win, return_complex=True).abs()


def loss_fn(y: torch.Tensor, s: torch.Tensor, mic: torch.Tensor, quiet: torch.Tensor):
    l1 = (y - s).abs().mean()
    # No DC from the correction path, and unity level when there is no loop.
    dc = (y - mic).mean(1).abs().mean()
    ey, es = y.pow(2).mean(1), s.pow(2).mean(1)
    level = ((10 * torch.log10((ey + 1e-9) / (es + 1e-9))).abs() * quiet).sum() / quiet.sum().clamp(min=1)
    spec = 0.0
    excess = 0.0
    for n in (256, 1024, 4096):
        Y, S = stft_mag(y, n), stft_mag(s, n)
        ly, ls = torch.log(Y + 1e-5), torch.log(S + 1e-5)
        sc = torch.linalg.norm(Y - S) / (torch.linalg.norm(S) + 1e-6)
        spec = spec + sc + (ly - ls).abs().mean()
        # Feedback shows up as energy the clean voice does not have.
        excess = excess + F.relu(ly - ls - 0.7).mean()
    total = 10 * l1 + spec / 3 + excess / 3 + 100 * dc + 0.3 * level
    return total, {"l1": l1.item(), "spec": float(spec) / 3, "excess": float(excess) / 3, "dc": dc.item(),
                   "level_db": level.item()}


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--steps", type=int, default=6000)
    ap.add_argument("--out", type=Path, default=DATA / "runs/v1")
    ap.add_argument("--workers", type=int, default=12)
    ap.add_argument("--worker-batch", type=int, default=8)
    ap.add_argument("--batches-per-step", type=int, default=3)
    ap.add_argument("--seconds", type=float, default=1.5)
    ap.add_argument("--lr", type=float, default=1e-3)
    ap.add_argument("--min-gain", type=float, default=-8.0)
    ap.add_argument("--max-gain", type=float, default=9.0)
    ap.add_argument("--ramp", type=int, default=2500)
    ap.add_argument("--teacher", type=float, default=0.25)
    ap.add_argument("--singing", type=float, default=0.35)
    ap.add_argument("--tones", type=float, default=0.15)
    ap.add_argument("--quiet", type=float, default=0.25)
    ap.add_argument("--resume", type=Path)
    args = ap.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)

    dev = torch.device("mps" if torch.backends.mps.is_available() else "cpu")
    model = TCN().to(dev)
    start = 0
    opt = torch.optim.AdamW(model.parameters(), lr=args.lr, weight_decay=1e-4)
    if args.resume:
        ck = torch.load(args.resume, map_location="cpu")
        model.load_state_dict(ck["model"])
        start = ck.get("step", 0)
    print(f"params {param_count(model)} on {dev}", flush=True)

    weights_path = str(args.out / "live_weights.pt")
    torch.save({k: v.cpu() for k, v in model.state_dict().items()}, weights_path)

    ctx = mp.get_context("spawn")
    q = ctx.Queue(maxsize=args.workers * 2)
    step_val = ctx.Value("i", start)
    procs = [ctx.Process(target=worker, args=(r, q, args, weights_path, step_val), daemon=True) for r in range(args.workers)]
    for p in procs:
        p.start()

    log = open(args.out / "log.jsonl", "a")
    t0 = time.time()
    hist: list[tuple[float, float, bool]] = []
    for step in range(start, args.steps):
        lr = args.lr * 0.5 * (1 + math.cos(math.pi * min(1.0, (step - start) / max(1, args.steps - start))))
        lr = max(lr, args.lr * 0.03)
        for g in opt.param_groups:
            g["lr"] = lr
        items = [q.get() for _ in range(args.batches_per_step)]
        mic = torch.cat([i[0] for i in items]).to(dev)
        s = torch.cat([i[1] for i in items]).to(dev)
        for i in items:
            hist.extend(zip(i[2].tolist(), i[4].tolist(), i[3].tolist()))
        model.train()
        quiet = torch.cat([(i[2] < -29).float() for i in items]).to(dev)
        y = model(mic)
        loss, parts = loss_fn(y, s, mic, quiet)
        opt.zero_grad(set_to_none=True)
        loss.backward()
        torch.nn.utils.clip_grad_norm_(model.parameters(), 1.0)
        opt.step()
        step_val.value = step + 1

        if (step + 1) % 10 == 0:
            torch.save({k: v.detach().cpu() for k, v in model.state_dict().items()}, weights_path + ".tmp")
            os.replace(weights_path + ".tmp", weights_path)
        if (step + 1) % 50 == 0:
            closed = [(g, h) for g, h, tf in hist if not tf and g > -29]
            buckets = {}
            for lo, hi in [(-8, 0), (0, 3), (3, 6), (6, 9.1)]:
                hs = [h for g, h in closed if lo <= g < hi]
                buckets[f"{lo}..{hi:g}"] = round(float(np.mean(hs)), 3) if hs else None
            rec = {"step": step + 1, "loss": round(loss.item(), 4), **{k: round(v, 4) for k, v in parts.items()},
                   "lr": round(lr, 6), "gain_top": round(gain_ceiling(step + 1, args.ramp, args.max_gain), 2),
                   "howl_by_gain": buckets, "elapsed_min": round((time.time() - t0) / 60, 1)}
            print(json.dumps(rec), flush=True)
            log.write(json.dumps(rec) + "\n")
            log.flush()
            hist.clear()
        if (step + 1) % 500 == 0 or step + 1 == args.steps:
            torch.save({"model": {k: v.cpu() for k, v in model.state_dict().items()}, "step": step + 1,
                        "label": f"ringout-tcn16-s{step + 1}"}, args.out / f"ckpt_{step + 1:05d}.pt")
            torch.save({"model": {k: v.cpu() for k, v in model.state_dict().items()}, "step": step + 1,
                        "label": f"ringout-tcn16-s{step + 1}"}, args.out / "latest.pt")
    for p in procs:
        p.terminate()


if __name__ == "__main__":
    main()

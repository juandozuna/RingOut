"""Pack clean voice into one 48 kHz float16 array per corpus.

  vctk      VCTK 0.92 (CC BY 4.0), FLAC shards from the HF mirror of the
            Edinburgh DataShare release, already 48 kHz
  vocalset  VocalSet 1.1 (CC BY 4.0), 44.1 kHz WAV, resampled to 48 kHz

Leading/trailing silence beyond 150 ms is trimmed; utterances are concatenated
with 50-400 ms gaps so segments contain natural onsets and pauses.

Usage: python corpus.py vctk ~/ringout-data/vctk/*.tar
       python corpus.py vocalset ~/ringout-data/vocalset
"""
from __future__ import annotations

import io
import sys
import tarfile
from pathlib import Path

import numpy as np
import soundfile as sf
from scipy.signal import resample_poly

FS = 48000
OUT = Path.home() / "ringout-data"


def trim(x: np.ndarray) -> np.ndarray:
    if len(x) < FS // 10:
        return x
    frame = 480
    n = len(x) // frame
    e = (x[: n * frame].reshape(n, frame) ** 2).mean(1)
    active = np.nonzero(e > e.max() * 10 ** (-45 / 10))[0]
    if len(active) == 0:
        return x[:0]
    a = max(0, (active[0] - 15) * frame)
    b = min(len(x), (active[-1] + 16) * frame)
    return x[a:b]


def normalise(x: np.ndarray) -> np.ndarray:
    # Active-speech RMS to -20 dBFS; level is randomised again at train time.
    frame = 480
    n = len(x) // frame
    if n == 0:
        return x
    e = (x[: n * frame].reshape(n, frame) ** 2).mean(1)
    act = e[e > e.max() * 1e-3]
    rms = np.sqrt(act.mean()) if len(act) else 1e-3
    return x * (0.1 / max(rms, 1e-5))


def pack(clips, name: str, rng: np.random.Generator) -> None:
    parts = []
    total = 0
    for x in clips:
        x = normalise(trim(x.astype(np.float32)))
        if len(x) < FS // 4:
            continue
        parts.append(x)
        parts.append(np.zeros(int(rng.uniform(0.05, 0.4) * FS), np.float32))
        total += len(x)
    audio = np.clip(np.concatenate(parts), -1, 1).astype(np.float16)
    np.save(OUT / f"{name}.npy", audio)
    print(f"{name}: {len(audio) / FS / 3600:.2f} h ({total / FS / 3600:.2f} h voiced)")


def vctk(tars):
    for t in tars:
        with tarfile.open(t) as tf:
            for m in tf:
                if m.name.endswith(".flac"):
                    x, fs = sf.read(io.BytesIO(tf.extractfile(m).read()), dtype="float32")
                    if x.ndim > 1:
                        x = x.mean(1)
                    if fs != FS:
                        continue
                    yield x


def vocalset(root):
    for p in sorted(Path(root).rglob("*.wav")):
        x, fs = sf.read(p, dtype="float32")
        if x.ndim > 1:
            x = x.mean(1)
        if fs == 44100:
            x = resample_poly(x, 160, 147).astype(np.float32)
        elif fs != FS:
            continue
        yield x


if __name__ == "__main__":
    kind, *paths = sys.argv[1:]
    rng = np.random.default_rng(0)
    if kind == "vctk":
        pack(vctk(paths), "vctk", rng)
    elif kind == "vocalset":
        pack(vocalset(paths[0]), "vocalset", rng)
    else:
        raise SystemExit("usage: corpus.py vctk|vocalset paths")

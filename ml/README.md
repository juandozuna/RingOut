# RingOut neural isolator: training

A small causal network (gated TCN, 17,921 parameters, 42.7 ms receptive field,
zero added latency) trained to remove PA feedback from a mic signal. It runs
inside the C++ engine on the audio thread (`Sources/RingOutEngine/NeuralIsolator.cpp`),
with the weights compiled in from `Sources/RingOutEngine/NeuralWeights.inc`.

Everything here runs locally. The model was trained on an M4 Max (MPS for the
gradient step, 12 CPU worker processes for the closed-loop simulation) in about
two hours of wall time.

## Data (all CC BY 4.0, commercial use allowed with attribution)

| Set | What | Used |
|---|---|---|
| [VCTK 0.92](https://datashare.ed.ac.uk/handle/10283/3443) (Yamagishi, Veaux, MacDonald, University of Edinburgh) | 48 kHz read speech, 110 speakers | 4 of 13 shards from the HF mirror `badayvedat/VCTK`, 30 h (28 h voiced) |
| [VocalSet 1.1](https://zenodo.org/records/1442513) (Wilkins, Seetharaman, Wahl, Pardo) | Singing: 20 singers, techniques incl. vibrato, straight tone, belt | 8.8 h, resampled 44.1 → 48 kHz |
| Rooms | Generated, no download: 45 % the engine simulator's modal rooms, 55 % image-source shoebox rooms (pyroomacoustics, 4–30 m, RT60 0.3–1.6 s) plus extra resonances, random PA EQ, 3–29 ms loop delay | 800 train, 64 held out |

DAPS (listed in the PRD) was not used: its licence is non-commercial
(see `research/neural-feedback-suppression.md`).

## Pipeline

```sh
uv venv --python 3.12 ~/ringout-data/.venv && source ~/ringout-data/.venv/bin/activate
uv pip install torch numpy scipy soundfile pyroomacoustics

python rooms.py --count 800                                   # train rooms
python rooms.py --count 64 --seed 900000 --out ~/ringout-data/rooms_val.npz
python corpus.py vctk ~/ringout-data/vctk/train-0*.tar        # -> ~/ringout-data/vctk.npy
python corpus.py vocalset ~/ringout-data/vocalset             # -> ~/ringout-data/vocalset.npy

python train.py --steps 3000 --ramp 3500 --out ~/ringout-data/runs/v1   # stage 1, speech
python train.py --resume ~/ringout-data/runs/v1/ckpt_03000.pt --steps 9000 --ramp 3500 \
    --lr 7e-4 --tones 0 --quiet 0.12 --singing 0.35 --out ~/ringout-data/runs/v3   # stage 2, + singing
python evaluate.py ~/ringout-data/runs/v3/latest.pt           # Python-side closed loop check
python export.py ~/ringout-data/runs/v3/latest.pt             # -> Sources/RingOutEngine/NeuralWeights.inc
swift test -c release                                         # parity, margins, transparency
```

| File | Role |
|---|---|
| `model.py` | The network (source of truth) and `StreamingTCN`, the block-by-block reference the C++ port matches |
| `loop.py` | Batched closed-loop PA simulation: mic = voice + noise + G·(h ∗ speaker)[t−D], partitioned FFT convolution, soft-clipping converter |
| `train.py` | On-policy recursive training: workers run the loop with the latest weights, the trainer fits the model's parallel forward pass to the feedback-free mic signal |
| `rooms.py`, `corpus.py` | Room pool and voice packing |
| `evaluate.py` | Added stable gain on held-out rooms, transparency on clean voice, held tones, silence |
| `export.py` | Weights + a parity vector into the C++ header |

**Training objective.** L1 + multi-resolution STFT (256/1024/4096) against the
mic signal with no feedback, plus a penalty on spectral energy above it (the
ring), a DC penalty on the correction and a level penalty on rows with no loop.
Loop gain is drawn from −8 dB up to a ceiling that ramps to +9 dB over the
bypass stability limit. 25 % of rows are teacher-forced (the speaker plays the
clean voice), 12 % have no loop at all.

## Results (shipped model: `ringout-tcn16-v3s6000`, v3 step 6000)

In the engine (C++ simulated room, notch bank running, Strength 0.8, seeds 1–6,
highest loop gain over the bypass limit with < 2 % howl, test capped at 12 dB):

| Isolator | Speech median / min | Singing median / min |
|---|---|---|
| DSP stand-in | 9.5 / 6 dB | 0 / 0 dB |
| **Neural (default)** | **11.5 / 10 dB** | **11.5 / 8 dB** |
| Neural + DSP | 11.5 / 9 dB | 11 / 8 dB |

Transparency with no feedback (network alone, held-out clips): SI-SDR 41 dB on
VCTK, 43 dB on VocalSet, 0.0 dB median level change, silence stays below
−69 dBFS. C++ vs PyTorch max error 2e-7. Compute ~19 µs per 32-frame block
per channel (M4 Max, release).

**On its own the network does not hold a loop.** In the Python closed loop on
32 held-out rooms, with no notch bank and no Strength mix, it adds 0 dB median
(0–2 dB) over bypass, for modal and shoebox rooms alike. Its gains come from
working behind the notch bank: the notches take the main rings, the network
removes the residual, especially on sustained singing where the detector holds
back on purpose. Earlier checkpoints were stronger alone (+4 dB at v1 step
1500) but coloured voice by 2–5 dB.

## What was tried and dropped

- **Speech only (v1).** Good suppression, but it learned "steady tone = feedback":
  −4 to −6 dB on held tones, −4.5 dB on singing, a DC offset at −51 dBFS.
- **Synthetic held tones + strong transparency terms (v2).** Transparent, but it
  stopped suppressing feedback (0 dB added gain): a settled howl and a held note
  look the same to a mic-only model.
- **Gating the network on the detector's confidence.** Kept speech transparent,
  but the detector is deliberately blind to held sung notes, so singing margin
  fell to a median of 0–6 dB. Dropped in favour of a silence-only gate.

## Known limits

- A pure, perfectly steady sine is turned down by about 6 dB once it has
  lasted ~50 ms (it is indistinguishable from a ring). Real voice and singing
  pass at ~30 dB SI-SDR and 0 dB median level change. Use the DSP isolator for
  sine-wave line checks.
- Trained and evaluated only on simulated loops. No real-room recordings yet.
- 48 kHz only; other rates fall back to the DSP isolator.

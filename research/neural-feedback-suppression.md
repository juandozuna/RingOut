# Neural feedback suppression for RingOut: what it takes

Research date: 2026-11-02. Scope: replace the DSP stand-in in the isolator slot (`Sources/RingOutEngine/ResidualIsolator.cpp`) with a trained, on-device model behind the existing `Isolator` interface (`Sources/RingOutEngine/Isolator.hpp`). Every external claim links to a primary source. **unverified** means I could not confirm it from a primary source. **conflicts with PRD** marks places where the sources disagree with the PRD (`722465e3…md`, "Neural model specification" and "Roadmap"). "Derived" means I worked it out from the repo code or simple arithmetic, not from a source.

> **Update (2026-11-02):** a first model was trained locally from this research and ships in the engine. See `ml/README.md`. Deviations from the plan below: hand-written C++ inference instead of BNNSGraph (no streaming-attribute risk; ~30–60 µs per 32-frame block per channel on an M4 Max), a smaller TCN (18k params, 43 ms receptive field), and no detector conditioning (gating on detector confidence cost singing margin). Everything is still measured on simulated loops only.

## Bottom line

1. **The runtime exists and fits our architecture.** BNNSGraph is a C API in Accelerate on iPadOS 18+ ([BNNSGraphContextExecute availability](https://developer.apple.com/documentation/accelerate/bnnsgraphcontextexecute(_:_:_:_:_:_:).md)). The header wraps itself in `extern "C"`, so the C++ engine can call it directly. Apple's own demo runs it inside a C++ AudioUnit DSP kernel ([WWDC24 10211](https://developer.apple.com/videos/play/wwdc2024/10211/)). It does not allocate on execute if you supply the workspace and the outputs ([same doc](https://developer.apple.com/documentation/accelerate/bnnsgraphcontextexecute(_:_:_:_:_:_:).md)). Conv history can live in Core ML state tensors with a ring-buffer "streaming" context ([BNNSGraphContextMakeStreaming](https://developer.apple.com/documentation/accelerate/bnnsgraphcontextmakestreaming(_:_:_:_:).md)).
2. **The PRD's DAFx26 benchmark is real and its 14 % number checks out.** But it was measured on a macOS M3 at a 128-sample buffer. Nobody has published BNNSGraph tail latency at 32 samples or on iPadOS ([DAFx26 paper 16](https://dafx.de/paper-archive/2026/papers/DAFx26_paper_16.pdf)). If the ~0.38 ms p99 tail is a fixed cost rather than proportional to the buffer, **two instances in 0.67 ms are not guaranteed**. Measure this first, on a real M4 iPad, with a dummy model.
3. **No published neural howling-suppression model runs sample-aligned with zero latency.** Every AHS/AFC paper I found uses STFT frames, with 4–10 ms of algorithmic latency, mostly at 16 kHz ([Zhang 2023](https://arxiv.org/abs/2309.16048), [L3C-DeepMFC](https://www.isca-archive.org/interspeech_2025/hao25_interspeech.pdf), [Voit & Doclo 2026](https://arxiv.org/html/2606.03832v1)). The PRD's causal time-domain TCN is plausible but unproven for this task. Expect a research phase, not just engineering.
4. **Recursive (closed-loop) training is the part of the literature that transfers.** Train first on teacher-forced (open-loop) mixtures, then fine-tune inside a simulated loop, with an early cut-off when the loop starts howling. All three groups found this necessary ([Zhang 2023](https://arxiv.org/abs/2309.16048), [L3C-DeepMFC](https://www.isca-archive.org/interspeech_2025/hao25_interspeech.pdf), [Voit & Doclo](https://arxiv.org/html/2606.03832v1)).
5. **Data is feasible but has to be curated by license.** Usable for commercial work: VCTK (CC BY 4.0, 48 kHz), LibriTTS, MLS Spanish, VocalSet, BUT ReverbDB, OpenSLR 26/28. **Not usable** without a separate licence: DAPS, EARS, GTSinger. The PRD lists DAPS (**conflicts with PRD**). Large-venue 48 kHz RIRs (churches, ballrooms) basically have to be measured or simulated by us.
6. **One structural cap found in our own code.** At the default Strength 0.8, the dry path passes 12–14 dB below the wet path (`Channel.cpp` lines 190–203). No isolator, however good, can add much more than ~12–14 dB of stable gain at the default setting. The current DSP already gets 9.5 dB median in the sim (README). The model's win has to come from voice quality at equal gain, or from higher Strength.
7. **Rough cost to a first shippable model:** about 4–7 months of one ML+DSP engineer, a few hundred to ~1,000 cloud GPU-hours (very roughly $1–4k, my estimate), an M4 iPad Pro, the $99/yr [Apple Developer Program](https://developer.apple.com/programs/whats-included/), and a physical PA/mic rig for held-out tests.

## Step-by-step plan

| # | Step | What | Effort (my estimate) | Hardware / accounts |
|---|---|---|---|---|
| 0 | **Runtime spike first** | Random-weight TCN of target size in PyTorch → coremltools → `.mlmodelc` → `BnnsGraphIsolator` → measure p50/p99/p99.9 for 2 channels × 32 samples on device, with UI and USB audio running. Go/no-go gate. | 1–2 weeks | M4 iPad Pro, Mac with Xcode, Apple Developer Program ($99/yr) |
| 1 | Data | License-clean corpora at 48 kHz (VCTK, DNS fullband permissive subsets, VocalSet, own recordings), RIRs (BUT, SLR26/28, pyroomacoustics synthetic, own church/ballroom measurements), noise. Python loop simulator that matches `Sim.cpp` (loop delay 2–25 ms, PA EQ, gain near the stability limit). | 3–5 weeks + recording sessions | ~1 TB disk; measurement mic, sweep tooling; venue access |
| 2 | Train in PyTorch | Stage A: teacher-forced open-loop training (multi-resolution STFT + L1 + ring-band penalty). Stage B: recursive closed-loop fine-tune, initialised from A, with howl cut-off. Ablate size, receptive field, reference input, FiLM side vector. | 6–10 weeks | 1–2 datacenter GPUs (A100/H100 class) or a rented equivalent; ~300–1000 GPU-h across ablations |
| 3 | Export | `torch.jit.trace` (not `torch.export`, see §1.3) → coremltools 9 `mlprogram`, iOS18+ target, conv history as `ct.StateType`, precision decided by ablation. Parity test of PyTorch vs BNNS on fixed vectors. | 1–2 weeks | Mac |
| 4 | `BnnsGraphIsolator : Isolator` | `prepare()`: compile, streaming context, workspace = max over all n ≤ maxFrames, preallocated I/O. `process()`: bind pointers, execute, NaN/peak guard, fall back to `ResidualIsolator` on failure. Preload speech+singing graphs so `setPreset()` only switches. | 2–3 weeks | Mac, iPad |
| 5 | Benchmark on device | RTSan on macOS build, `mach_absolute_time` histograms on iPad under contention, thermal soak, both presets, all buffer sizes 32–256. | 1–2 weeks | M4 iPad Pro (also an M5 if supported), USB interface |
| 6 | Closed-loop evaluation | Sim gain sweep → added stable gain; SI-SDR/PESQ/STOI at fixed gain margins; howling rate; physical rig at 1–3 m; ABX/MUSHRA listening tests vs the current DSP chain. | 3–4 weeks, repeat per model | PA speaker, vocal mics, interface, room; 10–20 listeners |

Steps 0 and 1 can run in parallel. Step 0 is the cheapest way to kill the project if the 32-sample budget does not hold.

---

## 1. Apple on-device runtime: BNNSGraph

### 1.1 What it is and how a model gets there

- BNNSGraph takes a whole Core ML model graph, not individual layers. The workflow: `.mlpackage` → Xcode compiles it to `.mlmodelc` → `BNNSGraphCompileFromFile` → `BNNSGraphContextMake` → `BNNSGraphContextExecute` ([WWDC24 10211](https://developer.apple.com/videos/play/wwdc2024/10211/)).
- Real-time guidance from the same session: compile on a background thread at startup; use `BNNSGraphCompileOptionsSetTargetSingleThread(options, true)` (the default is multi-threaded); preallocate a page-aligned workspace from `BNNSGraphContextGetWorkspaceSize`; use `BNNSGraphArgumentTypePointer` to pass audio buffers directly; use one context per thread ([WWDC24 10211](https://developer.apple.com/videos/play/wwdc2024/10211/)).
- Apple's own demo puts the BNNSGraph calls inside the **C++ DSP kernel header** of an Audio Unit ([WWDC24 10211](https://developer.apple.com/videos/play/wwdc2024/10211/)). That is the same shape as our engine.
- Graph optimisations happen automatically: fusion, copy elision, weight repacking. Apple says "on average at least 2x faster than previous BNNS primitives" ([WWDC24 10211](https://developer.apple.com/videos/play/wwdc2024/10211/)).
- WWDC25 added `BNNSGraphBuilder`, a Swift API for writing graphs directly. It is still recommended for audio and latency-sensitive work, and FP16 is described as "much faster" for the demo graph ([WWDC25 276](https://developer.apple.com/videos/play/wwdc2025/276/)). The builder is shown only in Swift. For a trained PyTorch model the file-based path is the one to use ([WWDC25 276](https://developer.apple.com/videos/play/wwdc2025/276/)).

### 1.2 Real-time safety: what is documented

- `BNNSGraphContextExecute` does not allocate if (a) the workspace is non-null, (b) BNNS could bound all tensors beforehand, (c) the arguments carry no new shape information, and (d) you provide all output storage ([Apple doc](https://developer.apple.com/documentation/accelerate/bnnsgraphcontextexecute(_:_:_:_:_:_:).md)). Unallocated outputs get allocated for you, which is the trap to avoid.
- An independent RealtimeSanitizer run (`-fsanitize=realtime`, `[[clang::nonblocking]]`) found zero violations over 100 invocations on macOS. The authors stress that this is not a proof for all configurations ([DAFx26 §3.3](https://dafx.de/paper-archive/2026/papers/DAFx26_paper_16.pdf)).
- The iOS 27 SDK header (`Accelerate.framework/.../BNNS/bnns_graph.h`, read locally) adds two caveats:
  - Workspace size "is not monotonic with any dynamic size". The workspace for the maximum size may not cover smaller sizes. **Implication:** in `prepare()`, call `SetBatchSize(n)` + `GetWorkspaceSize` for every n in 1…maxFrames and keep the maximum.
  - `SetDynamicShapes` may change the required workspace. Whether calling `BNNSGraphContextSetBatchSize` on the audio thread when n changes is allocation-free is **unverified**. The WWDC demo does call it per render ([WWDC24 10211](https://developer.apple.com/videos/play/wwdc2024/10211/)). Safest design: run the isolator on a fixed internal block (the engine already sub-blocks; `Sim.cpp` uses 32) and verify with RTSan.
- The FP16 path has a debugging check for "infinities when 16-bit accumulators overflow" ([WWDC24 10211](https://developer.apple.com/videos/play/wwdc2024/10211/)). A howling input can reach full scale, so overflow handling has to be tested (see Risks).

### 1.3 State for a causal TCN (the PRD's "InOut tensors")

- Core ML states need the iOS18/macOS15 target and the `mlprogram` type. You declare them in PyTorch with `register_buffer` and convert with `ct.StateType(...)`. Apple's guide uses `torch.jit.trace` ([coremltools stateful models](https://apple.github.io/coremltools/docs-guides/source/stateful-models.html)).
- `BNNSGraphContextMakeStreaming` allocates **ring-buffer-backed memory for every Core ML state** of the function. Apple names "dilations on convolution layers" in audio as the use case. It removes copies for the pattern `output_state = concat(input_state, x)` and advances the ring by the size of `x` after each execute ([Apple doc](https://developer.apple.com/documentation/accelerate/bnnsgraphcontextmakestreaming(_:_:_:_:).md)). For dynamic shapes, `BNNSGraphContextSetStreamingAdvanceCount` (iOS 18.4+) sets the advance per call. Streaming "do[es] not support models that require different advancement amounts for different states" ([Apple doc](https://developer.apple.com/documentation/accelerate/bnnsgraphcontextsetstreamingadvancecount(_:_:).md)). A pure TCN advances every layer by n, which is fine. A TCN plus GRU state (which is replaced, not advanced) may not fit this mode: **unverified**.
- Two documented gotchas in streaming mode:
  - The model's MIL function has to carry an attribute dictionary `BNNSOptions = { 'StateMode': 'Streaming' }` ([Apple doc](https://developer.apple.com/documentation/accelerate/bnnsgraphcontextmakestreaming(_:_:_:_:).md)). I found **no public coremltools API** that emits this attribute. Expect to post-process the MIL text in the `.mlpackage`: **unverified**.
  - Streaming contexts **ignore user pointers for inputs and outputs** and point them at internal ring memory ([Apple doc](https://developer.apple.com/documentation/accelerate/bnnsgraphcontextmakestreaming(_:_:_:_:).md)). So `process()` copies n samples in and out. That is trivial at n = 32.
- DAFx26 says BNNSGraph supports state "natively through CoreML state tensors declared as InOut arguments" ([DAFx26 §1](https://dafx.de/paper-archive/2026/papers/DAFx26_paper_16.pdf)). This matches the PRD's wording.
- Fallback if streaming mode fails: explicit state in/out tensors that we keep ourselves. Derived cost: a gated TCN with 24 channels, kernel 3, two stacks of dilations 1…512 holds ≈ 24·2·2·1023 ≈ 98k floats (≈ 393 KB fp32) per instance. Copying that every 32-sample call is ≈ 590 MB/s per instance, which is not free. Streaming mode is worth the effort.

### 1.4 Export path

- `torch.jit.trace` is "the recommended way" to convert. `torch.export` is **beta** ([coremltools PyTorch workflow](https://apple.github.io/coremltools/docs-guides/source/convert-pytorch-workflow.html)). Release 8.2 reported torch.export at 83 % parity with the trace converter. coremltools 9.0 (10 Nov 2025) adds iOS26 targets, PyTorch 2.7 support, and reading/writing model state ([coremltools releases](https://github.com/apple/coremltools/releases)). The PRD specifies `torch.export`: **conflicts with PRD**. Use jit.trace, and try export only once trace works.
- `mlprogram` defaults to **float16** for everything. `compute_precision=ct.precision.FLOAT32` forces fp32 ([coremltools typed execution](https://apple.github.io/coremltools/docs-guides/source/typed-execution.html)). The PRD's "fp16 weights, fp32 activations" needs per-op mixed precision. Whether BNNSGraph honours that mix: **unverified**.
- The PRD's "bit-equivalence … within 1e-4" against PyTorch cannot hold if the graph runs in fp16 (fp16 epsilon is ~1e-3). Use an SNR/SI-SDR threshold between PyTorch and BNNS outputs instead, or test the fp32 build: **conflicts with PRD**.
- Argument order in the `.mlmodelc` can differ from the Python source. Look positions up with `BNNSGraphGetArgumentPosition` ([WWDC24 10211](https://developer.apple.com/videos/play/wwdc2024/10211/)). Outputs come before inputs (local SDK header).

### 1.5 Sketch of `BnnsGraphIsolator` against our seam

This follows `Isolator.hpp`. Every API name is from the [WWDC24 session](https://developer.apple.com/videos/play/wwdc2024/10211/), the [Apple docs](https://developer.apple.com/documentation/accelerate/bnnsgraphcontextmakestreaming(_:_:_:_:).md), or the local header.

- **prepare(fs, maxFrames)** (may allocate):
  - Refuse if fs ≠ the model rate, or resample outside the isolator.
  - `BNNSGraphCompileFromFile(path, NULL, opts)` with `SetTargetSingleThread(true)`, once per preset model (speech, singing).
  - `BNNSGraphContextMakeStreaming` per channel.
  - `SetArgumentType(Pointer)`.
  - Workspace = max over n of `GetWorkspaceSize`, page-aligned.
  - Preallocate argument arrays and a 16-float side-vector buffer.
  - Run a warm-up execute.
- **process(x, n, side)** (RT):
  - Pack `SideVector` (8 freq + 8 confidence values) into the conditioning tensor.
  - Copy x into the context's input.
  - `BNNSGraphContextExecute`.
  - Check the return code and finiteness/peak. On failure, run `ResidualIsolator` for this block and flag a re-init to a non-RT thread.
  - Copy the output back into x.
- **setPreset()**: `Channel::applyParams` calls it alongside `det_.setPreset`. Assume it runs on the audio thread, so it may only switch a pointer between two preloaded contexts and crossfade (derived from `Channel.cpp:77–78`).
- **reset()**: re-initialising state memory has to be a memset of known buffers. Do not rebuild the context on the RT thread.
- **Plumbing gap**: the model file lives in the app bundle, but the engine is a SwiftPM C++ target. It needs a C API entry (for example a model-path setter before `ro_engine_prepare`). That is a design change, not made here.

---

## 2. Alternatives

| Option | Status | Notes |
|---|---|---|
| **RTNeural** | BSD-3-Clause ([repo](https://github.com/jatinchowdhury18/RTNeural)) | Dense, GRU, LSTM, Conv1D/2D, BatchNorm, PReLU/tanh/sigmoid. Eigen, xsimd, and STL backends. Weights load from JSON; PyTorch helpers exist ([repo](https://github.com/jatinchowdhury18/RTNeural)). Conv1D takes a `dilation` argument and keeps a per-layer ring state (`RTNeural/conv1d/conv1d.h`). The README makes no formal real-time guarantee and does not mention iOS. On M3, TCN-Large under Core Audio hit **158.5 % p99 with 355 xruns at 128 samples**, against BNNSGraph's 13.7 % ([DAFx26 Table 5](https://dafx.de/paper-archive/2026/papers/DAFx26_paper_16.pdf)). BNNSGraph's lead over RTNeural-XSIMD for TCN-Large shrinks to **3× at 32 samples** ([DAFx26 §4.1](https://dafx.de/paper-archive/2026/papers/DAFx26_paper_16.pdf)). The PRD's "RTNeural fallback, one channel at 64 samples" is therefore optimistic for a ~94k-param TCN. Treat it as a reduced-size-model fallback. |
| **ONNX Runtime** | — | Not real-time safe in DAFx26's classification. Its MLAS kernels did not use AMX on Apple Silicon ([DAFx26 §1, Table 2](https://dafx.de/paper-archive/2026/papers/DAFx26_paper_16.pdf)). Only usable through a worker thread, which adds at least one buffer of latency ([DAFx26](https://dafx.de/paper-archive/2026/papers/DAFx26_paper_16.pdf), anira discussion). That breaks "zero added latency". |
| **Core ML runtime / ANE / GPU** | — | GPU round trips can exceed small-buffer deadlines, and "current consumer NPU APIs … do not expose a callback-safe path" ([DAFx26 §1](https://dafx.de/paper-archive/2026/papers/DAFx26_paper_16.pdf)). An iOS demo paper rejects Metal and Core ML/ANE for per-block audio at 256 samples because of dispatch latency ([Sato & Silverstein 2026](https://arxiv.org/abs/2607.10086)). Agrees with PRD. |
| **Hand-written conv (vDSP/BLAS/NEON)** | — | Possible, and the most controllable. But a dense 22k-param WaveNet in a custom C++ engine was not real-time on an iPhone 16 Pro at 256 samples. It needed 90 % pruning to reach RTF ≈ 0.6 ([Sato & Silverstein 2026](https://arxiv.org/abs/2607.10086)). LibTorch reaches AMX only indirectly through Accelerate BLAS ([DAFx26](https://dafx.de/paper-archive/2026/papers/DAFx26_paper_16.pdf)). Hand-rolling only makes sense as a reduced-size fallback. |

**Recommendation:** BNNSGraph primary. A smaller RTNeural or hand-written model is the fallback, plus the existing `ResidualIsolator` as the last resort. This agrees with the PRD, apart from the size of the fallback model.

---

## 3. Neural howling-suppression literature

| Work | Model | Domain / latency | Data | Loop sim | Reported |
|---|---|---|---|---|---|
| Deep AHS, ICASSP 2023 ([arXiv 2302.09252](https://arxiv.org/abs/2302.09252)) | Attention RNN on engineered features | STFT frames | — | Teacher forcing turns the problem into separation | Prevents howling instead of detecting it |
| Hybrid AHS ([arXiv 2305.02583](https://arxiv.org/abs/2305.02583)) | Kalman filter + self-attentive RNN | STFT | simulated + real recordings | Teacher-forced, frozen at inference | Beats baselines offline and streaming |
| Recursive training, Zhang et al. 2023 ([arXiv 2309.16048](https://arxiv.org/abs/2309.16048)) | 2×300 LSTM, **1.54 M params**, complex ratio mask; NN-only and NN+Kalman | **STFT 8 ms frame / 4 ms hop**; uses the loudspeaker reference R as input | AISHELL-2 (16 kHz), 10k image-method RIR pairs, RT60 0–0.6 s | **System delay 150–250 ms, G 1–3** | At G=3: SDR 2.11 dB (hybrid) vs −33.2 dB no AHS; PESQ 2.13 vs HybridAHS 1.95. Needed howl detection (stop when amplitude exceeds threshold for 100 samples) and pre-trained init to avoid NaNs. "Paper in submission". |
| NN-augmented Kalman ([arXiv 2309.16049](https://arxiv.org/abs/2309.16049)) | NN refines reference + Kalman covariances | STFT 8 ms, 50 % shift, 16 kHz | AISHELL-2 | delay 0.15–0.25 s | +4.94 dB SDR, +0.09 PESQ at G=3 over the next-best |
| Meta multichannel AFC, Interspeech 2025 ([arXiv 2505.15914](https://arxiv.org/abs/2505.15914)) | CRN, **684k params**, 82 M MAC/s | frequency domain, frame size not stated | DNS clean speech, 4k simulated rooms, measured glasses feedback paths | delay 5–30 ms train, 2.5–32.5 ms robustness | Teacher forcing kept PESQ > 4 at 50 dB gain. **In-a-loop training was unstable** for them; hybrid + MCWF had the best PESQ ([HTML v2](https://arxiv.org/html/2505.15914v2)) |
| L3C-DeepMFC, Interspeech 2025 ([PDF](https://www.isca-archive.org/interspeech_2025/hao25_interspeech.pdf)) | Full/sub-band RNN, **0.31 M params, 0.43 GMAC/s** | T-F, 20 ms window / 2 ms hop, modified OLA, **4 ms algorithmic latency**, 24 kHz | AISHELL-3, DNS noise | Pretrain on marginal feedback, then closed-loop fine-tune at higher gain | Stable at gain margins where AFC fails; frame shift drives complexity up "exponentially" |
| Voit & Doclo, arXiv June 2026 ([HTML](https://arxiv.org/html/2606.03832v1)) | DNN estimating a 64-tap feedback filter | 16 kHz, 128-pt frames, hop 63 | LibriSpeech, measured hearing-aid paths | In-the-loop, two stages (stable gains then wider range) | In-the-loop wins at high gain (ECLG −0.7 vs +4.1 dB for open-loop) |

Takeaways for RingOut:

- **Latency (conflicts with PRD's assumption that the literature backs a zero-latency design):** every model above is frame-based with ≥ 4 ms algorithmic latency. I found **no published sample-aligned, zero-latency neural AHS model**. Very-low-latency STFT enhancement down to 2 ms exists and beat Conv-TasNet at equal compute ([Wang et al. 2022](https://arxiv.org/abs/2204.09911)). That shows time-domain is not automatically better. The PRD's TCN choice is reasonable for zero latency, but its suppression quality is **unverified**.
- **Delay range mismatch:** Zhang et al. train with 150–250 ms loop delays ([2309.16048 §4.1](https://arxiv.org/abs/2309.16048)). Live PA loops are 2–25 ms (PRD; `Sim.cpp` uses 3–12 ms). The Meta work (2.5–32.5 ms) is the closest match ([2505.15914](https://arxiv.org/html/2505.15914v2)).
- **Reference input:** the Zhang models take the loudspeaker signal R as an input ([2309.16048 §3.2.3](https://arxiv.org/abs/2309.16048)). RingOut knows its own past output exactly, up to the console gain and PA EQ after it. Feeding the model its previous output as a second input channel costs little and matches the literature. This extends the PRD, which only feeds the post-notch signal plus the side vector.
- **Closed-loop training is necessary and fragile.** It improved high-gain results for Zhang, L3C, and Voit & Doclo, but Meta could not stabilise it ([2505.15914 HTML](https://arxiv.org/html/2505.15914v2)). Budget for that instability: pre-trained init, howl cut-off, curriculum on gain.
- **Commercial reference: Alpha Labs De-Feedback.** Claims "zero latency" in the plugin, 4.9 ms round trip at a 16-sample buffer on its NUC, and training on "many terabytes" of data. It documents its limits: mic closer than ~6 ft to the PA, input must be > 50 % direct sound, "ringy" artifacts at high gain, not linear phase, can damage instruments ([product page/FAQ](https://www.alphalabsaudio.com/defeedback/)). Its architecture is not disclosed.

---

## 4. Training data

### 4.1 Clean voice (48 kHz is the constraint)

| Corpus | License | Rate / size | Use |
|---|---|---|---|
| VCTK 0.92 | CC BY 4.0 ([license_text.txt](https://datashare.ed.ac.uk/bitstream/handle/10283/3443/license_text.txt)) | 48 kHz, 110 speakers ([DataShare](https://datashare.ed.ac.uk/handle/10283/3443)) | core fullband speech |
| DNS Challenge fullband | per-subset licenses. LibriVox = public domain, VocalSet CC BY 4.0, VCTK ODC-By, AudioSet CC BY 4.0, Freesound CC0, **DEMAND CC BY-SA 3.0**, **PTDB-TUG ODbL** ([repo](https://github.com/microsoft/DNS-Challenge)) | ~827 GB clean incl. 65 GB Spanish ([repo](https://github.com/microsoft/DNS-Challenge)) | volume, Spanish, noise. Keep a per-file license manifest |
| LibriTTS | CC BY 4.0, ~585 h, **24 kHz** ([OpenSLR 60](https://www.openslr.org/60/)) | band-limited | pretraining only |
| MLS (incl. Spanish) | CC BY 4.0 ([OpenSLR 94](https://www.openslr.org/94/)) | LibriVox audiobooks | Spanish coverage. Bandwidth below 48 kHz fullband: unverified per file |
| VocalSet | CC BY 4.0, 10.1 h, 20 pro singers ([Zenodo](https://zenodo.org/records/1193957)) | — | singing (thin) |
| **DAPS** | **CC BY-NC 4.0** ([Zenodo](https://zenodo.org/record/4660670)) | — | **not commercial: conflicts with PRD** (the PRD lists it) |
| **EARS** | **CC-NC 4.0**, 100 h, 48 kHz anechoic ([repo](https://github.com/facebookresearch/ears_dataset)) | — | research only |
| **GTSinger** | **CC BY-NC-SA 4.0** ([dataset_license.md](https://github.com/GTSinger/GTSinger/blob/main/dataset_license.md)), 80.6 h singing, 48 kHz ([repo](https://github.com/GTSinger/GTSinger)) | — | research only |

Conclusion: commercially clean singing data is scarce (VocalSet's 10 h). The PRD's own risk #4 is confirmed. The "≥ 100 h singing" target means in-house recording or licensed data.

### 4.2 Room impulse responses and noise

- OpenSLR 28 (real RIRs from RWCP/REVERB/AIR + simulated + MUSAN point noises), Apache 2.0, **16 kHz** ([OpenSLR 28](https://www.openslr.org/28/)). OpenSLR 26 simulated RIRs, Apache 2.0, 16 kHz ([OpenSLR 26](https://www.openslr.org/26/)). At 16 kHz they only cover up to 8 kHz, so they cannot carry 48 kHz training on their own.
- BUT ReverbDB: CC BY 4.0, 9 rooms (offices, stairs, conference and lecture rooms up to ~2,700 m³), ~2,000+ RIRs measured with exponential sine sweeps ([BUT](https://speech.fit.vut.cz/software/but-speech-fit-reverb-database)). No churches or clubs.
- MIT IR Survey: 271 IRs of everyday spaces, no license stated on the page ([MIT](https://mcdermottlab.mit.edu/Reverb/IR_Survey.html)). Licence **unverified**, so don't ship-train on it without asking.
- OpenAIR (York) has large spaces. Its license page could not be fetched (expired certificate): **unverified**.
- Synthetic: pyroomacoustics (MIT license, [repo](https://github.com/LCAV/pyroomacoustics)) for image-method RIRs at 48 kHz. Zhang et al. and Meta both trained on image-method RIRs ([2309.16048](https://arxiv.org/abs/2309.16048), [2505.15914](https://arxiv.org/html/2505.15914v2)).
- The PRD's "500+ measured church/ballroom/club IRs" requires our own measurement campaign. No public source covers it.

### 4.3 Simulating the PA loop

- Loop model: mic = voice ∗ h_voice + PA(out delayed by Δ) ∗ h_PA + noise, with PA = console gain × random EQ. That is the construction in Zhang et al. (their eq. 1, Δ = system delay, G = gain; [2309.16048](https://arxiv.org/abs/2309.16048)) and in our `Sim.cpp`. `Sim.cpp` already calibrates 0 dB loop gain to the bypass stability limit (largest |L(ω)| at a phase-zero crossing), uses 3–12 ms delay, random PA peaking EQ, and four room modes (read from `Sim.cpp`).
- Using `Sim.cpp` as is: its talker is synthetic (a glottal pulse train through formants, `Talker.hpp`), its room is four biquad modes rather than an RIR, and it has no API for injecting arbitrary audio. That makes it good for **closed-loop evaluation of the real C++ engine with the real BNNS model**, but not a training-data generator. Training needs a differentiable PyTorch port with real voice and RIRs, plus the same calibration logic so "gain margin" means the same thing in both.
- Closed-loop training mechanics (derived): the output at time t only feeds back after Δ ≥ 2 ms (≥ 96 samples at 48 kHz). The recursive simulation can therefore advance in chunks of ≤ Δ samples, with the TCN running one chunk at a time and keeping state. This is the same "frame-by-frame closed loop" as Zhang's Algorithm 1 ([2309.16048](https://arxiv.org/abs/2309.16048)). It is roughly 500 sequential steps per second of audio, which is why stage B costs several times stage A.

---

## 5. Real-time budget

### 5.1 What is actually published (DAFx26, verified)

- The paper exists: "Real-time neural audio on Apple Silicon: benchmarking inference frameworks under realistic DAW contention", Balasubramaniam, Ramachandran, Timoney, Maynooth University, DAFx26 ([PDF](https://dafx.de/paper-archive/2026/papers/DAFx26_paper_16.pdf)). Benchmark code is GPL-3.0 ([repo](https://github.com/dharanipathirk/neural-audio-bench)).
- Setup: MacBook Air **M3**, macOS 26.4, Tracktion Engine, BlackHole virtual driver, mono, 48 kHz ([§3](https://dafx.de/paper-archive/2026/papers/DAFx26_paper_16.pdf)).
- TCN-Large is C=48, L=10, dilations 1–512, **93,745 params**, PReLU and residual connections ([Table 1](https://dafx.de/paper-archive/2026/papers/DAFx26_paper_16.pdf)). It is not the gated WaveNet the PRD specifies.
- BNNSGraph TCN-Large at a **128-sample** buffer: isolated RTF 0.022; Core Audio p99 13.7 % at zero contention and **14.3 % at 36 contention tracks**, zero xruns; never above 20 % p99 for large models ([Tables 4–5, §4.2](https://dafx.de/paper-archive/2026/papers/DAFx26_paper_16.pdf)). The PRD's "p99 14 % of a 128-sample deadline on an M3 under heavy contention" is **confirmed**.
- Instance scaling at 128 samples: p99 of one instance is 4.0 % at N=1, 11.7 % at N=2, 27.1 % at N=16 ([Table 6](https://dafx.de/paper-archive/2026/papers/DAFx26_paper_16.pdf)).
- Contention tests ran only at 64–512 samples. 32 samples appears only in the isolated sweep ([§3.4–3.5](https://dafx.de/paper-archive/2026/papers/DAFx26_paper_16.pdf)). The paper says macOS is "the only platform where BNNSGraph is available". That is wrong: Apple lists iPadOS 18+ ([Apple doc](https://developer.apple.com/documentation/accelerate/bnnsgraphcontextexecute(_:_:_:_:_:_:).md)). The paper only means it tested macOS.
- Limitations the authors list: one M3 chip, virtual driver, thermal state not logged, memory not measured ([§5.1](https://dafx.de/paper-archive/2026/papers/DAFx26_paper_16.pdf)).

### 5.2 Is "2 instances in 32 samples" feasible? (honest read)

- Budget: 32/48000 = 0.667 ms. The PRD wants ≤ 15 % per instance (≈ 0.10 ms) and < 40 % total in phase 0.
- Derived from DAFx26: 14.3 % of 2.667 ms ≈ **0.38 ms p99** for one TCN-Large call at 128 samples. If that tail is mostly fixed per-call overhead and scheduler jitter, a 32-sample call has a similar absolute p99. That is ≈ 57 % of the budget per instance, so **two would not fit**. If the cost scales with samples, it is ≈ 0.095 ms per instance and fits the PRD target. The data cannot tell these apart. The paper's own point that BNNSGraph's advantage shrinks at small buffers (3× at 32 vs 25× at 1024) suggests per-call overhead matters ([§4.1](https://dafx.de/paper-archive/2026/papers/DAFx26_paper_16.pdf)). **The PRD's claim that "this size class meets [the 32-sample target] on M4" is unverified.**
- Arithmetic (derived): a ~94k-param conv net costs roughly 94k MAC per output sample, so 2 × 48k × 94k ≈ 9 GMAC/s. Raw throughput is not the problem. Dispatch overhead and tail latency are.
- The M4 has a matrix unit like the M3's AMX. DAFx26 notes that ARM SME standardises a similar unit and that "different M-series generations have different … matrix-unit implementations" ([DAFx26](https://dafx.de/paper-archive/2026/papers/DAFx26_paper_16.pdf)). M4 numbers have to be measured.
- Sample-by-sample vs block: BNNSGraph is designed for one call per buffer with dynamic shapes. DAFx26 ran TCN/WaveNet "buffer-at-a-time via a single BNNSGraphContextExecute call" ([§3.2](https://dafx.de/paper-archive/2026/papers/DAFx26_paper_16.pdf)). A per-sample BNNS call would multiply the dispatch overhead by 32. Process whole blocks, with state carried by streaming ring buffers (§1.3). Zero added latency is preserved because a causal TCN computes y[t] from x[≤t] within the same block.
- Mitigations if it doesn't fit:
  - Shrink the model (the DAFx TCN-Medium is 33.6k params).
  - Run the isolator at 64 samples while the detector and notches stay at 32. This adds latency, so it conflicts with "zero added latency".
  - Use one instance for both channels with batch = 2 (one execute call; **unverified** that batching helps here).
  - Fall back to 64-sample host buffers. The README's watchdog already steps up buffers on overload.

---

## 6. Validation

- **Added stable gain (ASG) / maximum stable gain (MSG)** is the primary metric in feedback control. MSG is the largest gain at which the closed loop stays stable, and ASG is the increase over the uncontrolled system ([van Waterschoot & Moonen 2011, Proc. IEEE review, report version](https://ftp.esat.kuleuven.be/pub/sista/vanwaterschoot/reports/08-13.pdf)). L3C-DeepMFC reports results against "gain margin" (MSG / current gain) ([L3C](https://www.isca-archive.org/interspeech_2025/hao25_interspeech.pdf)). Voit & Doclo use ECLG and ASG ([HTML](https://arxiv.org/html/2606.03832v1)).
  - In our sim: sweep `ro_sim_set_loop_gain_db` upward per seed until the output stays above a howl threshold. ASG = last stable dB. Report median/min over ≥ 16 seeds, the same protocol as the README's 9.5 dB median.
- **Quality at fixed gain margin** (−12…0 dB):
  - SI-SDR/SDR. Zhang et al. emphasise SDR because PESQ is scale-insensitive ([2309.16048 §4.2](https://arxiv.org/abs/2309.16048)).
  - WB-PESQ, which only works at a 16 kHz bandwidth ([L3C §5](https://www.isca-archive.org/interspeech_2025/hao25_interspeech.pdf)), and STOI.
  - Peak-to-threshold / howling-frame rate as in Meta's PTPR ([2505.15914](https://arxiv.org/html/2505.15914v2)).
  - For 48 kHz singing, PESQ is not meaningful. Use listening tests.
- **Listening tests:** ABX for transparency on clean voice (the PRD gate is ABX ≤ 60 %) and MUSHRA-style ratings for artefacts near the stability edge. Standard references are ITU-R BS.1116 / BS.1534 (not fetched here).
- **Closed-loop is mandatory.** Open-loop scores on teacher-forced mixtures overestimate real behaviour. That is the core finding of the recursive-training papers ([2309.16048](https://arxiv.org/abs/2309.16048), [2606.03832](https://arxiv.org/html/2606.03832v1)). Test order: PyTorch loop sim → C++ engine + BNNS model inside `Sim.cpp` (bit-for-bit what ships) → physical rig at 1, 2, 3 m (De-Feedback documents trouble under ~6 ft, so report that cell; [Alpha Labs](https://www.alphalabsaudio.com/defeedback/)).
- **Baseline:** compare against the current notch + `ResidualIsolator` chain, not against bypass. The PRD's phase-0 gate "beats bypass by ≥ 3 dB on the synthetic loop" is already exceeded by the DSP chain (9.5 dB median, README). A meaningful gate is "≥ DSP ASG at better SI-SDR/ABX".
- **Strength cap (derived from `Channel.cpp:190–203`):** out = (1−s)·k·dry + s·k·wet with k = 1/√(u² + s² + 2suρ). At s = 0.8 the dry gain is 0.2 (ρ = 1, −14 dB) to 0.24 (ρ = 0, −12.3 dB). Dry is un-notched and un-isolated, so the loop through the dry path alone limits ASG to roughly 12–14 dB at default Strength, however good the model is. Evaluate at s = 1.0 too, or revisit how dry is mixed while a ring is active.
- **Real-time validation:** RTSan (`-fsanitize=realtime`, `[[clang::nonblocking]]`) on the macOS build, as DAFx26 did ([§3.3](https://dafx.de/paper-archive/2026/papers/DAFx26_paper_16.pdf)). Whether RTSan runs for iOS device targets: **unverified**. On the iPad itself, collect `mach_absolute_time` p99/p99.9 per call under UI rendering and USB audio. PRD risk #2 (iPadOS scheduler differs from macOS) remains open.

---

## Open risks

1. **32-sample tail latency on iPadOS** (§5.2). No published data, and the arithmetic says it could fail. Run step 0 before anything else.
2. **No precedent for zero-latency neural AHS.** All published systems are frame-based with ≥ 4 ms latency (§3). Quality could fall short of what the notch + DSP chain already does.
3. **Closed-loop training instability.** Meta abandoned in-a-loop training ([2505.15914](https://arxiv.org/html/2505.15914v2)), and Zhang needed workarounds ([2309.16048](https://arxiv.org/abs/2309.16048)).
4. **Streaming state tooling.** The `BNNSOptions StateMode=Streaming` attribute has no documented coremltools path, and mixing GRU state with conv streaming is unclear (§1.3).
5. **FP16 overflow on howling-level input** ([WWDC24 10211](https://developer.apple.com/videos/play/wwdc2024/10211/) mentions 16-bit accumulator overflow). Possible mitigations: normalise input gain inside the graph, test with full-scale sines, or keep accumulation in fp32.
6. **License hygiene.** DAPS/EARS/GTSinger are non-commercial, and DEMAND/PTDB-TUG are share-alike. Track licenses per file.
7. **Singing and Spanish coverage** is thin in commercially licensed data (§4.1). In-house recording is needed.
8. **The Strength mix caps ASG** (§6). The model cannot show its value at the default Strength without a mix change.
9. **Phase and Strength crossfade.** A non-linear-phase isolator output mixed with dry can comb-filter. `Channel.cpp` already measures dry/wet correlation, but the model should be checked for constant group delay on clean voice.
10. **Model file plumbing.** It needs a C-API change to pass the bundle path to the engine, plus preloaded preset models, because `setPreset` runs on the audio thread (§1.5).
11. **Single-paper evidence for BNNSGraph.** DAFx26 calls itself "the first independent academic evaluation" ([DAFx26](https://dafx.de/paper-archive/2026/papers/DAFx26_paper_16.pdf)), with one chip and a virtual driver.

## Sources

Apple / tools
- [WWDC24 10211 Support real-time ML inference on the CPU](https://developer.apple.com/videos/play/wwdc2024/10211/)
- [WWDC25 276 What's new in BNNS Graph](https://developer.apple.com/videos/play/wwdc2025/276/)
- [BNNSGraphContextExecute](https://developer.apple.com/documentation/accelerate/bnnsgraphcontextexecute(_:_:_:_:_:_:).md)
- [BNNSGraphContextMakeStreaming](https://developer.apple.com/documentation/accelerate/bnnsgraphcontextmakestreaming(_:_:_:_:).md)
- [BNNSGraphContextSetStreamingAdvanceCount](https://developer.apple.com/documentation/accelerate/bnnsgraphcontextsetstreamingadvancecount(_:_:).md)
- Local SDK header: `iPhoneOS27.0.sdk/.../vecLib.framework/Headers/BNNS/bnns_graph.h`
- [coremltools: Stateful models](https://apple.github.io/coremltools/docs-guides/source/stateful-models.html)
- [coremltools: PyTorch conversion workflow](https://apple.github.io/coremltools/docs-guides/source/convert-pytorch-workflow.html)
- [coremltools: Typed execution](https://apple.github.io/coremltools/docs-guides/source/typed-execution.html)
- [coremltools releases](https://github.com/apple/coremltools/releases)
- [Apple Developer Program](https://developer.apple.com/programs/whats-included/)
- [RTNeural](https://github.com/jatinchowdhury18/RTNeural)
- [pyroomacoustics](https://github.com/LCAV/pyroomacoustics)

Benchmarks
- [DAFx26 paper 16: Real-time neural audio on Apple Silicon](https://dafx.de/paper-archive/2026/papers/DAFx26_paper_16.pdf)
- [neural-audio-bench repo](https://github.com/dharanipathirk/neural-audio-bench)
- [Sato & Silverstein, WaveNet pruning for iOS, arXiv 2607.10086](https://arxiv.org/abs/2607.10086)

Howling / feedback suppression
- [Deep AHS, arXiv 2302.09252](https://arxiv.org/abs/2302.09252)
- [Hybrid AHS, arXiv 2305.02583](https://arxiv.org/abs/2305.02583)
- [Recursive training, arXiv 2309.16048](https://arxiv.org/abs/2309.16048)
- [NN-augmented Kalman, arXiv 2309.16049](https://arxiv.org/abs/2309.16049)
- [Meta multichannel AFC, arXiv 2505.15914](https://arxiv.org/html/2505.15914v2)
- [L3C-DeepMFC, Interspeech 2025](https://www.isca-archive.org/interspeech_2025/hao25_interspeech.pdf)
- [Voit & Doclo, In-the-loop DFC, arXiv 2606.03832](https://arxiv.org/html/2606.03832v1)
- [Wang et al., Very-low-latency STFT SE, arXiv 2204.09911](https://arxiv.org/abs/2204.09911)
- [van Waterschoot & Moonen, Fifty years of acoustic feedback control (report)](https://ftp.esat.kuleuven.be/pub/sista/vanwaterschoot/reports/08-13.pdf)
- [Alpha Labs De-Feedback](https://www.alphalabsaudio.com/defeedback/)

Data
- [VCTK 0.92](https://datashare.ed.ac.uk/handle/10283/3443) ([license](https://datashare.ed.ac.uk/bitstream/handle/10283/3443/license_text.txt))
- [DNS Challenge](https://github.com/microsoft/DNS-Challenge)
- [LibriTTS / OpenSLR 60](https://www.openslr.org/60/)
- [MLS / OpenSLR 94](https://www.openslr.org/94/)
- [VocalSet](https://zenodo.org/records/1193957)
- [DAPS](https://zenodo.org/record/4660670)
- [EARS](https://github.com/facebookresearch/ears_dataset)
- [GTSinger](https://github.com/GTSinger/GTSinger)
- [OpenSLR 28](https://www.openslr.org/28/)
- [OpenSLR 26](https://www.openslr.org/26/)
- [BUT ReverbDB](https://speech.fit.vut.cz/software/but-speech-fit-reverb-database)
- [MIT IR Survey](https://mcdermottlab.mit.edu/Reverb/IR_Survey.html)

Repo files read: `Sources/RingOutEngine/Isolator.hpp`, `ResidualIsolator.cpp`, `Sim.cpp`, `Talker.hpp`, `Channel.cpp`, `FeedbackDetector.hpp`, `README.md`, PRD `722465e3…md`.

<img src="assets/icon.png" width="96" height="96" alt="RingOut icon">

# RingOut

**Two-channel real-time feedback suppression for live vocal mics, on an iPad you already own.**

RingOut turns an M4-or-newer iPad plus a class-compliant USB audio interface into a feedback-suppression insert. It sits between a console insert send and return (or between a mic and the console) and adds no algorithmic latency.

- Landing page: https://juandozuna.github.io/RingOut/
- Status: **V1 in development.** The app, the engine and the setup flow run today. The neural voice isolator from the PRD is not trained yet, so a zero-latency DSP stand-in sits in its slot (see [Limitations](#limitations)).

## What's in the repo

| Path | What it is |
| --- | --- |
| `Sources/RingOutEngine/` | C++20 real-time engine behind a small C API (`include/ringout_engine.h`): DC block, 80 Hz HPF, 1024-pt FFT feedback detector with peak tracking and a logistic classifier, adaptive notch bank (8 auto + 4 fixed, Q≈60), isolator stage, equal-power Strength mix, −0.3 dBFS limiter, meters, spectrum, lock-free parameter/event queues. Also includes a simulated acoustic feedback loop (`ro_sim_*`) for demos and tests. |
| `Tests/RingOutEngineTests/` | Engine tests (`swift test`): bit-exact bypass, zero latency, unity gain, detection speed, false-positive resistance on vibrato vocals, notch lifecycle, synthetic closed-loop stability, performance. |
| `App/` | The iPadOS app (SwiftUI, Swift 6, iPadOS 26+). XcodeGen spec in `App/project.yml`; generated project committed as `App/RingOut.xcodeproj`. |
| `App/RingOut/Audio/RenderGlue.c` | The only non-engine code on the Core Audio I/O thread: RemoteIO in → engine → out, written in C (no Swift, no allocation, no locks), plus Out 2 → In 2 loopback latency measurement. |
| `docs/` | GitHub Pages landing page. |
| `tools/make_icon.swift` | Renders the app icon. |

## The app

Landscape-only, dark, stage-safe. Every screen in the PRD is implemented:

| Screen | Highlights |
| --- | --- |
| S1 Welcome | Hue-style setup ring, "Start setup", import a show file from Files |
| S2 Setup wizard | Connect (live USB interface detection, wrong-route warning, power source) · Wiring (topologies A/B/C, 1 or 2 channels) · Checks (session, requested vs actual buffer, I/O buffer mismatch from accessibility features, reported latency, mains power, direct-monitor confirmation) · Calibrate (signal in the −18 dBFS band, loopback latency, 60 s / 10 min stress test with automatic step-up to the next buffer) · Done (summary, save show file) |
| S3 Live | Two full-height channel strips whose background colour is the channel state (safe / working / ring / bypass), input and output meters with −18/−6 marks, peak hold and clip latch, a live log spectrum with notch markers and ring flash, a 160 pt Strength dial (double-tap = 80 %), Speech / Singing / Custom presets, Bypass, hold-to-mute, status banner (interface, rate, buffer, latency in ms + samples, DSP load, thermal, power, lock) |
| S4 Calibration | Wizard step 4 as a sheet over Live |
| S5 Notch detail | Large spectrum with draggable notches, table with pin/release, ring-out mode that pins up to 4 fixed notches, notch hold and max auto notches |
| S6 Settings | Audio, channels, show files (save / load / duplicate / export / import / iCloud), lock PIN and auto-lock, power and thermal policy, dim booth, license, about |
| S7 Diagnostics | 10-minute graphs (DSP load, overloads, buffer, thermal, battery), filterable event log, JSON + PDF report export |
| S8 Interface disconnected | Output muted within one buffer, recovers automatically with a 200 ms fade-in, "Use a different interface" after 10 s |
| S9 Locked | Meters stay visible, controls blocked, PIN pad, hold 2 s for safety bypass |

Reliability features: render-callback watchdog (switches to bit-exact bypass rather than mute), overload counter with step-up after 5 in a minute, thermal step-up at the next silent gap (input < −50 dBFS for 200 ms) and an offer to step back down, critical thermal forces 128 samples, battery drain projection, screen kept awake while live, background audio.

### Simulated rig

With no interface plugged in (or in the iOS Simulator), turn on **Use simulated rig** in wizard step 1. The engine then runs inside a simulated room: a synthetic talker or singer, a mic, a PA, room modes and a loop delay. A bar under the strips sets each channel's console gain relative to the point where bypass starts ringing. Push it above 0 dB to make the room howl and watch RingOut catch it. Toggle **Listen** to hear the loop.

## Build and run

Requirements: Xcode 26+ (tested with Xcode 27), iPadOS 26 SDK.

```bash
# Engine tests (macOS)
swift test
swift test -c release        # includes the performance test

# App
open App/RingOut.xcodeproj   # scheme RingOut, pick an iPad simulator or a device
# or regenerate the project after editing App/project.yml:
brew install xcodegen && (cd App && xcodegen generate)
```

To run on a real iPad, set your Development Team in the RingOut target. Debug builds unlock Pro (2 channels). Release builds use StoreKit 2 with the product `com.juandozuna.ringout.pro`.

### Verified rig (V1 target)

iPad Pro 11"/13" with M4 or newer · USB-C hub with ≥ 85 W PD pass-through · Focusrite Scarlett 4i4 / 2i2 4th gen or MOTU M4 · 100 W PD brick · a TRS loopback cable from Out 2 to In 2 for latency measurement.

## Limitations

- **Neural isolator.** The PRD's causal TCN running on BNNSGraph needs a trained model, which needs the data pipeline. The engine has the isolator seam, and a causal zero-latency DSP stand-in runs there now. The detector and notch bank are complete.
- **iPadOS limits.** iPadOS does not expose USB vendor/product IDs or negotiated USB speed, so interfaces are identified by port name and UID. Accessibility audio features can't be read directly; RingOut infers them from a buffer mismatch.
- **Not implemented yet:** Live Activity, iCloud sync (needs an iCloud-enabled signing team; the toggle stays disabled until then), AUv3, stereo link (V1.x per the PRD).
- The V1 success metrics (≥ 6 dB added gain before feedback, ≤ 6 ms round trip, 4-hour thermal run) are targets. They have to be verified on the physical lab rig described in the PRD.

## License

All rights reserved © 2026 Juan Ozuna.

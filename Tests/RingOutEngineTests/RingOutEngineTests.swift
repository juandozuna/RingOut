import Foundation
import RingOutEngine
import XCTest

final class TransparencyTests: XCTestCase {
    func testStrengthZeroIsBitExactDry() {
        let e = makeEngine { ro_engine_set_param($0, -1, RO_PARAM_STRENGTH, 0) }
        defer { ro_engine_destroy(e) }
        var rng = Lcg(state: 7)
        let speech = simSource(RO_SIM_SPEECH, seed: 2, seconds: 3)
        let x = speech.enumerated().map { $0.element + 0.05 * rng.next() * Float($0.offset % 3) }
        let y = process(e, x, block: 64)
        XCTAssertTrue(zip(x, y).allSatisfy { $0.bitPattern == $1.bitPattern })

        // Switching to 0 at runtime is bit-exact once the 64-sample ramp completes.
        let e2 = makeEngine()
        defer { ro_engine_destroy(e2) }
        _ = process(e2, Array(x[0..<4800]), block: 64)
        ro_engine_set_param(e2, 0, RO_PARAM_STRENGTH, 0)
        let tail = Array(x[4800..<48_000])
        let y2 = process(e2, tail, block: 64)
        XCTAssertTrue(zip(tail[64...], y2[64...]).allSatisfy { $0.bitPattern == $1.bitPattern })
    }

    func testBypassIsBitExactDryAndDetectorKeepsAnalysing() {
        let e = makeEngine { ro_engine_set_param($0, 0, RO_PARAM_BYPASS, 1) }
        defer { ro_engine_destroy(e) }
        let x = growingTone(freq: 1500, seconds: 3)
        let y = process(e, x, block: 128)
        XCTAssertTrue(zip(x, y).allSatisfy { $0.bitPattern == $1.bitPattern })
        XCTAssertTrue(drainEvents(e).contains { $0.type == RO_EVENT_RING_DETECTED }, "detector must keep analysing in bypass")
        XCTAssertEqual(snapshot(e).state, RO_STATE_BYPASS)
    }

    func testZeroLatencyImpulse() {
        let e = makeEngine { ro_engine_set_param($0, 0, RO_PARAM_STRENGTH, 1) }
        defer { ro_engine_destroy(e) }
        var x = [Float](repeating: 0, count: 48_000)
        let at = 24_000 + 37  // mid-block
        x[at] = 0.5
        let y = process(e, x, block: 64)
        let peak = y.indices.max { abs(y[$0]) < abs(y[$1]) }!
        XCTAssertEqual(peak, at, "output impulse must be sample-aligned")
        XCTAssertGreaterThan(abs(y[at]), 0.45)
        XCTAssertTrue(y[..<at].allSatisfy { $0 == 0 }, "nothing may precede the impulse")
    }

    func testUnityLevelOnSpeechAtDefaultStrength() {
        for seed: UInt32 in 1...3 {
            let e = makeEngine()
            defer { ro_engine_destroy(e) }
            let x = simSource(RO_SIM_SPEECH, seed: seed, seconds: 10)
            let y = process(e, x, block: 64)
            let skip = 24_000
            let diff = rmsDb(y[skip...]) - rmsDb(x[skip...])
            print("unity level seed \(seed): \(String(format: "%+.3f", diff)) dB")
            XCTAssertEqual(diff, 0, accuracy: 0.5)
            XCTAssertFalse(drainEvents(e).contains { $0.type == RO_EVENT_RING_DETECTED })
            XCTAssertEqual(snapshot(e).state, RO_STATE_SAFE)
        }
    }
}

final class DetectorTests: XCTestCase {
    func testNotchesGrowingToneWithin40ms() {
        let e = makeEngine()
        defer { ro_engine_destroy(e) }
        let f = 1037.3
        _ = process(e, growingTone(freq: f, seconds: 2), block: 64)
        let ring = drainEvents(e).first { $0.type == RO_EVENT_RING_DETECTED }
        XCTAssertNotNil(ring)
        guard let ring else { return }
        let delay = Double(ring.frame) / fs48k - crossingTime()
        print("growing tone: notch placed \(String(format: "%.1f", delay * 1000)) ms after crossing -60 dBFS, f=\(ring.frequency_hz)")
        XCTAssertLessThanOrEqual(delay, 0.040)
        XCTAssertEqual(Double(ring.frequency_hz), f, accuracy: 1.0)
        XCTAssertEqual(ring.depth_db, -6, accuracy: 0.01)
        XCTAssertGreaterThanOrEqual(ring.confidence, 0.7)
        let s = snapshot(e)
        XCTAssertGreaterThanOrEqual(s.active_auto_notches, 1)
        XCTAssertEqual(Double(s.last_ring_hz), f, accuracy: 1.0)
    }

    func testDeepensWhileRingKeepsGrowing() {
        let e = makeEngine()
        defer { ro_engine_destroy(e) }
        _ = process(e, growingTone(freq: 2200, rateDbPerS: 60, seconds: 2), block: 64)
        let deepened = drainEvents(e).filter { $0.type == RO_EVENT_NOTCH_DEEPENED }
        XCTAssertFalse(deepened.isEmpty)
        XCTAssertEqual(deepened.map(\.depth_db).min()!, -18, accuracy: 0.01, "deepens in 3 dB steps to -18")
        XCTAssertEqual(notches(snapshot(e)).filter(\.active).map(\.depth_db).min()!, -18, accuracy: 0.01)
    }

    func testNoNotchOnVibratoVocal() {
        for seed: UInt32 in 1...4 {
            let e = makeEngine { ro_engine_set_param($0, 0, RO_PARAM_PRESET, Float(RO_PRESET_SINGING.rawValue)) }
            defer { ro_engine_destroy(e) }
            _ = process(e, simSource(RO_SIM_SINGING, seed: seed, seconds: 20), block: 64)
            let rings = drainEvents(e).filter { $0.type == RO_EVENT_RING_DETECTED }
            XCTAssertEqual(rings.count, 0, "seed \(seed): \(rings.map(\.frequency_hz))")
        }
    }

    func testNoNotchOnCleanSpeech() {
        for seed: UInt32 in 1...4 {
            let e = makeEngine()
            defer { ro_engine_destroy(e) }
            _ = process(e, simSource(RO_SIM_SPEECH, seed: seed, seconds: 20), block: 64)
            let rings = drainEvents(e).filter { $0.type == RO_EVENT_RING_DETECTED }
            XCTAssertEqual(rings.count, 0, "seed \(seed): \(rings.map(\.frequency_hz))")
        }
    }

    func testNotchReleasedAfterDecay() {
        let e = makeEngine { ro_engine_set_param($0, 0, RO_PARAM_NOTCH_HOLD_S, 2) }
        defer { ro_engine_destroy(e) }
        let stop = 3.0
        _ = process(e, growingTone(freq: 900, maxDb: -20, seconds: 9, stopAt: stop), block: 64)
        let evs = drainEvents(e)
        XCTAssertTrue(evs.contains { $0.type == RO_EVENT_RING_DETECTED })
        let released = evs.first { $0.type == RO_EVENT_NOTCH_RELEASED }
        XCTAssertNotNil(released)
        if let released {
            let t = Double(released.frame) / fs48k
            // 2 s below max-12 dB, then a 2 s ramp.
            XCTAssertGreaterThan(t, stop + 3.9)
            XCTAssertLessThan(t, stop + 4.5)
            XCTAssertGreaterThan(released.duration_s, 4)
        }
        let s = snapshot(e)
        XCTAssertEqual(s.active_auto_notches, 0, "released notches are removed")
        XCTAssertEqual(s.state, RO_STATE_SAFE)
    }

    func testOscillationGuardWarnsAboveSixNotches() {
        let e = makeEngine()
        defer { ro_engine_destroy(e) }
        let freqs = [610.0, 890.0, 1270.0, 1730.0, 2390.0, 3110.0, 4070.0]
        let n = Int(2.5 * fs48k)
        let tones = freqs.map { growingTone(freq: $0, rateDbPerS: 40, maxDb: -24, seconds: 2.5, noiseAmp: 0) }
        let x = (0..<n).map { i in tones.reduce(Float(0)) { $0 + $1[i] } }
        _ = process(e, x, block: 64)
        let evs = drainEvents(e)
        XCTAssertGreaterThanOrEqual(evs.filter { $0.type == RO_EVENT_RING_DETECTED }.count, 7)
        XCTAssertTrue(evs.contains { $0.type == RO_EVENT_LOOP_GAIN_WARNING })
        let s = snapshot(e)
        XCTAssertTrue(s.loop_gain_warning)
        XCTAssertEqual(s.state, RO_STATE_RING)
    }

    func testRingOutModePinsConfirmedRings() {
        let e = makeEngine { ro_engine_set_param($0, 0, RO_PARAM_RING_OUT_MODE, 1) }
        defer { ro_engine_destroy(e) }
        _ = process(e, growingTone(freq: 1250, rateDbPerS: 60, seconds: 1.5), block: 64)
        let pinned = drainEvents(e).filter { $0.type == RO_EVENT_NOTCH_PINNED }
        XCTAssertEqual(pinned.count, 1)
        let s = snapshot(e)
        XCTAssertEqual(s.active_fixed_notches, 1)
        let fixed = notches(s)[8...].first { $0.active }
        XCTAssertNotNil(fixed)
        XCTAssertEqual(Double(fixed?.frequency_hz ?? 0), 1250, accuracy: 1)
        XCTAssertTrue(fixed?.fixed ?? false)
    }
}

final class CommandTests: XCTestCase {
    func testFixedNotchAddMoveRelease() {
        let e = makeEngine { ro_engine_set_param($0, 0, RO_PARAM_STRENGTH, 1) }
        defer { ro_engine_destroy(e) }
        ro_engine_command(e, 0, RO_CMD_ADD_FIXED_NOTCH, 1000, -12)
        // Broadband noise: the detector leaves it alone, so the response is the fixed notch only.
        var x = noise(seconds: 1.5, rmsDb: -30)
        var y = process(e, x, block: 64)
        var s = snapshot(e)
        var slot = notches(s)[8]
        XCTAssertTrue(slot.active)
        XCTAssertTrue(slot.fixed)
        XCTAssertEqual(slot.frequency_hz, 1000, accuracy: 0.01)
        XCTAssertEqual(slot.depth_db, -12, accuracy: 0.01)
        XCTAssertEqual(s.active_fixed_notches, 1)
        XCTAssertEqual(s.active_auto_notches, 0)
        let span = 24_000..<72_000
        XCTAssertEqual(transferDb(input: x[span], output: y[span], freq: 1000), -12, accuracy: 1.0)
        XCTAssertEqual(transferDb(input: x[span], output: y[span], freq: 1500), 0, accuracy: 0.5)

        ro_engine_command(e, 0, RO_CMD_MOVE_NOTCH, 8, 2000)
        x = noise(seconds: 1.5, rmsDb: -30, seed: 12)
        y = process(e, x, block: 64)
        slot = notches(snapshot(e))[8]
        XCTAssertEqual(slot.frequency_hz, 2000, accuracy: 0.01)
        XCTAssertEqual(transferDb(input: x[span], output: y[span], freq: 1000), 0, accuracy: 0.5)
        XCTAssertEqual(transferDb(input: x[span], output: y[span], freq: 2000), -12, accuracy: 1.0)

        // Fixed notches survive prepare.
        XCTAssertTrue(ro_engine_prepare(e, 96_000, 128, 1))
        s = snapshot(e)
        XCTAssertEqual(s.active_fixed_notches, 1)
        XCTAssertEqual(notches(s)[8].frequency_hz, 2000, accuracy: 0.01)

        ro_engine_command(e, 0, RO_CMD_RELEASE_NOTCH, 8, 0)
        _ = process(e, [Float](repeating: 0, count: 96_000), block: 128)
        s = snapshot(e)
        XCTAssertFalse(notches(s)[8].active)
        XCTAssertEqual(s.active_fixed_notches, 0)
    }

    func testFixedSlotsAreLimitedToFour() {
        let e = makeEngine()
        defer { ro_engine_destroy(e) }
        for i in 0..<6 { ro_engine_command(e, 0, RO_CMD_ADD_FIXED_NOTCH, Float(500 + 300 * i), -9) }
        _ = process(e, [Float](repeating: 0, count: 4800), block: 64)
        XCTAssertEqual(snapshot(e).active_fixed_notches, 4)
    }

    func testPinAndClearAutoNotches() {
        let e = makeEngine()
        defer { ro_engine_destroy(e) }
        _ = process(e, growingTone(freq: 1400, seconds: 1.6), block: 64)
        var s = snapshot(e)
        XCTAssertGreaterThanOrEqual(s.active_auto_notches, 1)
        let autoSlot = notches(s)[..<8].firstIndex { $0.active }!
        _ = drainEvents(e)

        ro_engine_command(e, 0, RO_CMD_PIN_NOTCH, Float(autoSlot), 0)
        _ = process(e, [Float](repeating: 0, count: 480), block: 64)
        XCTAssertTrue(drainEvents(e).contains { $0.type == RO_EVENT_NOTCH_PINNED })
        s = snapshot(e)
        XCTAssertEqual(s.active_fixed_notches, 1)
        XCTAssertEqual(Double(notches(s)[8...].first { $0.active }!.frequency_hz), 1400, accuracy: 1)

        // A fresh auto notch, then clear (once the tone has left the analysis window).
        _ = process(e, growingTone(freq: 2600, seconds: 1.6) + [Float](repeating: 0, count: 4800), block: 64)
        XCTAssertGreaterThanOrEqual(snapshot(e).active_auto_notches, 1)
        ro_engine_command(e, 0, RO_CMD_CLEAR_AUTO_NOTCHES, 0, 0)
        _ = process(e, [Float](repeating: 0, count: 4800), block: 64)
        s = snapshot(e)
        XCTAssertEqual(s.active_auto_notches, 0)
        XCTAssertEqual(s.active_fixed_notches, 1, "clear leaves fixed notches alone")
    }

    func testMuteRampsToSilenceIn5ms() {
        let e = makeEngine()
        defer { ro_engine_destroy(e) }
        let x = fmTone(freq: 440, db: -12, seconds: 0.5)
        _ = process(e, Array(x[0..<4800]), block: 64)
        ro_engine_set_param(e, 0, RO_PARAM_MUTE, 1)
        let y = process(e, Array(x[4800...]), block: 64)
        XCTAssertGreaterThan(abs(y[0..<48].max()!), 0.01, "ramps, not a hard cut")
        XCTAssertTrue(y[240...].allSatisfy { $0 == 0 }, "silent after 5 ms")
        XCTAssertEqual(snapshot(e).state, RO_STATE_BYPASS)
    }

    func testParametersAreScopedPerChannel() {
        let e = makeEngine(channels: 2) { ro_engine_set_param($0, 1, RO_PARAM_BYPASS, 1) }
        defer { ro_engine_destroy(e) }
        let x = growingTone(freq: 1800, seconds: 2)
        let y = processMulti(e, [x, x], block: 64)
        XCTAssertTrue(zip(x, y[1]).allSatisfy { $0.bitPattern == $1.bitPattern })
        XCTAssertFalse(zip(x, y[0]).allSatisfy { $0.bitPattern == $1.bitPattern })
        XCTAssertEqual(snapshot(e, 1).state, RO_STATE_BYPASS)
        XCTAssertNotEqual(snapshot(e, 0).state, RO_STATE_BYPASS)
        XCTAssertTrue(drainEvents(e).contains { $0.channel == 0 && $0.type == RO_EVENT_RING_DETECTED })

        ro_engine_set_param(e, -1, RO_PARAM_BYPASS, 1)
        _ = processMulti(e, [[Float](repeating: 0, count: 960), [Float](repeating: 0, count: 960)], block: 64)
        XCTAssertEqual(snapshot(e, 0).state, RO_STATE_BYPASS)
    }
}

final class SnapshotTests: XCTestCase {
    func testMetersSpectrumAndCounters() {
        let e = makeEngine(maxFrames: 128)
        defer { ro_engine_destroy(e) }
        let x = fmTone(freq: 1000, db: -20, seconds: 1)
        _ = process(e, x, block: 128)
        let s = snapshot(e)
        // Snapshots are published every 5 ms of audio.
        XCTAssertEqual(Double(s.frames_processed), Double(x.count), accuracy: 240 + 128)
        XCTAssertEqual(s.input_peak_db, -20, accuracy: 0.3)
        XCTAssertEqual(s.input_rms_db, -23.01, accuracy: 0.3)
        XCTAssertEqual(s.output_rms_db, -23.01, accuracy: 0.5)
        XCTAssertEqual(s.input_peak_hold_db, -20, accuracy: 0.3)
        XCTAssertFalse(s.input_clip)
        XCTAssertFalse(s.output_clip)
        XCTAssertLessThanOrEqual(s.gain_reduction_db, 0)
        XCTAssertGreaterThan(s.gain_reduction_db, -0.5)
        XCTAssertEqual(s.state, RO_STATE_SAFE)
        XCTAssertEqual(s.last_ring_hz, 0)
        XCTAssertGreaterThan(s.last_ring_age_s, 1000)
        XCTAssertTrue(isFinite(s))

        // Spectrum: 96 log bands 100 Hz..20 kHz; 1 kHz lands in band 96*log(10)/log(200).
        let spec = spectrum(s)
        XCTAssertEqual(spec.count, 96)
        let peakBand = spec.indices.max { spec[$0] < spec[$1] }!
        XCTAssertEqual(peakBand, Int(96 * log(10.0) / log(200.0)), accuracy: 1)
        XCTAssertEqual(spec[peakBand], -20, accuracy: 1.5)
        XCTAssertTrue(spec.allSatisfy { $0 >= -120 && $0 <= 0 })

        XCTAssertGreaterThan(ro_engine_dsp_load(e), 0)

        var out = ro_channel_snapshot()
        XCTAssertFalse(ro_engine_read_snapshot(e, 1, &out), "only channel 0 was prepared")
        XCTAssertFalse(ro_engine_read_snapshot(e, -1, &out))
    }

    func testClipLatchPeakHoldAndReset() {
        let e = makeEngine()
        defer { ro_engine_destroy(e) }
        _ = process(e, fmTone(freq: 300, db: 0, seconds: 0.1), block: 64)
        _ = process(e, fmTone(freq: 300, db: -30, seconds: 1.0), block: 64)
        var s = snapshot(e)
        XCTAssertTrue(s.input_clip, "latched")
        XCTAssertTrue(s.output_clip, "limiter ceiling -0.3 dBFS is above the -0.5 dBFS clip mark")
        XCTAssertGreaterThan(s.input_peak_hold_db, -1, "held for 2 s")
        XCTAssertEqual(s.input_peak_db, -30, accuracy: 0.5)
        _ = process(e, fmTone(freq: 300, db: -30, seconds: 2.0), block: 64)
        s = snapshot(e)
        XCTAssertLessThan(s.input_peak_hold_db, -1, "hold decays after 2 s")
        ro_engine_command(e, 0, RO_CMD_RESET_METERS, 0, 0)
        _ = process(e, fmTone(freq: 300, db: -30, seconds: 0.05), block: 64)
        s = snapshot(e)
        XCTAssertFalse(s.input_clip)
        XCTAssertFalse(s.output_clip)
    }

    func testEventsAndRingState() {
        let e = makeEngine()
        defer { ro_engine_destroy(e) }
        XCTAssertTrue(drainEvents(e).isEmpty)
        _ = process(e, growingTone(freq: 1700, seconds: 1.5), block: 64)
        let evs = drainEvents(e)
        let ring = evs.first { $0.type == RO_EVENT_RING_DETECTED }!
        XCTAssertEqual(ring.channel, 0)
        XCTAssertGreaterThan(ring.frame, 0)
        XCTAssertEqual(Double(ring.frequency_hz), 1700, accuracy: 1)
        XCTAssertTrue(evs.allSatisfy { $0.frame <= UInt64(1.5 * fs48k) })
        XCTAssertTrue(zip(evs, evs.dropFirst()).allSatisfy { $0.frame <= $1.frame }, "FIFO order")
        let s = snapshot(e)
        XCTAssertEqual(s.state, RO_STATE_RING)
        XCTAssertLessThan(s.last_ring_age_s, 2)
        XCTAssertTrue(drainEvents(e).isEmpty, "drained")
    }

    func testMultiTalkerHeuristic() {
        func fraction(_ x: [Float]) -> Double {
            let e = makeEngine()
            defer { ro_engine_destroy(e) }
            var on = 0, total = 0
            var pos = 48_000
            _ = process(e, Array(x[0..<pos]), block: 64)
            while pos + 4800 <= x.count {
                _ = process(e, Array(x[pos..<(pos + 4800)]), block: 64)
                pos += 4800
                total += 1
                if snapshot(e).multi_talker { on += 1 }
            }
            return Double(on) / Double(total)
        }
        for seed: UInt32 in [1, 3, 5] {
            XCTAssertLessThan(fraction(simSource(RO_SIM_SPEECH, seed: seed, seconds: 15)), 0.15, "single talker \(seed)")
        }
        var mixed: [Double] = []
        for seed: UInt32 in [2, 4, 9, 10] {
            let a = simSource(RO_SIM_SPEECH, seed: seed, seconds: 15)
            let b = simSource(RO_SIM_SPEECH, seed: seed + 10, seconds: 15)
            mixed.append(fraction(zip(a, b).map { $0 + $1 }))
        }
        print("multi_talker fraction on two-talker mixes: \(mixed)")
        XCTAssertGreaterThan(mixed.reduce(0, +) / Double(mixed.count), 0.4)
    }

    func testSnapshotReadableBeforePrepare() {
        let e = ro_engine_create()!
        defer { ro_engine_destroy(e) }
        var s = ro_channel_snapshot()
        XCTAssertTrue(ro_engine_read_snapshot(e, 0, &s))
        XCTAssertEqual(s.frames_processed, 0)
        XCTAssertFalse(ro_engine_pop_event(e, nil))
        XCTAssertEqual(ro_engine_dsp_load(e), 0)
    }
}

final class RobustnessTests: XCTestCase {
    func testPrepareAtRatesAndBufferSizes() {
        for rate in [44_100.0, 48_000.0, 96_000.0] {
            for frames in [32, 64, 128, 256] {
                let e = makeEngine(sampleRate: rate, maxFrames: frames)
                defer { ro_engine_destroy(e) }
                let f = 1234.5
                let x = growingTone(freq: f, seconds: 1.5, sampleRate: rate)
                let y = process(e, x, block: frames)
                let ring = drainEvents(e).first { $0.type == RO_EVENT_RING_DETECTED }
                XCTAssertNotNil(ring, "\(rate) Hz / \(frames)")
                if let ring {
                    let delay = Double(ring.frame) / rate - crossingTime()
                    XCTAssertEqual(Double(ring.frequency_hz), f, accuracy: 1.5, "\(rate) Hz / \(frames)")
                    XCTAssertLessThan(delay, 0.050, "\(rate) Hz / \(frames)")
                }
                XCTAssertTrue(y.allSatisfy(\.isFinite))
            }
        }
    }

    func testPrepareRejectsBadArguments() {
        let e = ro_engine_create()!
        defer { ro_engine_destroy(e) }
        XCTAssertFalse(ro_engine_prepare(e, 0, 64, 1))
        XCTAssertFalse(ro_engine_prepare(e, 48_000, 0, 1))
        XCTAssertFalse(ro_engine_prepare(e, 48_000, Int32(RO_MAX_FRAMES) + 1, 1))
        XCTAssertFalse(ro_engine_prepare(e, 48_000, 64, 0))
        XCTAssertFalse(ro_engine_prepare(e, 48_000, 64, 3))
        XCTAssertFalse(ro_engine_prepare(nil, 48_000, 64, 1))
        XCTAssertTrue(ro_engine_prepare(e, 48_000, Int32(RO_MAX_FRAMES), 2))
    }

    func testNoNaNUnderExtremeInput() {
        let ceiling = Float(pow(10, -0.3 / 20)) + 1e-6
        for strength: Float in [0.8, 1.0] {
            let e = makeEngine { ro_engine_set_param($0, 0, RO_PARAM_STRENGTH, strength) }
            defer { ro_engine_destroy(e) }
            var rng = Lcg(state: 3)
            var x: [Float] = []
            x += [Float](repeating: .nan, count: 512)
            x += [Float](repeating: .infinity, count: 300) + [Float](repeating: -.infinity, count: 300)
            x += (0..<4800).map { $0 % 2 == 0 ? 1e30 : -1e30 }
            x += (0..<4800).map { ($0 / 24) % 2 == 0 ? 1e6 : -1e6 }
            x += [Float](repeating: 10, count: 4800)
            x += (0..<48_000).map { _ in 4 * rng.next() }
            x += (0..<4800).map { _ in rng.next() < 0.99 ? 0 : .nan }
            x += [Float.leastNonzeroMagnitude, -Float.leastNonzeroMagnitude, .greatestFiniteMagnitude] + [Float](repeating: 0, count: 2000)
            let y = process(e, x, block: 64)
            XCTAssertTrue(y.allSatisfy(\.isFinite), "strength \(strength)")
            XCTAssertLessThanOrEqual(y.map(abs).max()!, ceiling, "limiter holds -0.3 dBFS")
            XCTAssertTrue(isFinite(snapshot(e)))

            // Recovers to normal operation afterwards.
            let after = process(e, fmTone(freq: 500, db: -20, seconds: 1), block: 64)
            XCTAssertTrue(after.allSatisfy(\.isFinite))
            XCTAssertEqual(rmsDb(after[24_000...]), -23, accuracy: 1.5)
        }
    }
}

final class SimulatedLoopTests: XCTestCase {
    func testSimIsCalibratedToTheBypassStabilityLimit() {
        for seed: UInt32 in 1...3 {
            for (gain, howls) in [(-3.0, false), (2.0, true), (6.0, true)] {
                let sim = ro_sim_create(fs48k, 1, seed)!
                defer { ro_sim_destroy(sim) }
                ro_sim_set_loop_gain_db(sim, 0, Float(gain))
                let y = renderSim(sim, engine: nil, seconds: 10)
                let tail = rmsDb(y[(y.count - 96_000)...])
                XCTAssertTrue(y.allSatisfy(\.isFinite))
                XCTAssertLessThanOrEqual(y.map(abs).max()!, 1.0)
                if howls {
                    XCTAssertGreaterThan(tail, -6, "seed \(seed) bypass at \(gain) dB must howl near the ceiling")
                } else {
                    XCTAssertLessThan(tail, -15, "seed \(seed) bypass at \(gain) dB must be stable")
                }
            }
        }
    }

    func testEngineHoldsLoopAtPlus6dB() {
        var worst = 0.0
        for seed: UInt32 in 1...6 {
            let sim = ro_sim_create(fs48k, 1, seed)!
            let e = makeEngine(maxFrames: 32)
            defer {
                ro_sim_destroy(sim)
                ro_engine_destroy(e)
            }
            ro_sim_set_loop_gain_db(sim, 0, 6)
            let y = renderSim(sim, engine: e, seconds: 25)
            let frac = howlFraction(y, from: 10)
            worst = max(worst, frac)
            XCTAssertTrue(y.allSatisfy(\.isFinite))
            XCTAssertLessThan(frac, 0.02, "seed \(seed): \(frac)")
            XCTAssertLessThan(rmsDb(y[(y.count - 10 * 48_000)...]), -18, "seed \(seed)")
        }
        print("loop +6 dB, strength 0.8: worst howl fraction \(worst)")
    }

    func testMeasuredGainMargin() {
        // For each seed: highest loop gain (dB above the bypass limit) at which
        // the engine at the default 0.8 Strength keeps the loop free of howl.
        var margins: [Double] = []
        for seed: UInt32 in 1...6 {
            var best = 0.0
            for g in stride(from: 1.0, through: 12.0, by: 1.0) {
                let sim = ro_sim_create(fs48k, 1, seed)!
                let e = makeEngine(maxFrames: 32)
                ro_sim_set_loop_gain_db(sim, 0, Float(g))
                let y = renderSim(sim, engine: e, seconds: 20)
                ro_sim_destroy(sim)
                ro_engine_destroy(e)
                if howlFraction(y, from: 8) < 0.02 { best = g } else { break }
            }
            margins.append(best)
        }
        let sorted = margins.sorted()
        let median = (sorted[2] + sorted[3]) / 2
        print("gain-before-feedback margin per seed (dB): \(margins), median \(median), min \(sorted[0])")
        XCTAssertGreaterThanOrEqual(median, 6)
        XCTAssertGreaterThanOrEqual(sorted[0], 6)
    }

    func testSimRendersTwoChannelsAndSilence() {
        let sim = ro_sim_create(fs48k, 2, 9)!
        let e = makeEngine(maxFrames: 64, channels: 2)
        defer {
            ro_sim_destroy(sim)
            ro_engine_destroy(e)
        }
        ro_sim_set_source(sim, 1, RO_SIM_SILENCE)
        let n = 48_000
        var a = [Float](repeating: 0, count: n), b = a
        a.withUnsafeMutableBufferPointer { pa in
            b.withUnsafeMutableBufferPointer { pb in
                var pos = 0
                while pos < n {
                    var ptrs: [UnsafeMutablePointer<Float>?] = [pa.baseAddress! + pos, pb.baseAddress! + pos]
                    ptrs.withUnsafeMutableBufferPointer { ro_sim_render(sim, e, $0.baseAddress, 480) }
                    pos += 480
                }
            }
        }
        XCTAssertGreaterThan(rmsDb(a), -40, "talker present")
        XCTAssertLessThan(rmsDb(b), -60, "room noise only")
        XCTAssertGreaterThan(rmsDb(b), -90)
        XCTAssertEqual(Double(snapshot(e, 1).frames_processed), Double(n), accuracy: 240 + 32)
    }
}

final class PerformanceTests: XCTestCase {
    func testTwoChannels32FramesAt48k() {
        let e = makeEngine(maxFrames: 32, channels: 2)
        defer { ro_engine_destroy(e) }
        let a = simSource(RO_SIM_SPEECH, seed: 3, seconds: 10)
        let b = simSource(RO_SIM_SINGING, seed: 4, seconds: 10)
        let block = 32
        let inA = UnsafeMutablePointer<Float>.allocate(capacity: a.count)
        let inB = UnsafeMutablePointer<Float>.allocate(capacity: b.count)
        let out0 = UnsafeMutablePointer<Float>.allocate(capacity: block)
        let out1 = UnsafeMutablePointer<Float>.allocate(capacity: block)
        defer { [inA, inB, out0, out1].forEach { $0.deallocate() } }
        inA.initialize(from: a, count: a.count)
        inB.initialize(from: b, count: b.count)
        var outs: [UnsafeMutablePointer<Float>?] = [out0, out1]
        var ins: [UnsafePointer<Float>?] = [nil, nil]

        let calls = a.count / block
        var loadSum = 0.0
        var loadMax: Float = 0
        let clock = ContinuousClock()
        var elapsed = Duration.zero
        outs.withUnsafeMutableBufferPointer { op in
            elapsed = clock.measure {
                for k in 0..<calls {
                    ins[0] = UnsafePointer(inA + k * block)
                    ins[1] = UnsafePointer(inB + k * block)
                    ins.withUnsafeMutableBufferPointer { ip in
                        ro_engine_process(e, ip.baseAddress, op.baseAddress, Int32(block))
                    }
                    let l = ro_engine_dsp_load(e)
                    loadSum += Double(l)
                    loadMax = max(loadMax, l)
                }
            }
        }
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) * 1e-18
        let perCall = seconds / Double(calls)
        let period = Double(block) / fs48k
        let fraction = perCall / period
        print(String(format: "perf: 2 ch x 32 frames @48k: %.2f us/call of %.1f us period = %.2f%% (engine-reported avg %.2f%%, max %.1f%%)",
                     perCall * 1e6, period * 1e6, fraction * 100, loadSum / Double(calls) * 100, Double(loadMax) * 100))
        XCTAssertLessThan(fraction, 0.40)
        XCTAssertLessThan(loadSum / Double(calls), 0.40)
    }
}

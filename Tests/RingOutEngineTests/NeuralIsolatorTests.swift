import Foundation
import RingOutEngine
import XCTest

final class NeuralIsolatorTests: XCTestCase {
    func testParityWithPyTorch() {
        let err = ro_neural_selftest()
        let id = String(cString: ro_neural_model_id())
        print(String(format: "neural selftest (%@): max abs error %.3e", id, err))
        XCTAssertFalse(id.isEmpty)
        XCTAssertLessThan(err, 1e-4)
    }

    func testSnapshotReportsActiveIsolator() {
        for (mode, rate, expected) in [(RO_ISOLATOR_NEURAL, 48_000.0, RO_ISOLATOR_NEURAL),
                                       (RO_ISOLATOR_NEURAL_DSP, 48_000.0, RO_ISOLATOR_NEURAL_DSP),
                                       (RO_ISOLATOR_DSP, 48_000.0, RO_ISOLATOR_DSP),
                                       (RO_ISOLATOR_NEURAL, 44_100.0, RO_ISOLATOR_DSP)] {
            let e = makeEngine(sampleRate: rate) { ro_engine_set_param($0, -1, RO_PARAM_ISOLATOR, Float(mode.rawValue)) }
            defer { ro_engine_destroy(e) }
            XCTAssertEqual(snapshot(e).isolator, expected, "mode \(mode.rawValue) at \(rate) Hz")
        }
    }

    func testCausalAndSampleAligned() {
        // Two inputs that agree up to sample k: outputs before k must be bit
        // identical, in every mode, including inside the block that holds k.
        let speech = simSource(RO_SIM_SPEECH, seed: 5, seconds: 1)
        let k = 24_000 + 37
        var other = speech
        for i in k..<other.count { other[i] = 0.3 * sin(Float(i) * 0.37) }
        other[k] = 0.9
        for mode in [RO_ISOLATOR_NEURAL, RO_ISOLATOR_NEURAL_DSP] {
            let configure: (Engine) -> Void = {
                ro_engine_set_param($0, 0, RO_PARAM_STRENGTH, 1)
                ro_engine_set_param($0, 0, RO_PARAM_ISOLATOR, Float(mode.rawValue))
            }
            let e1 = makeEngine(configure: configure), e2 = makeEngine(configure: configure)
            defer {
                ro_engine_destroy(e1)
                ro_engine_destroy(e2)
            }
            let y1 = process(e1, speech, block: 64)
            let y2 = process(e2, other, block: 64)
            XCTAssertTrue(zip(y1[..<k], y2[..<k]).allSatisfy { $0.bitPattern == $1.bitPattern }, "mode \(mode.rawValue)")
            XCTAssertNotEqual(y1[k], y2[k], "mode \(mode.rawValue): the change shows up at k, not later")
            XCTAssertTrue(y1.allSatisfy(\.isFinite) && y2.allSatisfy(\.isFinite))
        }
    }

    func testStrengthZeroStaysBitExactInNeuralModes() {
        for mode in [RO_ISOLATOR_NEURAL, RO_ISOLATOR_NEURAL_DSP] {
            let e = makeEngine {
                ro_engine_set_param($0, -1, RO_PARAM_STRENGTH, 0)
                ro_engine_set_param($0, -1, RO_PARAM_ISOLATOR, Float(mode.rawValue))
            }
            defer { ro_engine_destroy(e) }
            let x = simSource(RO_SIM_SPEECH, seed: 2, seconds: 1)
            let y = process(e, x, block: 64)
            XCTAssertTrue(zip(x, y).allSatisfy { $0.bitPattern == $1.bitPattern }, "mode \(mode.rawValue)")
        }
    }

    func testModeSwitchesAreClickFreeAndFinite() {
        // Each switch cross-fades the stages, so the largest sample-to-sample
        // step around a switch stays within what the modes on either side
        // produce in steady state.
        let e = makeEngine { ro_engine_set_param($0, 0, RO_PARAM_STRENGTH, 1) }
        defer { ro_engine_destroy(e) }
        let modes = [0, 1, 2, 0, 2, 1, 0]
        let seg = 24_000, settle = 4800
        let x = fmTone(freq: 440, db: -20, seconds: Double(modes.count * seg) / fs48k)
        var y: [Float] = []
        for (i, mode) in modes.enumerated() {
            ro_engine_set_param(e, 0, RO_PARAM_ISOLATOR, Float(mode))
            y += process(e, Array(x[(i * seg)..<((i + 1) * seg)]), block: 32)
        }
        XCTAssertTrue(y.allSatisfy(\.isFinite))
        func maxStep(_ r: Range<Int>) -> Float { r.dropFirst().map { abs(y[$0] - y[$0 - 1]) }.max()! }
        for i in 1..<modes.count {
            let b = i * seg
            let around = maxStep((b - 32)..<(b + settle))
            let steady = max(maxStep((b - seg + settle)..<b), maxStep((b + settle)..<(b + seg)))
            print(String(format: "switch %d -> %d: max step %.4f, steady %.4f", modes[i - 1], modes[i], around, steady))
            XCTAssertLessThan(around, 1.25 * steady, "switch \(modes[i - 1]) -> \(modes[i])")
        }
    }

    func testRecoversFromExtremeInput() {
        let e = makeEngine {
            ro_engine_set_param($0, 0, RO_PARAM_STRENGTH, 1)
            ro_engine_set_param($0, 0, RO_PARAM_ISOLATOR, Float(RO_ISOLATOR_NEURAL.rawValue))
        }
        defer { ro_engine_destroy(e) }
        var x = [Float](repeating: .nan, count: 300) + [Float](repeating: 30, count: 4800)
        x += (0..<4800).map { $0 % 2 == 0 ? 1e30 : -1e30 }
        let y = process(e, x, block: 64)
        XCTAssertTrue(y.allSatisfy(\.isFinite))
        let after = process(e, fmTone(freq: 500, db: -20, seconds: 1), block: 64)
        XCTAssertTrue(after.allSatisfy(\.isFinite))
        XCTAssertLessThan(after.map(abs).max()!, 1)
    }

    func testTimingTwoChannels32Frames() {
        let us = timePerBlockPerChannel(mode: RO_ISOLATOR_NEURAL)
        let usDsp = timePerBlockPerChannel(mode: RO_ISOLATOR_DSP)
        let usBoth = timePerBlockPerChannel(mode: RO_ISOLATOR_NEURAL_DSP)
        print(String(format: "neural timing: %.2f us per 32-frame block per channel (DSP only %.2f, neural+DSP %.2f; budget 666.7 us/block)",
                     us, usDsp, usBoth))
        XCTAssertLessThan(us, 150)
        XCTAssertLessThan(usBoth, 150)
    }

    func testGainMarginPerIsolatorMode() {
        for source in [RO_SIM_SPEECH, RO_SIM_SINGING] {
            for mode in [RO_ISOLATOR_DSP, RO_ISOLATOR_NEURAL, RO_ISOLATOR_NEURAL_DSP] {
                let (margins, finite) = gainMargins(mode: mode, source: source)
                let sorted = margins.sorted()
                let median = (sorted[2] + sorted[3]) / 2
                print("isolator mode \(mode.rawValue), source \(source == RO_SIM_SPEECH ? "speech" : "singing"): "
                      + "margin per seed (dB) \(margins), median \(median), min \(sorted[0])")
                XCTAssertTrue(finite, "mode \(mode.rawValue)")
                if mode == RO_ISOLATOR_DSP && source == RO_SIM_SPEECH {
                    XCTAssertGreaterThanOrEqual(median, 6)
                    XCTAssertGreaterThanOrEqual(sorted[0], 6)
                }
            }
        }
    }
}

/// Per seed 1...6: highest loop gain (dB over the bypass limit, 1 dB steps)
/// the engine holds without howl at the default Strength. Seeds run in parallel.
private func gainMargins(mode: ro_isolator, source: ro_sim_source) -> ([Double], Bool) {
    let seeds: [UInt32] = Array(1...6)
    nonisolated(unsafe) var margins = [Double](repeating: 0, count: seeds.count)
    nonisolated(unsafe) var finite = [Bool](repeating: true, count: seeds.count)
    DispatchQueue.concurrentPerform(iterations: seeds.count) { i in
        var best = 0.0
        for g in stride(from: 1.0, through: 12.0, by: 1.0) {
            let sim = ro_sim_create(fs48k, 1, seeds[i])!
            let e = makeEngine(maxFrames: 32) { ro_engine_set_param($0, -1, RO_PARAM_ISOLATOR, Float(mode.rawValue)) }
            ro_sim_set_source(sim, 0, source)
            ro_sim_set_loop_gain_db(sim, 0, Float(g))
            let y = renderSim(sim, engine: e, seconds: 20)
            ro_sim_destroy(sim)
            ro_engine_destroy(e)
            if !y.allSatisfy(\.isFinite) { finite[i] = false }
            if howlFraction(y, from: 8) < 0.02 { best = g } else { break }
        }
        margins[i] = best
    }
    return (margins, !finite.contains(false))
}

/// Engine wall time per 32-frame block per channel, 10 s of two-channel audio.
private func timePerBlockPerChannel(mode: ro_isolator) -> Double {
    let e = makeEngine(maxFrames: 32, channels: 2) { ro_engine_set_param($0, -1, RO_PARAM_ISOLATOR, Float(mode.rawValue)) }
    defer { ro_engine_destroy(e) }
    let a = simSource(RO_SIM_SPEECH, seed: 3, seconds: 10)
    let b = simSource(RO_SIM_SINGING, seed: 4, seconds: 10)
    let block = 32
    let calls = a.count / block
    let out0 = UnsafeMutablePointer<Float>.allocate(capacity: block)
    let out1 = UnsafeMutablePointer<Float>.allocate(capacity: block)
    defer { [out0, out1].forEach { $0.deallocate() } }
    var outs: [UnsafeMutablePointer<Float>?] = [out0, out1]
    let clock = ContinuousClock()
    let elapsed = a.withUnsafeBufferPointer { pa in
        b.withUnsafeBufferPointer { pb in
            outs.withUnsafeMutableBufferPointer { op in
                var ins: [UnsafePointer<Float>?] = [nil, nil]
                return clock.measure {
                    for k in 0..<calls {
                        ins[0] = pa.baseAddress! + k * block
                        ins[1] = pb.baseAddress! + k * block
                        ins.withUnsafeMutableBufferPointer { ip in
                            ro_engine_process(e, ip.baseAddress, op.baseAddress, Int32(block))
                        }
                    }
                }
            }
        }
    }
    let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) * 1e-18
    return seconds / Double(calls) / 2 * 1e6
}

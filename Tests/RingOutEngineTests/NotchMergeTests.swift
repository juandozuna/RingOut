import Foundation
import RingOutEngine
import XCTest

// One resonance, one notch: a ring that moves onto the skirt of its own notch
// (placing the notch shifts the loop's phase crossing) must deepen / re-centre
// that notch, not take a new slot.

/// Phase-continuous tone that hops between `freqs` every `hopS` seconds while
/// its level rises like growingTone.
func hoppingTone(freqs: [Double], hopS: Double, startDb: Double = -90, rateDbPerS: Double = 30,
                 maxDb: Double = -6, seconds: Double, noiseAmp: Float = 3e-5, seed: UInt32 = 5) -> [Float] {
    let n = Int(seconds * fs48k)
    var rng = Lcg(state: seed)
    var phase = 0.0
    return (0..<n).map { i in
        let t = Double(i) / fs48k
        let f = freqs[Int(t / hopS) % freqs.count]
        phase += 2 * .pi * f / fs48k
        let db = min(maxDb, startDb + rateDbPerS * t)
        return Float(pow(10, db / 20) * sin(phase)) + noiseAmp * rng.next()
    }
}

/// Active auto notches as (frequency, depth), sorted by frequency.
func activeAuto(_ s: ro_channel_snapshot) -> [(f: Double, d: Double)] {
    notches(s)[..<Int(RO_MAX_AUTO_NOTCHES)].filter(\.active).map { (Double($0.frequency_hz), Double($0.depth_db)) }
        .sorted { $0.f < $1.f }
}

/// Smallest merge window the bank uses: 1.5 x the -3 dB bandwidth f/Q of a
/// fresh Q 60 notch (widened notches have larger windows).
func mergeWindowHz(_ f: Double) -> Double { max(1.5, 1.5 * f / 60) }

final class NotchMergeTests: XCTestCase {
    func testDriftingRingGetsOneNotchThatDeepens() {
        // The ring wanders +-5 Hz around 630 Hz (half the notch's -3 dB bandwidth)
        // while growing, as it does when its own notch shifts the loop phase.
        let freqs = [630.0, 634.5, 626.0, 635.0, 627.5, 633.0, 625.0, 631.0]
        let e = makeEngine()
        defer { ro_engine_destroy(e) }
        _ = process(e, hoppingTone(freqs: freqs, hopS: 0.15, rateDbPerS: 40, seconds: 3), block: 32)
        let evs = drainEvents(e)
        let rings = evs.filter { $0.type == RO_EVENT_RING_DETECTED }
        let deepened = evs.filter { $0.type == RO_EVENT_NOTCH_DEEPENED }
        let auto = activeAuto(snapshot(e))
        print("drifting 630 Hz ring: rings \(rings.map(\.frequency_hz)), deepen steps \(deepened.count), notches \(auto)")
        XCTAssertEqual(rings.count, 1, "one resonance, one detection: \(rings.map(\.frequency_hz))")
        XCTAssertEqual(auto.count, 1, "\(auto)")
        XCTAssertFalse(deepened.isEmpty, "the notch deepens instead")
        XCTAssertLessThanOrEqual(auto.first?.d ?? 0, -9)
        XCTAssertEqual(auto.first?.f ?? 0, 630, accuracy: 6, "re-centred within the drift range")
    }

    func testRingOnTheSkirtOfAFullDepthNotchMovesThatNotch() {
        // Ring at 1000 Hz drives its notch to -18 dB; then (as if the notch had
        // moved the loop's phase crossing) it grows again 8 Hz higher, on the
        // notch's skirt. Same resonance: no second notch, the existing one
        // moves toward the new ring.
        let e = makeEngine()
        defer { ro_engine_destroy(e) }
        _ = process(e, growingTone(freq: 1000, maxDb: -20, seconds: 2.5), block: 64)
        let before = activeAuto(snapshot(e))
        _ = drainEvents(e)
        _ = process(e, growingTone(freq: 1008, startDb: -60, rateDbPerS: 40, maxDb: -14, seconds: 1.5, seed: 3), block: 64)
        let evs = drainEvents(e)
        let after = activeAuto(snapshot(e))
        XCTAssertEqual(before.count, 1, "\(before)")
        XCTAssertEqual(before.first?.d ?? 0, -18, accuracy: 0.01)
        XCTAssertFalse(evs.contains { $0.type == RO_EVENT_RING_DETECTED }, "\(evs.map(\.frequency_hz))")
        XCTAssertEqual(after.count, 1, "\(after)")
        XCTAssertGreaterThan(after.first?.f ?? 0, 1002, "pulled toward the new ring")
        XCTAssertLessThanOrEqual(after.first?.f ?? 0, 1008.5)
        XCTAssertEqual(after.first?.d ?? 0, -18, accuracy: 0.01)
    }

    func testDistinctResonancesStillGetTheirOwnNotches() {
        // 630 and 700 Hz are ~4.4 merge windows apart: two rings, two notches.
        // (Sequential: two simultaneous tones 1.5 FFT bins apart are one peak to
        // the detector.) The first ring fades out smoothly and its notch is
        // still held when the second one grows.
        let e = makeEngine()
        defer { ro_engine_destroy(e) }
        let a = growingTone(freq: 630, maxDb: -20, seconds: 4)
        let fade = 2.2 * fs48k
        let first = a.enumerated().map { i, v in Double(i) < fade ? v : v * Float(pow(10, -60 * (Double(i) - fade) / fs48k / 20)) }
        let second = growingTone(freq: 700, startDb: -150, maxDb: -20, seconds: 4, noiseAmp: 0, seed: 2)
        _ = process(e, zip(first, second).map { $0 + $1 }, block: 64)
        let auto = activeAuto(snapshot(e))
        XCTAssertEqual(auto.count, 2, "\(auto)")
        XCTAssertEqual(auto.first?.f ?? 0, 630, accuracy: 3)
        XCTAssertEqual(auto.last?.f ?? 0, 700, accuracy: 3)
    }

    func testFixedNotchBandIsUserOwned() {
        // A steady tone is notched after ~0.5 s of persistence...
        let tone = sine(freq: 1003, db: -20, seconds: 3)
        let plain = makeEngine()
        defer { ro_engine_destroy(plain) }
        _ = process(plain, tone, block: 64)
        XCTAssertGreaterThanOrEqual(snapshot(plain).active_auto_notches, 1, "sanity: a steady tone is notched")

        // ...but not inside a fixed notch's band: the user's notch already covers it.
        let e = makeEngine()
        defer { ro_engine_destroy(e) }
        ro_engine_command(e, 0, RO_CMD_ADD_FIXED_NOTCH, 1000, -9)
        _ = process(e, tone, block: 64)
        var s = snapshot(e)
        XCTAssertEqual(s.active_auto_notches, 0, "\(activeAuto(s))")
        XCTAssertEqual(notches(s)[8].depth_db, -9, accuracy: 0.01)

        // A ring that keeps growing through it gets an auto notch on top; the
        // fixed notch keeps the user's depth and frequency.
        _ = process(e, growingTone(freq: 1003, startDb: -40, rateDbPerS: 40, maxDb: -6, seconds: 1.5), block: 64)
        s = snapshot(e)
        XCTAssertEqual(s.active_auto_notches, 1, "\(activeAuto(s))")
        XCTAssertEqual(notches(s)[8].depth_db, -9, accuracy: 0.01)
        XCTAssertEqual(notches(s)[8].frequency_hz, 1000, accuracy: 0.01)
    }

    /// The demo-mode finding: ro_sim channel 0 at +6 dB, speech, Speech preset,
    /// Strength 0.8, 32-frame blocks, ~45 s. Duplicate notches on one ring used
    /// to fill every slot.
    func testDemoLoopAtPlus6dBHasNoDuplicateNotches() {
        var report: [String] = []
        for seed: UInt32 in 1...8 {
            let sim = ro_sim_create(fs48k, 1, seed)!
            let e = makeEngine(maxFrames: 32)
            defer {
                ro_sim_destroy(sim)
                ro_engine_destroy(e)
            }
            ro_sim_set_loop_gain_db(sim, 0, 6)
            ro_sim_set_source(sim, 0, RO_SIM_SPEECH)
            // Checked once a second: the closest pair of active auto notches, in merge windows.
            var closest = Double.infinity
            var closestPair = ""
            for _ in 0..<45 {
                _ = renderSim(sim, engine: e, seconds: 1, block: 32)
                let auto = activeAuto(snapshot(e))
                for (a, b) in zip(auto, auto.dropFirst()) {
                    let w = (b.f - a.f) / mergeWindowHz(0.5 * (a.f + b.f))
                    if w < closest { closest = w; closestPair = String(format: "%.1f / %.1f Hz", a.f, b.f) }
                }
            }
            XCTAssertGreaterThan(closest, 0.99, "seed \(seed): \(closestPair) are one resonance")
            let s = snapshot(e)
            report.append("seed \(seed): \(s.active_auto_notches)/8 slots, warning \(s.loop_gain_warning), closest pair \(String(format: "%.1f", closest)) windows")
            XCTAssertLessThanOrEqual(s.active_auto_notches, 6, "seed \(seed)")
        }
        print("demo loop +6 dB after 45 s:\n  " + report.joined(separator: "\n  "))
    }
}

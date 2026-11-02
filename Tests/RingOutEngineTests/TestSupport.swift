import Foundation
import RingOutEngine

// Shared helpers for driving the C API from tests.

typealias Engine = OpaquePointer

let fs48k = 48_000.0

func makeEngine(sampleRate: Double = fs48k, maxFrames: Int = 64, channels: Int = 1,
                configure: (Engine) -> Void = { _ in }) -> Engine {
    let e = ro_engine_create()!
    configure(e)
    precondition(ro_engine_prepare(e, sampleRate, Int32(maxFrames), Int32(channels)))
    return e
}

/// Runs mono `input` through channel 0 in blocks of `block` frames.
func process(_ e: Engine, _ input: [Float], block: Int) -> [Float] {
    processMulti(e, [input], block: block)[0]
}

/// Runs one array per channel through the engine.
func processMulti(_ e: Engine, _ input: [[Float]], block: Int) -> [[Float]] {
    let ch = input.count
    let n = input[0].count
    var output = [[Float]](repeating: [Float](repeating: 0, count: n), count: ch)
    let inBufs = (0..<ch).map { _ in UnsafeMutablePointer<Float>.allocate(capacity: block) }
    let outBufs = (0..<ch).map { _ in UnsafeMutablePointer<Float>.allocate(capacity: block) }
    defer {
        inBufs.forEach { $0.deallocate() }
        outBufs.forEach { $0.deallocate() }
    }
    var inPtrs: [UnsafePointer<Float>?] = inBufs.map { UnsafePointer($0) }
    var outPtrs: [UnsafeMutablePointer<Float>?] = outBufs
    var pos = 0
    while pos < n {
        let m = min(block, n - pos)
        for c in 0..<ch {
            input[c].withUnsafeBufferPointer { src in
                inBufs[c].update(from: src.baseAddress! + pos, count: m)
            }
        }
        inPtrs.withUnsafeMutableBufferPointer { ip in
            outPtrs.withUnsafeMutableBufferPointer { op in
                ro_engine_process(e, ip.baseAddress, op.baseAddress, Int32(m))
            }
        }
        for c in 0..<ch {
            output[c].withUnsafeMutableBufferPointer { dst in
                (dst.baseAddress! + pos).update(from: outBufs[c], count: m)
            }
        }
        pos += m
    }
    return output
}

func drainEvents(_ e: Engine) -> [ro_event] {
    var out: [ro_event] = []
    var ev = ro_event()
    while ro_engine_pop_event(e, &ev) { out.append(ev) }
    return out
}

func snapshot(_ e: Engine, _ channel: Int = 0) -> ro_channel_snapshot {
    var s = ro_channel_snapshot()
    precondition(ro_engine_read_snapshot(e, Int32(channel), &s))
    return s
}

func notches(_ s: ro_channel_snapshot) -> [ro_notch_info] {
    var copy = s.notches
    return withUnsafeBytes(of: &copy) { Array($0.bindMemory(to: ro_notch_info.self)) }
}

func spectrum(_ s: ro_channel_snapshot) -> [Float] {
    var copy = s.spectrum_db
    return withUnsafeBytes(of: &copy) { Array($0.bindMemory(to: Float.self)) }
}

func rmsDb(_ x: ArraySlice<Float>) -> Double {
    var sum = 0.0
    for v in x { sum += Double(v) * Double(v) }
    return 10 * log10(sum / Double(max(1, x.count)) + 1e-20)
}

func rmsDb(_ x: [Float]) -> Double { rmsDb(x[...]) }

/// Small deterministic noise source.
struct Lcg {
    var state: UInt32
    mutating func next() -> Float {
        state = state &* 1_664_525 &+ 1_013_904_223
        return Float(state >> 8) / Float(1 << 24) * 2 - 1
    }
}

/// Sine whose level rises linearly in dB from `startDb` at `rateDbPerS`, capped
/// at `maxDb`, optionally stopping at `stopAt` seconds; plus low white noise.
func growingTone(freq: Double, startDb: Double = -90, rateDbPerS: Double = 30, maxDb: Double = -6,
                 seconds: Double, stopAt: Double? = nil, noiseAmp: Float = 3e-5,
                 sampleRate: Double = fs48k, seed: UInt32 = 1) -> [Float] {
    let n = Int(seconds * sampleRate)
    var rng = Lcg(state: seed)
    var out = [Float](repeating: 0, count: n)
    for i in 0..<n {
        let t = Double(i) / sampleRate
        var v = 0.0
        if stopAt == nil || t < stopAt! {
            let db = min(maxDb, startDb + rateDbPerS * t)
            v = pow(10, db / 20) * sin(2 * .pi * freq * t)
        }
        out[i] = Float(v) + noiseAmp * rng.next()
    }
    return out
}

/// Time (s) at which a growingTone crosses `levelDb`.
func crossingTime(startDb: Double = -90, rateDbPerS: Double = 30, levelDb: Double = -60) -> Double {
    (levelDb - startDb) / rateDbPerS
}

func sine(freq: Double, db: Double, seconds: Double, sampleRate: Double = fs48k) -> [Float] {
    let n = Int(seconds * sampleRate)
    let a = pow(10, db / 20)
    return (0..<n).map { Float(a * sin(2 * .pi * freq * Double($0) / sampleRate)) }
}

/// Talker material from the simulator with the loop effectively open.
func simSource(_ src: ro_sim_source, seed: UInt32, seconds: Double, sampleRate: Double = fs48k) -> [Float] {
    let sim = ro_sim_create(sampleRate, 1, seed)!
    defer { ro_sim_destroy(sim) }
    ro_sim_set_loop_gain_db(sim, 0, -60)
    ro_sim_set_source(sim, 0, src)
    return renderSim(sim, engine: nil, seconds: seconds, sampleRate: sampleRate)
}

/// Renders the closed loop; returns the monitor (engine output) of channel 0.
func renderSim(_ sim: OpaquePointer, engine: Engine?, seconds: Double, sampleRate: Double = fs48k,
               block: Int = 256) -> [Float] {
    let n = Int(seconds * sampleRate)
    var out = [Float](repeating: 0, count: n)
    out.withUnsafeMutableBufferPointer { buf in
        var pos = 0
        while pos < n {
            let m = min(block, n - pos)
            var ptrs: [UnsafeMutablePointer<Float>?] = [buf.baseAddress! + pos]
            ptrs.withUnsafeMutableBufferPointer { p in
                ro_sim_render(sim, engine, p.baseAddress, Int32(m))
            }
            pos += m
        }
    }
    return out
}

/// Fraction of 100 ms windows after `from` seconds whose RMS exceeds `thresholdDb`.
func howlFraction(_ x: [Float], from: Double, thresholdDb: Double = -14, sampleRate: Double = fs48k) -> Double {
    let w = Int(0.1 * sampleRate)
    var a = Int(from * sampleRate)
    var hot = 0, total = 0
    while a + w <= x.count {
        total += 1
        if rmsDb(x[a..<(a + w)]) > thresholdDb { hot += 1 }
        a += w
    }
    return total > 0 ? Double(hot) / Double(total) : 0
}

func isFinite(_ s: ro_channel_snapshot) -> Bool {
    let scalars: [Float] = [s.input_peak_db, s.input_rms_db, s.input_peak_hold_db, s.output_peak_db,
                            s.output_rms_db, s.output_peak_hold_db, s.last_ring_hz, s.last_ring_age_s,
                            s.isolator_activity, s.gain_reduction_db]
    return scalars.allSatisfy(\.isFinite) && spectrum(s).allSatisfy(\.isFinite)
        && notches(s).allSatisfy { $0.frequency_hz.isFinite && $0.depth_db.isFinite && $0.age_s.isFinite }
}

/// Constant-amplitude tone with a little vibrato, so the detector reads it as
/// a voice-like partial rather than a ring (a perfectly steady sine is treated
/// as feedback after ~0.5 s in the Speech preset).
func fmTone(freq: Double, db: Double, seconds: Double, sampleRate: Double = fs48k) -> [Float] {
    let n = Int(seconds * sampleRate)
    let a = pow(10, db / 20)
    var phase = 0.0
    return (0..<n).map { i in
        let t = Double(i) / sampleRate
        let f = freq * (1 + 0.02 * sin(2 * .pi * 5.5 * t))
        phase += 2 * .pi * f / sampleRate
        return Float(a * sin(phase))
    }
}

/// White noise at the given RMS.
func noise(seconds: Double, rmsDb: Double, seed: UInt32 = 11, sampleRate: Double = fs48k) -> [Float] {
    var rng = Lcg(state: seed)
    let a = Float(pow(10, rmsDb / 20) * sqrt(3.0))
    return (0..<Int(seconds * sampleRate)).map { _ in a * rng.next() }
}

/// |Y(f)/X(f)| in dB from Hann-windowed single-bin DFTs over the same span.
func transferDb(input x: ArraySlice<Float>, output y: ArraySlice<Float>, freq: Double, sampleRate: Double = fs48k) -> Double {
    func bin(_ s: ArraySlice<Float>) -> Double {
        var re = 0.0, im = 0.0
        let n = Double(s.count)
        for (k, v) in s.enumerated() {
            let w = 2 * Double.pi * freq * Double(k) / sampleRate
            let win = 0.5 - 0.5 * cos(2 * Double.pi * Double(k) / n)
            re += Double(v) * win * cos(w)
            im -= Double(v) * win * sin(w)
        }
        return re * re + im * im
    }
    return 10 * log10(bin(y) / bin(x))
}

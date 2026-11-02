import Foundation
import RingOutEngine

/// Swift face of the C++ engine. Owns the ro_engine and (optionally) the
/// simulated loop. All calls are from the main actor; the audio thread only
/// ever touches the raw pointers through RenderGlue.
final class Engine {
    let raw: OpaquePointer
    private(set) var sim: OpaquePointer?
    private(set) var channels = 2
    private(set) var sampleRate: Double = 48_000

    init() {
        raw = ro_engine_create()
    }

    isolated deinit {
        if let sim { ro_sim_destroy(sim) }
        ro_engine_destroy(raw)
    }

    @discardableResult
    func prepare(sampleRate: Double, maxFrames: Int, channels: Int) -> Bool {
        self.sampleRate = sampleRate
        self.channels = channels
        return ro_engine_prepare(raw, sampleRate, Int32(maxFrames), Int32(channels))
    }

    func makeSimulation(sampleRate: Double, channels: Int) {
        if let sim { ro_sim_destroy(sim) }
        sim = ro_sim_create(sampleRate, Int32(channels), UInt32.random(in: 1...UInt32.max))
    }

    func destroySimulation() {
        if let sim { ro_sim_destroy(sim) }
        sim = nil
    }

    // MARK: Parameters

    func set(_ param: ro_param, _ value: Float, channel: Int) {
        ro_engine_set_param(raw, Int32(channel), param, value)
    }

    func set(_ param: ro_param, _ value: Bool, channel: Int) {
        set(param, value ? 1 : 0, channel: channel)
    }

    func command(_ cmd: ro_command, channel: Int, _ a: Float = 0, _ b: Float = 0) {
        ro_engine_command(raw, Int32(channel), cmd, a, b)
    }

    // MARK: Simulation

    func setSimLoopGain(_ db: Float, channel: Int) {
        guard let sim else { return }
        ro_sim_set_loop_gain_db(sim, Int32(channel), db)
    }

    func setSimSource(_ source: ro_sim_source, channel: Int) {
        guard let sim else { return }
        ro_sim_set_source(sim, Int32(channel), source)
    }

    // MARK: Reading

    func snapshot(channel: Int) -> ChannelSnapshot? {
        var s = ro_channel_snapshot()
        guard ro_engine_read_snapshot(raw, Int32(channel), &s) else { return nil }
        return ChannelSnapshot(s)
    }

    var dspLoad: Float { ro_engine_dsp_load(raw) }

    func drainEvents(_ body: (ro_event) -> Void) {
        var ev = ro_event()
        var n = 0
        while n < 256, ro_engine_pop_event(raw, &ev) {
            body(ev)
            n += 1
        }
    }
}

struct NotchInfo: Identifiable, Hashable, Sendable {
    let slot: Int
    let frequency: Float
    let depth: Float
    let age: Float
    let fixed: Bool
    var id: Int { slot }
}

/// Value copy of ro_channel_snapshot that SwiftUI can diff.
struct ChannelSnapshot: Sendable {
    var inputPeak: Float = -120, inputRMS: Float = -120, inputHold: Float = -120
    var outputPeak: Float = -120, outputRMS: Float = -120, outputHold: Float = -120
    var inputClip = false, outputClip = false
    var state: ChannelState = .safe
    var autoNotches = 0, fixedNotches = 0
    var notches: [NotchInfo] = []
    var spectrum: [Float] = Array(repeating: -120, count: Int(RO_SPECTRUM_BINS))
    var lastRingHz: Float = 0
    var lastRingAge: Float = 999
    var isolatorActivity: Float = 0
    var gainReduction: Float = 0
    var loopGainWarning = false
    var multiTalker = false

    init() {}

    init(_ s: ro_channel_snapshot) {
        inputPeak = s.input_peak_db; inputRMS = s.input_rms_db; inputHold = s.input_peak_hold_db
        outputPeak = s.output_peak_db; outputRMS = s.output_rms_db; outputHold = s.output_peak_hold_db
        inputClip = s.input_clip; outputClip = s.output_clip
        state = ChannelState(rawValue: Int(s.state.rawValue)) ?? .safe
        autoNotches = Int(s.active_auto_notches); fixedNotches = Int(s.active_fixed_notches)
        var n = s.notches
        notches = withUnsafeBytes(of: &n) { raw in
            let arr = raw.bindMemory(to: ro_notch_info.self)
            return arr.enumerated().compactMap { i, info in
                info.active ? NotchInfo(slot: i, frequency: info.frequency_hz, depth: info.depth_db, age: info.age_s, fixed: info.fixed) : nil
            }
        }
        var sp = s.spectrum_db
        spectrum = withUnsafeBytes(of: &sp) { Array($0.bindMemory(to: Float.self)) }
        lastRingHz = s.last_ring_hz; lastRingAge = s.last_ring_age_s
        isolatorActivity = s.isolator_activity; gainReduction = s.gain_reduction_db
        loopGainWarning = s.loop_gain_warning; multiTalker = s.multi_talker
    }
}

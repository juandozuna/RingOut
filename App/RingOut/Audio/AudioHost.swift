import AVFAudio
import Foundation
import Observation

struct AudioPortInfo: Hashable, Sendable {
    var name: String
    var uid: String
    var portType: String
    var channels: Int

    var isUSB: Bool { portType == AVAudioSession.Port.usbAudio.rawValue }
    var isBuiltIn: Bool {
        [AVAudioSession.Port.builtInMic, .builtInSpeaker, .builtInReceiver].map(\.rawValue).contains(portType)
    }
}

/// What the current route looks like from the wizard's point of view.
enum InterfaceStatus: Equatable, Sendable {
    case none
    case notAnInterface(String)          // something is routed, but not a USB interface in both directions
    case found(AudioPortInfo)            // USB audio class device on input AND output
    case simulated
}

/// Owns AVAudioSession and the RemoteIO unit. Requested vs actual buffer is
/// always compared; the UI only ever shows actual values.
@Observable
final class AudioHost {
    let io: OpaquePointer = ro_io_create()

    private(set) var input: AudioPortInfo?
    private(set) var output: AudioPortInfo?
    private(set) var availableInputs: [AudioPortInfo] = []
    private(set) var sampleRate: Double = 48_000
    private(set) var requestedFrames = 32
    private(set) var actualFrames = 0
    private(set) var reportedInputLatency: Double = 0
    private(set) var reportedOutputLatency: Double = 0
    private(set) var isRunning = false
    private(set) var simulated = false
    private(set) var lastError: String?
    private(set) var ioChannels = 2

    var onRouteChange: ((AVAudioSession.RouteChangeReason) -> Void)?
    var onInterruption: ((_ began: Bool) -> Void)?
    var onMediaReset: (() -> Void)?

    private var observers: [NSObjectProtocol] = []

    init() {
        let nc = NotificationCenter.default
        let s = AVAudioSession.sharedInstance()
        observers.append(nc.addObserver(forName: AVAudioSession.routeChangeNotification, object: s, queue: .main) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt ?? 0
            let reason = AVAudioSession.RouteChangeReason(rawValue: raw) ?? .unknown
            MainActor.assumeIsolated {
                self?.refreshRoute()
                self?.onRouteChange?(reason)
            }
        })
        observers.append(nc.addObserver(forName: AVAudioSession.interruptionNotification, object: s, queue: .main) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt ?? 0
            let began = AVAudioSession.InterruptionType(rawValue: raw) == .began
            MainActor.assumeIsolated { self?.onInterruption?(began) }
        })
        observers.append(nc.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: s, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.onMediaReset?() }
        })
        refreshRoute()
    }

    var interfaceStatus: InterfaceStatus {
        if simulated { return .simulated }
        let input = self.input.flatMap { $0.isBuiltIn ? nil : $0 }
        let output = self.output.flatMap { $0.isBuiltIn ? nil : $0 }
        guard let input, let output else {
            if let any = input ?? output { return .notAnInterface(any.name) }
            return .none
        }
        if input.isUSB && output.isUSB { return .found(input) }
        if input.isUSB { return .notAnInterface("\(input.name) (output is \(output.name))") }
        if output.isUSB { return .notAnInterface("\(output.name) (input is \(input.name))") }
        return .none
    }

    var interfaceName: String {
        switch interfaceStatus {
        case .found(let p): p.name
        case .simulated: "Simulated rig"
        case .notAnInterface(let n): n
        case .none: "No interface"
        }
    }

    /// Round trip estimate from what Core Audio reports. Shown only until a
    /// loopback measurement exists.
    var estimatedRoundTripSeconds: Double {
        let frames = Double(max(actualFrames, requestedFrames))
        return reportedInputLatency + reportedOutputLatency + 2 * frames / sampleRate
    }

    var interfaceReportsLatency: Bool { reportedInputLatency > 0 || reportedOutputLatency > 0 }

    func refreshRoute() {
        let s = AVAudioSession.sharedInstance()
        let r = s.currentRoute
        input = r.inputs.first.map { AudioPortInfo(name: $0.portName, uid: $0.uid, portType: $0.portType.rawValue, channels: $0.channels?.count ?? 1) }
        output = r.outputs.first.map { AudioPortInfo(name: $0.portName, uid: $0.uid, portType: $0.portType.rawValue, channels: $0.channels?.count ?? 2) }
        availableInputs = (s.availableInputs ?? []).map { AudioPortInfo(name: $0.portName, uid: $0.uid, portType: $0.portType.rawValue, channels: $0.channels?.count ?? 1) }
        sampleRate = s.sampleRate > 0 ? s.sampleRate : 48_000
        actualFrames = Int((s.ioBufferDuration * sampleRate).rounded())
        reportedInputLatency = s.inputLatency
        reportedOutputLatency = s.outputLatency
    }

    func preferInput(uid: String) {
        let s = AVAudioSession.sharedInstance()
        if let port = s.availableInputs?.first(where: { $0.uid == uid }) {
            try? s.setPreferredInput(port)
        }
        refreshRoute()
    }

    func requestMicrophone() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    /// Configures and activates the session. Returns the actual buffer size.
    @discardableResult
    func configureSession(simulated: Bool, frames: Int) throws -> Int {
        self.simulated = simulated
        let s = AVAudioSession.sharedInstance()
        if simulated {
            try s.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        } else {
            try s.setCategory(.playAndRecord, mode: .measurement, options: [])
        }
        if !simulated, let interface = s.availableInputs?.first(where: { $0.portType == .usbAudio }) {
            try? s.setPreferredInput(interface)
        }
        try s.setActive(true)
        try? s.setPreferredSampleRate(s.sampleRate)
        requestedFrames = frames
        try? s.setPreferredIOBufferDuration(Double(frames) / max(s.sampleRate, 1))
        if !simulated {
            let wantIn = min(2, s.maximumInputNumberOfChannels)
            let wantOut = min(2, s.maximumOutputNumberOfChannels)
            if wantIn > 0 { try? s.setPreferredInputNumberOfChannels(wantIn) }
            if wantOut > 0 { try? s.setPreferredOutputNumberOfChannels(wantOut) }
            ioChannels = max(1, min(wantIn, wantOut))
        } else {
            ioChannels = 2
        }
        refreshRoute()
        return actualFrames
    }

    /// Changes the buffer on a running session (thermal step-up, settings).
    func setBuffer(frames: Int) {
        requestedFrames = frames
        let s = AVAudioSession.sharedInstance()
        try? s.setPreferredIOBufferDuration(Double(frames) / sampleRate)
        refreshRoute()
    }

    func start(engine: Engine, channels: Int, monitorAudible: Bool) throws {
        stop()
        let engineChannels = min(channels, simulated ? 2 : ioChannels)
        engine.prepare(sampleRate: sampleRate, maxFrames: Int(RO_MAX_FRAMES), channels: engineChannels)
        if simulated { engine.makeSimulation(sampleRate: sampleRate, channels: engineChannels) } else { engine.destroySimulation() }
        let status = ro_io_start(io, engine.raw, engine.sim, simulated ? RO_IO_SIMULATED : RO_IO_HARDWARE,
                                 Int32(simulated ? 2 : ioChannels), Int32(engineChannels), sampleRate, monitorAudible)
        guard status == noErr else {
            lastError = "Audio unit failed to start (\(status))"
            throw NSError(domain: "RingOut.Audio", code: Int(status), userInfo: [NSLocalizedDescriptionKey: lastError!])
        }
        lastError = nil
        isRunning = true
    }

    func stop() {
        ro_io_stop(io)
        isRunning = false
    }

    func setOutputMuted(_ muted: Bool) { ro_io_set_output_muted(io, muted) }
    func setMonitorAudible(_ audible: Bool) { ro_io_set_monitor_audible(io, audible) }

    var callbackCount: UInt64 { ro_io_callback_count(io) }
    var lastCallbackFrames: Int { Int(ro_io_last_frames(io)) }
    var renderErrors: Int { Int(ro_io_render_errors(io)) }

    func beginLatencyMeasurement() { ro_io_begin_latency_measurement(io) }

    enum LatencyResult { case pending, done(Float), failed }
    func latencyResult() -> LatencyResult {
        var samples: Float = 0
        switch ro_io_latency_result(io, &samples) {
        case 1: return .done(samples)
        case 0: return .pending
        default: return .failed
        }
    }
}

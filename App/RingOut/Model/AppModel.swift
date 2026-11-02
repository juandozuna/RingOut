import AVFAudio
import Foundation
import Observation
import UIKit

/// Root coordinator. Owns the engine, audio host and monitors; everything the
/// screens read lives here. Runs a 30 Hz tick that pulls meter snapshots and
/// engine events and performs the watchdog, thermal and power logic.
@Observable
final class AppModel {
    enum Phase: Equatable { case welcome, wizard, live }

    struct Disconnect: Equatable {
        var since: Date
        var name: String
    }

    enum BannerLevel { case info, warning, critical }
    struct Banner: Equatable, Identifiable {
        var id: String
        var level: BannerLevel
        var text: String
        var actionTitle: String?
    }

    // Subsystems
    let engine = Engine()
    let audio = AudioHost()
    let device = DeviceMonitor()
    let store = ShowStore()
    let log = EventLog()
    let license = License()

    // Navigation / overlays
    var phase: Phase = .welcome
    var showSettings = false
    var showDiagnostics = false
    var showCalibration = false
    var notchDetailChannel: Int?
    private(set) var disconnect: Disconnect?
    private(set) var reconnectedFlash = false
    var locked = false

    // Current show (persisted)
    private(set) var show = ShowFile.makeDefault()

    // Live readouts
    private(set) var snapshots: [ChannelSnapshot] = [ChannelSnapshot(), ChannelSnapshot()]
    private(set) var dspLoad: Float = 0
    private(set) var overloads = 0
    private(set) var watchdogTripped = false
    private(set) var lastStartError: String?

    // Thermal / overload step-up
    private(set) var stepUpPending = false
    private(set) var stepDownOffered = false
    private var preStepUpFrames: Int?
    private var nominalSince: Date?
    private var overloadTimes: [Date] = []

    // Simulated rig controls (demo mode only)
    var simLoopGain: [Float] = [-6, -6]
    var simSource: [ro_sim_source] = [RO_SIM_SPEECH, RO_SIM_SPEECH]
    var monitorAudible = false { didSet { audio.setMonitorAudible(monitorAudible) } }

    private var timer: Timer?
    private var lastCallbacks: UInt64 = 0
    private var watchdogMisses = 0
    private var lastRenderErrors = 0
    private var silentSince: Date?
    private var tickCount = 0
    private var lastInteraction = Date()
    private var lastThermal: ProcessInfo.ThermalState = .nominal
    private var trialMuteUntil: Date?
    private var lastTrialMute = Date()
    private var saveWork: DispatchWorkItem?

    static let setupCompleteKey = "setupComplete"

    init() {
        audio.onRouteChange = { [weak self] reason in self?.handleRouteChange(reason) }
        audio.onInterruption = { [weak self] began in self?.handleInterruption(began) }
        audio.onMediaReset = { [weak self] in self?.restartAudio(reason: "Media services reset") }
    }

    // MARK: - Lifecycle

    /// F2: returning users go straight to Live with the last show.
    func bootstrap() {
        if ProcessInfo.processInfo.arguments.contains("-resetForUITests") {
            UserDefaults.standard.removeObject(forKey: Self.setupCompleteKey)
        }
        if ProcessInfo.processInfo.arguments.contains("-demoLive") {
            var s = ShowFile.makeDefault()
            s.name = "Demo"
            s.simulated = true
            show = s
            if UserDefaults.standard.object(forKey: "demoGain") != nil {
                let g = UserDefaults.standard.float(forKey: "demoGain")
                simLoopGain = [g, min(g, -3)]
            }
            goLive()
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-previewDisconnect") {
                disconnect = Disconnect(since: Date().addingTimeInterval(-12), name: "Scarlett 4i4 USB")
            }
            #endif
            return
        }
        if UserDefaults.standard.bool(forKey: Self.setupCompleteKey), let last = store.lastShow() {
            show = last
            goLive()
        } else {
            phase = .welcome
        }
    }

    func beginSetup() { phase = .wizard }

    /// Wizard: make `s` the working show and (re)start audio so checks and
    /// calibration see real numbers.
    @discardableResult
    func stage(_ s: ShowFile, startAudio start: Bool) -> Bool {
        let restart = s.simulated != show.simulated || s.channelCount != show.channelCount || !audio.isRunning
        show = s
        guard start else { return true }
        if restart { audio.stop(); return startAudio() }
        audio.setBuffer(frames: s.bufferFrames)
        applyShowToEngine()
        return true
    }

    /// Persist a calibration result into the current show.
    func storeCalibration(_ c: CalibrationResult) {
        show.calibration = c
        scheduleSave()
    }

    func load(_ s: ShowFile) {
        show = s
        UserDefaults.standard.set(s.id.uuidString, forKey: ShowStore.lastShowKey)
        if phase == .live { restartAudio(reason: "Loaded show “\(s.name)”") }
    }

    /// Finishes the wizard (or loads a show) and starts live processing.
    func finishSetup(with s: ShowFile, saveAs name: String?) {
        show = s
        if let name, !name.isEmpty { show.name = name }
        try? store.save(show)
        UserDefaults.standard.set(true, forKey: Self.setupCompleteKey)
        goLive()
    }

    func goLive() {
        phase = .live
        UIApplication.shared.isIdleTimerDisabled = true
        if !audio.isRunning { startAudio() } else { applyShowToEngine() }
        startTimer()
        log.add(.session, "Live — \(effectiveChannels) channel(s) on \(audio.interfaceName)")
    }

    var effectiveChannels: Int { license.isPro ? show.channelCount : 1 }

    /// Starts (or restarts) audio with the current show. Shared by the wizard,
    /// live and recovery paths.
    @discardableResult
    func startAudio() -> Bool {
        do {
            if !show.simulated {
                Task { _ = await audio.requestMicrophone() }
            }
            let actual = try audio.configureSession(simulated: show.simulated, frames: show.bufferFrames)
            try audio.start(engine: engine, channels: effectiveChannels, monitorAudible: monitorAudible)
            applyShowToEngine()
            lastCallbacks = audio.callbackCount
            watchdogMisses = 0
            lastRenderErrors = audio.renderErrors
            lastStartError = nil
            if actual > 128 && !show.simulated {
                lastStartError = "Buffer is \(actual) samples. RingOut needs 128 or less to run live — close other audio apps and turn off Sound Recognition / Vocal Shortcuts."
            }
            startTimer()
            return true
        } catch {
            lastStartError = error.localizedDescription
            log.add(.session, "Audio start failed: \(error.localizedDescription)")
            return false
        }
    }

    func restartAudio(reason: String) {
        log.add(.session, reason)
        audio.stop()
        startAudio()
    }

    private func applyShowToEngine() {
        for ch in 0..<2 {
            let c = show.channels[ch]
            engine.set(RO_PARAM_STRENGTH, c.strength, channel: ch)
            engine.set(RO_PARAM_PRESET, Float(c.preset.rawValue), channel: ch)
            engine.set(RO_PARAM_HIGHPASS, c.highPass, channel: ch)
            engine.set(RO_PARAM_INPUT_TRIM_DB, c.inputTrimDB, channel: ch)
            engine.set(RO_PARAM_LIMITER, show.limiter, channel: ch)
            engine.set(RO_PARAM_NOTCH_HOLD_S, show.notchHoldSeconds, channel: ch)
            engine.set(RO_PARAM_MAX_AUTO_NOTCHES, Float(show.maxAutoNotches), channel: ch)
            engine.set(RO_PARAM_BYPASS, bypassed[ch] || watchdogTripped, channel: ch)
            engine.set(RO_PARAM_MUTE, muted[ch], channel: ch)
            engine.set(RO_PARAM_RING_OUT_MODE, false, channel: ch)
            for slot in Int(RO_MAX_AUTO_NOTCHES)..<Int(RO_MAX_NOTCHES) {
                engine.command(RO_CMD_RELEASE_NOTCH, channel: ch, Float(slot))
            }
            for n in c.fixedNotches { engine.command(RO_CMD_ADD_FIXED_NOTCH, channel: ch, n.frequency, n.depth) }
            if show.simulated {
                engine.setSimLoopGain(simLoopGain[ch], channel: ch)
                engine.setSimSource(simSource[ch], channel: ch)
            }
        }
    }

    // MARK: - Live controls (not persisted: bypass, mute)

    private(set) var bypassed = [false, false]
    private(set) var muted = [false, false]
    private(set) var ringOutActive: Int?

    func touch() { lastInteraction = Date() }

    func setStrength(_ v: Float, channel: Int) {
        touch()
        let v = min(max(v, 0), 1)
        show.channels[channel].strength = v
        if show.channels[channel].preset != .custom, let def = show.channels[channel].preset.defaultStrength, abs(def - v) > 0.001 {
            // Moving the dial off a preset's default keeps the preset's model variant.
        }
        engine.set(RO_PARAM_STRENGTH, v, channel: channel)
        scheduleSave()
    }

    func setPreset(_ p: Preset, channel: Int) {
        touch()
        show.channels[channel].preset = p
        engine.set(RO_PARAM_PRESET, Float(p.rawValue), channel: channel)
        if let s = p.defaultStrength { setStrength(s, channel: channel) }
        scheduleSave()
    }

    func toggleBypass(_ channel: Int) {
        touch()
        bypassed[channel].toggle()
        engine.set(RO_PARAM_BYPASS, bypassed[channel] || watchdogTripped, channel: channel)
        log.add(.info, bypassed[channel] ? "Bypass on" : "Bypass off", channel: channel)
    }

    func setMuted(_ m: Bool, channel: Int) {
        touch()
        muted[channel] = m
        engine.set(RO_PARAM_MUTE, m, channel: channel)
        log.add(.info, m ? "Muted" : "Unmuted", channel: channel)
    }

    func rename(_ channel: Int, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        show.channels[channel].name = String(trimmed.prefix(24))
        scheduleSave()
    }

    func resetMeters(_ channel: Int) { engine.command(RO_CMD_RESET_METERS, channel: channel) }

    // Notch detail
    func pinNotch(slot: Int, channel: Int) {
        engine.command(RO_CMD_PIN_NOTCH, channel: channel, Float(slot))
        log.add(.pin, "Pinned notch", channel: channel)
    }
    func releaseNotch(slot: Int, channel: Int) { engine.command(RO_CMD_RELEASE_NOTCH, channel: channel, Float(slot)) }
    func moveNotch(slot: Int, to hz: Float, channel: Int) { engine.command(RO_CMD_MOVE_NOTCH, channel: channel, Float(slot), hz) }
    func clearAutoNotches(_ channel: Int) { engine.command(RO_CMD_CLEAR_AUTO_NOTCHES, channel: channel) }

    func setRingOut(_ on: Bool, channel: Int) {
        ringOutActive = on ? channel : nil
        engine.set(RO_PARAM_RING_OUT_MODE, on, channel: channel)
        log.add(.info, on ? "Ring-out mode started" : "Ring-out mode finished", channel: channel)
    }

    // Settings mutations
    func update(_ body: (inout ShowFile) -> Void, restart: Bool = false) {
        let before = show
        body(&show)
        if restart || before.channelCount != show.channelCount || before.simulated != show.simulated {
            if phase == .live { restartAudio(reason: "Settings changed") }
        } else {
            if before.bufferFrames != show.bufferFrames { audio.setBuffer(frames: show.bufferFrames) }
            if phase == .live { applyLightParams() }
        }
        scheduleSave()
    }

    private func applyLightParams() {
        for ch in 0..<2 {
            engine.set(RO_PARAM_HIGHPASS, show.channels[ch].highPass, channel: ch)
            engine.set(RO_PARAM_INPUT_TRIM_DB, show.channels[ch].inputTrimDB, channel: ch)
            engine.set(RO_PARAM_PRESET, Float(show.channels[ch].preset.rawValue), channel: ch)
            engine.set(RO_PARAM_LIMITER, show.limiter, channel: ch)
            engine.set(RO_PARAM_NOTCH_HOLD_S, show.notchHoldSeconds, channel: ch)
            engine.set(RO_PARAM_MAX_AUTO_NOTCHES, Float(show.maxAutoNotches), channel: ch)
        }
    }

    func setSimLoopGain(_ db: Float, channel: Int) {
        simLoopGain[channel] = db
        engine.setSimLoopGain(db, channel: channel)
    }

    func setSimSource(_ s: ro_sim_source, channel: Int) {
        simSource[channel] = s
        engine.setSimSource(s, channel: channel)
    }

    func saveNow() { try? store.save(show) }

    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.saveNow() } }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    // MARK: - Lock

    var hasPIN: Bool { show.lockPINHash != nil }

    func lock() {
        guard hasPIN else { return }
        locked = true
        log.add(.info, "UI locked")
    }

    func unlock(pin: String) -> Bool {
        guard LockPIN.verify(pin, hash: show.lockPINHash) else { return false }
        locked = false
        touch()
        log.add(.info, "UI unlocked")
        return true
    }

    func setPIN(_ pin: String?) {
        update { $0.lockPINHash = pin.map(LockPIN.hash) }
    }

    /// S9 safety release: bypass both channels without the PIN.
    func safetyBypass() {
        guard show.allowBypassRelease else { return }
        for ch in 0..<2 where !bypassed[ch] { toggleBypass(ch) }
        log.add(.info, "Safety bypass from lock screen")
    }

    // MARK: - Watchdog

    func resumeAfterWatchdog() {
        watchdogTripped = false
        for ch in 0..<2 { engine.set(RO_PARAM_BYPASS, bypassed[ch], channel: ch) }
        log.add(.watchdog, "Processing resumed by operator")
    }

    // MARK: - Thermal step-down

    func acceptStepDown() {
        guard let frames = preStepUpFrames else { return }
        stepDownOffered = false
        preStepUpFrames = nil
        update { $0.bufferFrames = frames }
        log.add(.thermal, "Buffer stepped back down to \(frames)")
    }

    func dismissStepDown() { stepDownOffered = false }

    // MARK: - Route handling (F4)

    private func handleRouteChange(_ reason: AVAudioSession.RouteChangeReason) {
        guard phase == .live, !show.simulated else { return }
        log.add(.route, "Route change: \(audio.input?.name ?? "none") → \(audio.output?.name ?? "none") (\(reason.rawValue))")
        let ok: Bool
        if case .found(let port) = audio.interfaceStatus {
            ok = show.interface == nil || show.interface?.name == port.name || show.interface?.uid == port.uid
        } else {
            ok = false
        }
        if !ok, disconnect == nil {
            audio.setOutputMuted(true)
            disconnect = Disconnect(since: Date(), name: show.interface?.name ?? audio.interfaceName)
            log.add(.route, "Interface disconnected — output muted")
        } else if ok, disconnect != nil {
            recoverInterface()
        }
    }

    private func recoverInterface() {
        audio.setOutputMuted(true)
        audio.stop()
        if startAudio() {
            audio.setOutputMuted(false)  // RenderGlue fades in over 200 ms
            disconnect = nil
            reconnectedFlash = true
            log.add(.route, "Interface reconnected — audio resumed")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                MainActor.assumeIsolated { self?.reconnectedFlash = false }
            }
        }
    }

    /// From S8 after 10 s: back to wizard step 1 keeping show settings.
    func useDifferentInterface() {
        disconnect = nil
        audio.setOutputMuted(false)
        audio.stop()
        phase = .wizard
    }

    private func handleInterruption(_ began: Bool) {
        log.add(.session, began ? "Audio session interrupted" : "Interruption ended")
        if !began, phase == .live { restartAudio(reason: "Resuming after interruption") }
    }

    // MARK: - Tick

    private func startTimer() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        tickCount += 1
        let n = audio.isRunning ? engine.channels : 0
        for ch in 0..<n {
            if let s = engine.snapshot(channel: ch) { snapshots[ch] = s }
        }
        dspLoad = engine.dspLoad
        engine.drainEvents { ev in self.record(ev) }
        watchdog()
        overloadCheck()
        silentGapStepUp()
        trialMute()
        if tickCount % 30 == 0 { everySecond() }
    }

    private func record(_ ev: ro_event) {
        let ch = Int(ev.channel)
        let hz = String(format: "%.0f Hz", ev.frequency_hz)
        switch ev.type {
        case RO_EVENT_RING_DETECTED:
            log.add(LogEvent(kind: .ring, channel: ch, frequency: ev.frequency_hz, confidence: ev.confidence, depth: ev.depth_db,
                             message: "Ring at \(hz), confidence \(Int(ev.confidence * 100))%, notch \(String(format: "%.0f", ev.depth_db)) dB"))
        case RO_EVENT_NOTCH_DEEPENED:
            log.add(LogEvent(kind: .deepen, channel: ch, frequency: ev.frequency_hz, confidence: ev.confidence, depth: ev.depth_db,
                             message: "Deepened \(hz) to \(String(format: "%.0f", ev.depth_db)) dB"))
        case RO_EVENT_NOTCH_RELEASED:
            log.add(LogEvent(kind: .release, channel: ch, frequency: ev.frequency_hz, depth: ev.depth_db, duration: ev.duration_s,
                             message: "Released \(hz) after \(String(format: "%.1f", ev.duration_s)) s"))
        case RO_EVENT_NOTCH_PINNED:
            log.add(LogEvent(kind: .pin, channel: ch, frequency: ev.frequency_hz, depth: ev.depth_db, message: "Pinned \(hz) as fixed"))
        case RO_EVENT_LOOP_GAIN_WARNING:
            log.add(LogEvent(kind: .loopGain, channel: ch, frequency: ev.frequency_hz, message: "Loop gain too high — lower the console fader"))
        default:
            break
        }
    }

    /// Three silent ticks in a row while running → bit-exact bypass (not mute)
    /// so the show continues without suppression rather than going silent.
    private func watchdog() {
        guard audio.isRunning, disconnect == nil, !watchdogTripped else { return }
        let c = audio.callbackCount
        if c == lastCallbacks {
            watchdogMisses += 1
            if watchdogMisses >= 3 && UIApplication.shared.applicationState == .active {
                watchdogTripped = true
                for ch in 0..<2 { engine.set(RO_PARAM_BYPASS, true, channel: ch) }
                log.add(.watchdog, "Render callback stalled — both channels switched to bypass")
            }
        } else {
            watchdogMisses = 0
        }
        lastCallbacks = c
    }

    private func overloadCheck() {
        let e = audio.renderErrors
        guard e != lastRenderErrors else { return }
        let delta = e - lastRenderErrors
        lastRenderErrors = e
        overloads += delta
        let now = Date()
        overloadTimes.append(contentsOf: Array(repeating: now, count: delta))
        overloadTimes.removeAll { now.timeIntervalSince($0) > 60 }
        log.add(.overload, "Audio overload (\(overloads) total)")
        if overloadTimes.count >= 5 && show.thermalPolicy == .autoStepUp && nextBuffer != nil {
            stepUpPending = true
            overloadTimes.removeAll()
            log.add(.overload, "5 overloads in a minute — will raise buffer at the next silent gap")
        }
    }

    private var nextBuffer: Int? {
        ShowFile.validBuffers.first { $0 > max(show.bufferFrames, audio.actualFrames) }
    }

    /// F5: apply the pending step-up only when every channel's input has been
    /// below −50 dBFS for 200 ms, so the change is inaudible.
    private func silentGapStepUp() {
        guard stepUpPending, let next = nextBuffer else { stepUpPending = false; return }
        let quiet = (0..<effectiveChannels).allSatisfy { snapshots[$0].inputPeak < -50 }
        if quiet {
            if silentSince == nil { silentSince = Date() }
            if let s = silentSince, Date().timeIntervalSince(s) >= 0.2 {
                if preStepUpFrames == nil { preStepUpFrames = show.bufferFrames }
                show.bufferFrames = next
                audio.setBuffer(frames: next)
                stepUpPending = false
                silentSince = nil
                log.add(.thermal, "Buffer raised to \(next) samples (\(String(format: "%.1f", audio.estimatedRoundTripSeconds * 1000)) ms)")
                scheduleSave()
            }
        } else {
            silentSince = nil
        }
    }

    private func trialMute() {
        guard !license.isPro, audio.isRunning else { return }
        let now = Date()
        if let until = trialMuteUntil {
            if now >= until { audio.setOutputMuted(disconnect != nil); trialMuteUntil = nil; lastTrialMute = now }
        } else if now.timeIntervalSince(lastTrialMute) >= 90 {
            audio.setOutputMuted(true)
            trialMuteUntil = now.addingTimeInterval(2)
        }
    }

    private func everySecond() {
        audio.refreshRoute()
        if tickCount % 150 == 0 { device.poll() }
        let t = device.thermal
        if t != lastThermal {
            log.add(.thermal, "Thermal state \(device.thermalLabel)")
            if t == .serious, show.thermalPolicy == .autoStepUp, nextBuffer != nil { stepUpPending = true }
            if t == .critical, show.bufferFrames < 128 {
                if preStepUpFrames == nil { preStepUpFrames = show.bufferFrames }
                show.bufferFrames = 128
                audio.setBuffer(frames: 128)
                log.add(.thermal, "Critical — buffer forced to 128")
            }
            lastThermal = t
        }
        if t == .nominal, preStepUpFrames != nil {
            if nominalSince == nil { nominalSince = Date() }
            if let s = nominalSince, Date().timeIntervalSince(s) > 300 { stepDownOffered = true }
        } else {
            nominalSince = nil
        }
        log.addHealth(HealthSample(date: Date(), dspLoad: dspLoad, overloads: overloads, thermal: t.rawValue,
                                   bufferFrames: audio.actualFrames, battery: device.batteryLevel ?? -1))
        syncFixedNotches()
        if show.autoLockMinutes > 0, hasPIN, !locked, Date().timeIntervalSince(lastInteraction) > Double(show.autoLockMinutes) * 60 {
            lock()
        }
    }

    /// Fixed notches pinned in the engine (ring-out, pin) are mirrored into the show file.
    private func syncFixedNotches() {
        var changed = false
        for ch in 0..<engine.channels where audio.isRunning {
            let fixed = snapshots[ch].notches.filter(\.fixed).map { FixedNotch(frequency: $0.frequency, depth: $0.depth) }
            let rounded = fixed.map { FixedNotch(frequency: ($0.frequency * 10).rounded() / 10, depth: ($0.depth * 10).rounded() / 10) }
            if rounded != show.channels[ch].fixedNotches {
                show.channels[ch].fixedNotches = rounded
                changed = true
            }
        }
        if changed { scheduleSave() }
    }

    // MARK: - Status

    /// Measured if a loopback run exists for this buffer, otherwise the Core Audio estimate.
    var latencyMS: Double {
        if let c = show.calibration, let ms = c.measuredLatencyMS, c.bufferFrames == audio.actualFrames { return ms }
        return audio.estimatedRoundTripSeconds * 1000
    }

    var latencyIsMeasured: Bool {
        if let c = show.calibration, c.measuredLatencySamples != nil, c.bufferFrames == audio.actualFrames { return true }
        return false
    }

    var latencySamples: Int { Int((latencyMS / 1000 * audio.sampleRate).rounded()) }

    var banners: [Banner] {
        var b: [Banner] = []
        if watchdogTripped { b.append(Banner(id: "watchdog", level: .critical, text: "Audio callback stalled — both channels bypassed. The show continues without suppression.", actionTitle: "Resume")) }
        if let e = lastStartError { b.append(Banner(id: "start", level: .critical, text: e, actionTitle: "Retry")) }
        if device.thermal == .critical { b.append(Banner(id: "thermal", level: .critical, text: "Thermal critical — buffer forced to 128 samples.", actionTitle: nil)) }
        else if device.thermal == .serious { b.append(Banner(id: "thermal", level: .warning, text: "iPad is hot. \(show.thermalPolicy == .autoStepUp ? "Buffer will step up at the next silent gap." : "Consider a larger buffer.")", actionTitle: nil)) }
        if let lvl = device.batteryLevel, !device.onMains, lvl < 0.15 { b.append(Banner(id: "battery", level: .warning, text: "Battery \(Int(lvl * 100))% — connect PD power to the hub.", actionTitle: nil)) }
        else if let h = device.projectedHours, h < show.batteryWarnHours { b.append(Banner(id: "drain", level: .warning, text: String(format: "On battery — about %.1f h left at this load.", h), actionTitle: nil)) }
        if stepDownOffered { b.append(Banner(id: "stepdown", level: .info, text: "Thermal back to nominal for 5 min. Return to \(preStepUpFrames ?? 32)-sample buffer? (may click)", actionTitle: "Step down")) }
        if !license.isPro { b.append(Banner(id: "trial", level: .info, text: "Trial — 1 channel, 2 s mute every 90 s.", actionTitle: "Upgrade")) }
        return b
    }

    func performBannerAction(_ id: String) {
        switch id {
        case "watchdog": resumeAfterWatchdog()
        case "start": restartAudio(reason: "Retry")
        case "stepdown": acceptStepDown()
        case "trial": showSettings = true
        default: break
        }
    }

    var statusDictionary: [String: String] {
        [
            "Interface": audio.interfaceName,
            "Sample rate": "\(Int(audio.sampleRate)) Hz",
            "Buffer (actual)": "\(audio.actualFrames) samples (requested \(audio.requestedFrames))",
            "Latency": String(format: "%.2f ms (%@)", latencyMS, latencyIsMeasured ? "measured" : "estimated"),
            "DSP load": "\(Int(dspLoad * 100))%",
            "Overloads": "\(overloads)",
            "Thermal": device.thermalLabel,
            "Power": { switch device.power { case .mains: "Mains"; case .battery: "Battery"; case .unknown: "Unknown" } }(),
        ]
    }
}

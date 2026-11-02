import Foundation
import Observation

/// Wizard step 4 / S4: signal check, loopback latency, stress test.
@Observable
final class Calibrator {
    enum LatencyState: Equatable { case idle, measuring, measured(Float), estimated(Float), failed }
    enum StressState: Equatable { case idle, running, passed, failed(String) }

    private unowned let app: AppModel

    private(set) var signalSeconds: [Double] = [0, 0]
    private(set) var latency: LatencyState = .idle
    private(set) var stress: StressState = .idle
    private(set) var stressProgress: Double = 0
    private(set) var stressLoad: [Float] = []
    private(set) var stressOverloads = 0
    private(set) var peakLoad: Float = 0
    private(set) var steppedUpTo: Int?
    var proMode = false

    private var task: Task<Void, Never>?
    private var signalTask: Task<Void, Never>?

    init(app: AppModel) {
        self.app = app
        if let c = app.show.calibration, c.bufferFrames == app.show.bufferFrames {
            if let s = c.measuredLatencySamples { latency = .measured(s) }
        }
        startSignalWatch()
    }

    var stressDuration: Double { proMode ? 600 : 60 }

    /// Seconds of input inside the −24…−6 dBFS band (target −18). 1.5 s passes.
    func signalOK(_ ch: Int) -> Bool { signalSeconds[ch] >= 1.5 }

    private func startSignalWatch() {
        signalTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self else { return }
                for ch in 0..<self.app.effectiveChannels {
                    let p = self.app.snapshots[ch].inputPeak
                    if p > -24 && p < -6 { self.signalSeconds[ch] = min(self.signalSeconds[ch] + 0.1, 5) }
                }
            }
        }
    }

    func measureLatency() {
        if app.show.simulated {
            latency = .estimated(Float(app.audio.estimatedRoundTripSeconds * app.audio.sampleRate))
            return
        }
        latency = .measuring
        app.audio.beginLatencyMeasurement()
        task?.cancel()
        task = Task { [weak self] in
            for _ in 0..<80 {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self else { return }
                switch self.app.audio.latencyResult() {
                case .done(let s): self.latency = .measured(s); self.app.log.add(.session, "Loopback latency \(Int(s)) samples"); return
                case .failed: self.latency = .failed; return
                case .pending: continue
                }
            }
            self?.latency = .failed
        }
    }

    func runStress() {
        task?.cancel()
        stress = .running
        stressProgress = 0
        stressLoad = []
        peakLoad = 0
        let startErrors = app.overloads
        let duration = stressDuration
        task = Task { [weak self] in
            let start = Date()
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self else { return }
                let t = Date().timeIntervalSince(start)
                self.stressProgress = min(t / duration, 1)
                let load = self.app.dspLoad
                self.stressLoad.append(load)
                self.peakLoad = max(self.peakLoad, load)
                self.stressOverloads = self.app.overloads - startErrors
                if t >= duration { break }
            }
            guard let self, !Task.isCancelled else { return }
            if self.stressOverloads == 0 {
                self.stress = .passed
            } else {
                // PRD: step up to the next buffer automatically and say so.
                let next = ShowFile.validBuffers.first { $0 > self.app.show.bufferFrames }
                if let next {
                    self.app.update { $0.bufferFrames = next }
                    self.steppedUpTo = next
                    self.stress = .failed("\(self.stressOverloads) overload(s). Buffer raised to \(next) samples — run the test again.")
                } else {
                    self.stress = .failed("\(self.stressOverloads) overload(s) at 128 samples. Close other apps and let the iPad cool.")
                }
            }
            self.app.log.add(.session, "Stress test \(self.stress == .passed ? "passed" : "failed"): \(self.stressOverloads) overloads, peak DSP \(Int(self.peakLoad * 100))%")
        }
    }

    func stop() {
        task?.cancel()
        signalTask?.cancel()
        if stress == .running { stress = .idle }
    }

    func result() -> CalibrationResult {
        var samples: Float?
        if case .measured(let s) = latency { samples = s }
        return CalibrationResult(measuredLatencySamples: samples, sampleRate: app.audio.sampleRate, bufferFrames: app.audio.actualFrames,
                                 stressPassed: stress == .passed, stressOverloads: stressOverloads, peakDSPLoad: peakLoad, date: Date())
    }
}

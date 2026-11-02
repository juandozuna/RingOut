import Foundation
import Observation
import UIKit

enum PowerSource: Equatable, Sendable {
    case mains(level: Float?)
    case battery(level: Float)
    case unknown
}

/// Thermal state, power source and battery drain. Polled every 5 s plus
/// system notifications.
@Observable
final class DeviceMonitor {
    private(set) var thermal: ProcessInfo.ThermalState = ProcessInfo.processInfo.thermalState
    private(set) var power: PowerSource = .unknown
    /// Percent per hour, positive = discharging. nil until enough samples.
    private(set) var drainPerHour: Double?

    private var samples: [(Date, Float)] = []
    private var observers: [NSObjectProtocol] = []

    init() {
        UIDevice.current.isBatteryMonitoringEnabled = true
        let nc = NotificationCenter.default
        for name in [ProcessInfo.thermalStateDidChangeNotification, UIDevice.batteryStateDidChangeNotification, UIDevice.batteryLevelDidChangeNotification] {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.poll() }
            })
        }
        poll()
    }

    func poll() {
        thermal = ProcessInfo.processInfo.thermalState
        let d = UIDevice.current
        let level = d.batteryLevel
        switch d.batteryState {
        case .charging, .full: power = .mains(level: level >= 0 ? level : nil)
        case .unplugged: power = .battery(level: max(level, 0))
        default: power = .unknown
        }
        if level >= 0 {
            samples.append((Date(), level))
            samples.removeAll { Date().timeIntervalSince($0.0) > 900 }
            if let first = samples.first, let last = samples.last, last.0.timeIntervalSince(first.0) > 120 {
                let hours = last.0.timeIntervalSince(first.0) / 3600
                drainPerHour = Double(first.1 - last.1) * 100 / hours
            }
        }
    }

    var batteryLevel: Float? {
        switch power {
        case .mains(let l): l
        case .battery(let l): l
        case .unknown: nil
        }
    }

    var onMains: Bool { if case .mains = power { true } else { false } }

    /// Projected hours remaining while discharging.
    var projectedHours: Double? {
        guard case .battery(let level) = power, let drain = drainPerHour, drain > 0.1 else { return nil }
        return Double(level) * 100 / drain
    }

    var thermalLabel: String {
        switch thermal {
        case .nominal: "Nominal"
        case .fair: "Fair"
        case .serious: "Serious"
        case .critical: "Critical"
        @unknown default: "Unknown"
        }
    }
}

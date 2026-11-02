import Foundation

enum Topology: String, Codable, CaseIterable, Identifiable, Sendable {
    case consoleInsert = "A"
    case micInLineOut = "B"
    case groupInsert = "C"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .consoleInsert: "Console insert"
        case .micInLineOut: "Mic in / line out"
        case .groupInsert: "Group insert"
        }
    }

    var summary: String {
        switch self {
        case .consoleInsert: "Insert send → interface line in → RingOut → line out → insert return. Recommended."
        case .micInLineOut: "Mic → interface preamp → RingOut → line out → console line input. For desks without inserts."
        case .groupInsert: "Automix group insert. One channel handles a whole speech panel (up to 3 talkers)."
        }
    }

    func stripName(_ index: Int) -> String {
        switch self {
        case .consoleInsert: "Insert \(index + 1)"
        case .micInLineOut: "Mic \(index + 1)"
        case .groupInsert: "Group \(index + 1)"
        }
    }
}

enum Preset: Int, Codable, CaseIterable, Identifiable, Sendable {
    case speech = 0, singing = 1, custom = 2
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .speech: "Speech"
        case .singing: "Singing"
        case .custom: "Custom"
        }
    }
    /// Default Strength when the preset chip is tapped. Custom keeps the current value.
    var defaultStrength: Float? {
        switch self {
        case .speech: 0.8
        case .singing: 0.7
        case .custom: nil
        }
    }
}

enum ThermalPolicy: String, Codable, CaseIterable, Sendable {
    case autoStepUp, warnOnly
    var title: String { self == .autoStepUp ? "Auto step-up buffer" : "Warn only" }
}

struct FixedNotch: Codable, Hashable, Sendable {
    var frequency: Float
    var depth: Float
}

struct ChannelSettings: Codable, Hashable, Sendable {
    var name: String
    var strength: Float = 0.8
    var preset: Preset = .speech
    var highPass = true
    var inputTrimDB: Float = 0
    var fixedNotches: [FixedNotch] = []
}

struct InterfaceIdentity: Codable, Hashable, Sendable {
    var name: String
    var uid: String
    var portType: String
}

struct CalibrationResult: Codable, Hashable, Sendable {
    var measuredLatencySamples: Float?
    var sampleRate: Double
    var bufferFrames: Int
    var stressPassed: Bool
    var stressOverloads: Int
    var peakDSPLoad: Float
    var date: Date

    var measuredLatencyMS: Double? {
        measuredLatencySamples.map { Double($0) / sampleRate * 1000 }
    }
}

/// Everything needed to bring a venue back exactly as it was. JSON on disk.
struct ShowFile: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var name: String
    var modified = Date()
    var topology: Topology = .consoleInsert
    var channelCount = 2
    var channels: [ChannelSettings] = [ChannelSettings(name: "Insert 1"), ChannelSettings(name: "Insert 2")]
    var bufferFrames = 32
    var notchHoldSeconds: Float = 4
    var maxAutoNotches = 8
    var limiter = true
    var interface: InterfaceIdentity?
    var calibration: CalibrationResult?
    var simulated = false
    var lockPINHash: String?
    var autoLockMinutes = 0
    var allowBypassRelease = true
    var thermalPolicy: ThermalPolicy = .autoStepUp
    var batteryWarnHours: Double = 2
    var dimBooth = false

    static func makeDefault() -> ShowFile { ShowFile(name: "Untitled show") }

    static let validBuffers = [32, 64, 128]
}

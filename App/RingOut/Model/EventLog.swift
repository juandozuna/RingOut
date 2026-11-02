import Foundation
import Observation
import UIKit

struct LogEvent: Identifiable, Codable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable {
        case ring, deepen, release, pin, loopGain, route, overload, thermal, power, watchdog, session, info
    }
    var id = UUID()
    var date = Date()
    var kind: Kind
    var channel: Int?
    var frequency: Float?
    var confidence: Float?
    var depth: Float?
    var duration: Float?
    var message: String

    var symbol: String {
        switch kind {
        case .ring: "waveform.badge.exclamationmark"
        case .deepen: "arrow.down.to.line"
        case .release: "arrow.up.to.line"
        case .pin: "pin.fill"
        case .loopGain: "exclamationmark.triangle.fill"
        case .route: "cable.connector"
        case .overload: "exclamationmark.octagon"
        case .thermal: "thermometer.medium"
        case .power: "bolt.fill"
        case .watchdog: "dog.fill"
        case .session: "waveform"
        case .info: "info.circle"
        }
    }
}

/// One sample per second of the health metrics, kept for 10 minutes.
struct HealthSample: Codable, Hashable, Sendable {
    var date: Date
    var dspLoad: Float
    var overloads: Int
    var thermal: Int
    var bufferFrames: Int
    var battery: Float
}

@Observable
final class EventLog {
    private(set) var events: [LogEvent] = []
    private(set) var health: [HealthSample] = []
    private let maxEvents = 2000
    private let maxHealth = 600

    func add(_ e: LogEvent) {
        events.append(e)
        if events.count > maxEvents { events.removeFirst(events.count - maxEvents) }
    }

    func add(_ kind: LogEvent.Kind, _ message: String, channel: Int? = nil) {
        add(LogEvent(kind: kind, channel: channel, message: message))
    }

    func addHealth(_ s: HealthSample) {
        health.append(s)
        if health.count > maxHealth { health.removeFirst(health.count - maxHealth) }
    }

    struct Report: Codable {
        var generated: Date
        var app: String
        var device: String
        var system: String
        var show: ShowFile
        var events: [LogEvent]
        var health: [HealthSample]
    }

    /// Writes report JSON + PDF into a temp folder and returns both URLs.
    func exportReport(show: ShowFile, status: [String: String]) throws -> [URL] {
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("RingOut-report-\(stamp)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var redacted = show
        redacted.lockPINHash = redacted.lockPINHash == nil ? nil : "<set>"
        let report = Report(
            generated: Date(),
            app: "RingOut \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?")",
            device: UIDevice.current.model,
            system: "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)",
            show: redacted, events: events, health: health)
        let json = dir.appendingPathComponent("RingOut-report.json")
        try ShowStore.encoder.encode(report).write(to: json)
        let pdf = dir.appendingPathComponent("RingOut-report.pdf")
        try renderPDF(report: report, status: status).write(to: pdf)
        return [json, pdf]
    }

    private func renderPDF(report: Report, status: [String: String]) -> Data {
        let page = CGRect(x: 0, y: 0, width: 612, height: 792)
        let renderer = UIGraphicsPDFRenderer(bounds: page)
        let df = DateFormatter()
        df.dateStyle = .short
        df.timeStyle = .medium
        return renderer.pdfData { ctx in
            var y: CGFloat = 0
            func newPage() { ctx.beginPage(); y = 48 }
            func line(_ text: String, size: CGFloat = 10, bold: Bool = false, color: UIColor = .black) {
                if y > page.height - 48 { newPage() }
                let font = bold ? UIFont.boldSystemFont(ofSize: size) : UIFont.monospacedSystemFont(ofSize: size, weight: .regular)
                (text as NSString).draw(at: CGPoint(x: 48, y: y), withAttributes: [.font: font, .foregroundColor: color])
                y += size * 1.5
            }
            newPage()
            line("RingOut diagnostics report", size: 20, bold: true)
            line("\(report.app) · \(report.device) · \(report.system)")
            line("Generated \(df.string(from: report.generated))")
            y += 8
            line("Status", size: 14, bold: true)
            for k in status.keys.sorted() { line("\(k): \(status[k] ?? "")") }
            y += 8
            line("Show: \(report.show.name)", size: 14, bold: true)
            line("Topology \(report.show.topology.rawValue) (\(report.show.topology.title)), \(report.show.channelCount) channel(s), buffer \(report.show.bufferFrames)")
            if let c = report.show.calibration {
                line("Calibration: latency \(c.measuredLatencyMS.map { String(format: "%.2f ms", $0) } ?? "not measured"), stress \(c.stressPassed ? "passed" : "failed") (\(c.stressOverloads) overloads)")
            }
            y += 8
            line("Events (\(report.events.count))", size: 14, bold: true)
            for e in report.events.suffix(400) {
                var s = "\(df.string(from: e.date))  \(e.kind.rawValue.padding(toLength: 9, withPad: " ", startingAt: 0))"
                if let c = e.channel { s += " ch\(c + 1)" }
                s += "  \(e.message)"
                line(s, size: 8)
            }
        }
    }
}

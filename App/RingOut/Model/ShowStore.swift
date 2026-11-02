import Foundation
import Observation

/// Show files live as JSON in Documents/Shows (visible in the Files app),
/// optionally mirrored to the iCloud Drive container when the build has one.
@Observable
final class ShowStore {
    private(set) var shows: [ShowFile] = []
    var iCloudEnabled: Bool {
        didSet { UserDefaults.standard.set(iCloudEnabled, forKey: "iCloudShows"); if iCloudEnabled { mirrorAll() } }
    }
    let iCloudAvailable: Bool
    private let ubiquityURL: URL?

    static let lastShowKey = "lastShowID"

    private let directory: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("Shows", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    init() {
        ubiquityURL = FileManager.default.url(forUbiquityContainerIdentifier: nil)?.appendingPathComponent("Documents/Shows")
        iCloudAvailable = ubiquityURL != nil
        iCloudEnabled = UserDefaults.standard.bool(forKey: "iCloudShows")
        reload()
    }

    func reload() {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        shows = files.filter { $0.pathExtension == "json" }
            .compactMap { try? Self.decoder.decode(ShowFile.self, from: Data(contentsOf: $0)) }
            .sorted { $0.modified > $1.modified }
    }

    func url(for show: ShowFile) -> URL {
        directory.appendingPathComponent("\(show.id.uuidString).json")
    }

    func save(_ show: ShowFile) throws {
        var s = show
        s.modified = Date()
        let data = try Self.encoder.encode(s)
        try data.write(to: url(for: s), options: .atomic)
        UserDefaults.standard.set(s.id.uuidString, forKey: Self.lastShowKey)
        if iCloudEnabled { mirror(s, data: data) }
        reload()
    }

    func duplicate(_ show: ShowFile) throws {
        var copy = show
        copy.id = UUID()
        copy.name = show.name + " copy"
        try save(copy)
    }

    func delete(_ show: ShowFile) {
        try? FileManager.default.removeItem(at: url(for: show))
        reload()
    }

    /// Parses a show file from Files. Throws on malformed JSON, never crashes.
    func importShow(from url: URL) throws -> ShowFile {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        var show = try Self.decode(Data(contentsOf: url))
        show.id = UUID()
        try save(show)
        return show
    }

    static func decode(_ data: Data) throws -> ShowFile {
        var show = try decoder.decode(ShowFile.self, from: data)
        show.channelCount = min(max(show.channelCount, 1), 2)
        if !ShowFile.validBuffers.contains(show.bufferFrames) { show.bufferFrames = 64 }
        while show.channels.count < 2 { show.channels.append(ChannelSettings(name: show.topology.stripName(show.channels.count))) }
        for i in show.channels.indices {
            show.channels[i].strength = min(max(show.channels[i].strength, 0), 1)
            show.channels[i].fixedNotches = Array(show.channels[i].fixedNotches.prefix(4))
        }
        show.notchHoldSeconds = min(max(show.notchHoldSeconds, 2), 10)
        show.maxAutoNotches = min(max(show.maxAutoNotches, 4), 8)
        return show
    }

    func lastShow() -> ShowFile? {
        guard let id = UserDefaults.standard.string(forKey: Self.lastShowKey) else { return nil }
        return shows.first { $0.id.uuidString == id }
    }

    private func mirror(_ show: ShowFile, data: Data) {
        guard let ubiquityURL else { return }
        try? FileManager.default.createDirectory(at: ubiquityURL, withIntermediateDirectories: true)
        try? data.write(to: ubiquityURL.appendingPathComponent("\(show.name)-\(show.id.uuidString.prefix(8)).json"))
    }

    private func mirrorAll() {
        for s in shows { if let d = try? Self.encoder.encode(s) { mirror(s, data: d) } }
    }
}

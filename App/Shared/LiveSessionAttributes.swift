import ActivityKit
import Foundation

/// Lock-screen Live Activity shown while RingOut is processing ("Live — 2 channels active").
nonisolated struct LiveSessionAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var channels: Int
        /// Worst channel state: 0 safe, 1 working, 2 ring, 3 bypass.
        var state: Int
        var latencyMS: Double
        var activeNotches: Int
    }

    var showName: String
    var interfaceName: String
}

import SwiftUI

/// Design tokens from the PRD design system. Dark only, stage-safe.
enum Tokens {
    enum Color {
        static let bgBase = SwiftUI.Color(hex: 0x0B0D10)
        static let bgStrip = SwiftUI.Color(hex: 0x14171C)
        static let bgElevated = SwiftUI.Color(hex: 0x1C2027)
        static let safe = SwiftUI.Color(hex: 0x2BD576)
        static let working = SwiftUI.Color(hex: 0xF2B544)
        static let ring = SwiftUI.Color(hex: 0xFF4D4D)
        static let bypass = SwiftUI.Color(hex: 0x7D8794)
        static let meterGreen = SwiftUI.Color(hex: 0x3DDC84)
        static let meterAmber = SwiftUI.Color(hex: 0xF2B544)
        static let meterRed = SwiftUI.Color(hex: 0xFF4D4D)
        static let textPrimary = SwiftUI.Color(hex: 0xF5F7FA)
        static let textSecondary = SwiftUI.Color(hex: 0x9AA4B2)
        static let accent = SwiftUI.Color(hex: 0x4DA3FF)
        static let hairline = SwiftUI.Color.white.opacity(0.08)
    }

    enum Size {
        static let liveTarget: CGFloat = 64
        static let target: CGFloat = 44
        static let dial: CGFloat = 160
        static let setupRing: CGFloat = 240
        static let banner: CGFloat = 56
        static let meterWidth: CGFloat = 24
        static let radius: CGFloat = 20
    }

    enum Font {
        static func numeral(_ size: CGFloat, weight: SwiftUI.Font.Weight = .semibold) -> SwiftUI.Font {
            .system(size: size, weight: weight, design: .rounded).monospacedDigit()
        }
        static func label(_ size: CGFloat, weight: SwiftUI.Font.Weight = .semibold) -> SwiftUI.Font {
            .system(size: size, weight: weight, design: .rounded)
        }
        static func body(_ size: CGFloat = 17, weight: SwiftUI.Font.Weight = .regular) -> SwiftUI.Font {
            .system(size: size, weight: weight, design: .default)
        }
        static let title = label(34, weight: .bold)
        static let headline = label(28, weight: .bold)
        static let subhead = label(22)
    }
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: opacity)
    }
}

/// Channel state as shown to the operator.
enum ChannelState: Int, Sendable {
    case safe = 0, working = 1, ring = 2, bypass = 3

    var color: Color {
        switch self {
        case .safe: Tokens.Color.safe
        case .working: Tokens.Color.working
        case .ring: Tokens.Color.ring
        case .bypass: Tokens.Color.bypass
        }
    }

    var label: String {
        switch self {
        case .safe: "Stable"
        case .working: "Working"
        case .ring: "Ring caught"
        case .bypass: "Bypassed"
        }
    }
}

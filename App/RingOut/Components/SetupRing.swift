import SwiftUI

enum RingState { case searching, found, warning, failed }

/// Hue-style device ring (240 pt). The ring colour is the state.
struct SetupRing<Content: View>: View {
    var state: RingState
    @ViewBuilder var content: Content
    @State private var spin = false

    private var color: Color {
        switch state {
        case .searching: Tokens.Color.accent
        case .found: Tokens.Color.safe
        case .warning: Tokens.Color.working
        case .failed: Tokens.Color.ring
        }
    }

    var body: some View {
        ZStack {
            Circle().fill(color.opacity(0.08))
            Circle().stroke(color.opacity(0.25), lineWidth: 10)
            if state == .searching {
                Circle()
                    .trim(from: 0, to: 0.22)
                    .stroke(color, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                    .rotationEffect(.degrees(spin ? 360 : 0))
                    .animation(.linear(duration: 1.4).repeatForever(autoreverses: false), value: spin)
            } else {
                Circle().stroke(color, lineWidth: 10)
            }
            content
        }
        .frame(width: Tokens.Size.setupRing, height: Tokens.Size.setupRing)
        .onAppear { spin = true }
    }
}

/// Illustration of iPad + hub + interface drawn with SF Symbols.
struct RigIllustration: View {
    var highlight: Int? = nil  // 0 iPad, 1 hub/PD, 2 interface
    var tint: Color = Tokens.Color.textPrimary

    var body: some View {
        HStack(spacing: 10) {
            symbol("ipad.landscape", 0)
            connector
            symbol("cable.connector.horizontal", 1)
            connector
            symbol("slider.vertical.3", 2)
        }
    }

    private var connector: some View {
        Capsule().fill(Tokens.Color.textSecondary.opacity(0.5)).frame(width: 14, height: 3)
    }

    private func symbol(_ name: String, _ index: Int) -> some View {
        Image(systemName: name)
            .font(.system(size: 36, weight: .medium))
            .foregroundStyle(highlight == index ? Tokens.Color.accent : tint)
    }
}

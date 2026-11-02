import SwiftUI

/// 64 pt pill used live. `holdToEngage` requires a 0.5 s press to turn ON
/// (Mute), turning off is a single tap.
struct BigButton: View {
    var title: String
    var systemImage: String
    var isOn: Bool
    var onColor: Color
    var holdToEngage = false
    var enabled = true
    var action: () -> Void

    @State private var pressing = false

    var body: some View {
        let shape = Capsule()
        let label = HStack(spacing: 10) {
            Image(systemName: systemImage).font(.system(size: 20, weight: .bold))
            Text(title).font(Tokens.Font.label(20, weight: .bold))
        }
        .foregroundStyle(isOn ? Color.black : Tokens.Color.textPrimary)
        .frame(maxWidth: .infinity, minHeight: Tokens.Size.liveTarget)
        .background(
            ZStack(alignment: .leading) {
                shape.fill(isOn ? onColor : Tokens.Color.bgElevated)
                if holdToEngage && !isOn {
                    GeometryReader { g in
                        shape.fill(onColor.opacity(0.45))
                            .frame(width: pressing ? g.size.width : 0)
                            .animation(pressing ? .linear(duration: 0.5) : .easeOut(duration: 0.15), value: pressing)
                    }
                }
            }
        )
        .overlay(shape.stroke(isOn ? Color.clear : Tokens.Color.hairline, lineWidth: 1))
        .contentShape(shape)
        .opacity(enabled ? 1 : 0.4)

        if holdToEngage && !isOn {
            label
                .accessibilityElement(children: .ignore)
                .onLongPressGesture(minimumDuration: 0.5, perform: { if enabled { action() } }, onPressingChanged: { pressing = $0 && enabled })
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel(title)
                .accessibilityHint("Hold to engage")
                .accessibilityAction { if enabled { action() } }
        } else {
            label
                .accessibilityElement(children: .ignore)
                .onTapGesture { if enabled { action() } }
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel(title)
                .accessibilityValue(isOn ? "On" : "Off")
                .accessibilityAction { if enabled { action() } }
        }
    }
}

/// Small pill chip (presets, filters).
struct Chip: View {
    var title: String
    var selected: Bool
    var enabled = true
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Tokens.Font.label(15))
                .foregroundStyle(selected ? Color.black : Tokens.Color.textPrimary)
                .padding(.horizontal, 16)
                .frame(minHeight: Tokens.Size.target)
                .background(Capsule().fill(selected ? Tokens.Color.accent : Tokens.Color.bgElevated))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
    }
}

struct PrimaryButton: View {
    var title: String
    var systemImage: String? = nil
    var color: Color = Tokens.Color.accent
    var enabled = true
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let systemImage { Image(systemName: systemImage) }
                Text(title)
            }
            .font(Tokens.Font.label(19, weight: .bold))
            .foregroundStyle(Color.black)
            .padding(.horizontal, 28)
            .frame(minHeight: 56)
            .background(Capsule().fill(enabled ? color : Tokens.Color.bypass))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

/// "Audio still running" indicator shown in the corner of every modal.
struct AudioRunningBadge: View {
    var running: Bool
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(running ? Tokens.Color.safe : Tokens.Color.ring)
                .frame(width: 10, height: 10)
                .scaleEffect(pulse ? 1.25 : 0.85)
                .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: pulse)
            Text(running ? "Audio still running" : "Audio stopped")
                .font(Tokens.Font.label(13))
                .foregroundStyle(Tokens.Color.textSecondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Capsule().fill(Color.black.opacity(0.5)))
        .onAppear { pulse = true }
        .accessibilityElement(children: .combine)
    }
}

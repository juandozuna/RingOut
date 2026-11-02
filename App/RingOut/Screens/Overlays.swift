import SwiftUI

/// S8 — Interface disconnected.
struct DisconnectedOverlay: View {
    @Environment(AppModel.self) private var app
    let disconnect: AppModel.Disconnect

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let elapsed = ctx.date.timeIntervalSince(disconnect.since)
            VStack(spacing: 28) {
                SetupRing(state: .failed) {
                    Image(systemName: "cable.connector.slash").font(.system(size: 64, weight: .semibold)).foregroundStyle(Tokens.Color.ring)
                }
                Text("\(disconnect.name) disconnected").font(Tokens.Font.title).foregroundStyle(Tokens.Color.textPrimary)
                Text("Output is muted. Reconnect the interface and audio resumes automatically.")
                    .font(Tokens.Font.body(19)).foregroundStyle(Tokens.Color.textSecondary)
                Text("\(Int(elapsed)) s").font(Tokens.Font.numeral(22)).foregroundStyle(Tokens.Color.textSecondary)
                if elapsed >= 10 {
                    Button("Use a different interface") { app.useDifferentInterface() }
                        .font(Tokens.Font.label(17))
                        .foregroundStyle(Tokens.Color.accent)
                        .frame(minHeight: Tokens.Size.target)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Tokens.Color.ring.opacity(0.22).background(.ultraThinMaterial))
            .background(Tokens.Color.bgBase.opacity(0.85))
        }
        .accessibilityIdentifier("disconnectedOverlay")
    }
}

/// 1 s green confirmation after reconnect.
struct ReconnectedFlash: View {
    var body: some View {
        VStack(spacing: 20) {
            SetupRing(state: .found) {
                Image(systemName: "checkmark").font(.system(size: 72, weight: .bold)).foregroundStyle(Tokens.Color.safe)
            }
            Text("Interface back — audio resumed").font(Tokens.Font.headline).foregroundStyle(Tokens.Color.textPrimary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Tokens.Color.safe.opacity(0.18).background(.ultraThinMaterial))
    }
}

/// S9 — Locked. Meters, spectrum and state colours stay visible underneath;
/// this layer swallows touches and offers the PIN pad and the safety bypass.
struct LockOverlay: View {
    @Environment(AppModel.self) private var app
    @State private var showPad = false
    @State private var pin = ""
    @State private var wrong = false
    @State private var holding = false

    var body: some View {
        ZStack {
            Color.black.opacity(showPad ? 0.55 : 0.18)
                .contentShape(Rectangle())
                .onTapGesture { showPad = true }
            if showPad {
                pinPad
            } else {
                VStack {
                    Spacer()
                    HStack(spacing: 18) {
                        Label("Locked — tap to unlock", systemImage: "lock.fill")
                            .font(Tokens.Font.label(17))
                            .foregroundStyle(Tokens.Color.textPrimary)
                            .padding(.horizontal, 18).frame(minHeight: 48)
                            .background(Capsule().fill(Tokens.Color.bgElevated))
                        if app.show.allowBypassRelease {
                            Text(holding ? "Keep holding…" : "Hold 2 s to bypass all")
                                .font(Tokens.Font.label(17))
                                .foregroundStyle(Color.black)
                                .padding(.horizontal, 18).frame(minHeight: 48)
                                .background(Capsule().fill(Tokens.Color.bypass))
                                .onLongPressGesture(minimumDuration: 2, perform: { app.safetyBypass() }, onPressingChanged: { holding = $0 })
                                .accessibilityIdentifier("safetyBypass")
                        }
                    }
                    .padding(.bottom, 28)
                }
            }
        }
        .accessibilityIdentifier("lockOverlay")
    }

    private var pinPad: some View {
        VStack(spacing: 20) {
            Text("Enter PIN").font(Tokens.Font.headline).foregroundStyle(Tokens.Color.textPrimary)
            HStack(spacing: 14) {
                ForEach(0..<max(4, pin.count), id: \.self) { i in
                    Circle().fill(i < pin.count ? Tokens.Color.accent : Tokens.Color.bgElevated).frame(width: 18, height: 18)
                }
            }
            .modifier(Shake(animatableData: wrong ? 1 : 0))
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(88), spacing: 16), count: 3), spacing: 16) {
                ForEach(["1", "2", "3", "4", "5", "6", "7", "8", "9", "⌫", "0", "OK"], id: \.self) { key in
                    Button { press(key) } label: {
                        Text(key).font(Tokens.Font.numeral(30, weight: .semibold))
                            .foregroundStyle(key == "OK" ? Color.black : Tokens.Color.textPrimary)
                            .frame(width: 88, height: 88)
                            .background(Circle().fill(key == "OK" ? Tokens.Color.accent : Tokens.Color.bgElevated))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("pin_\(key)")
                }
            }
            Button("Cancel") { showPad = false; pin = "" }.foregroundStyle(Tokens.Color.textSecondary).frame(minHeight: Tokens.Size.target)
        }
        .padding(32)
        .background(RoundedRectangle(cornerRadius: 28).fill(Tokens.Color.bgStrip))
    }

    private func press(_ key: String) {
        switch key {
        case "⌫": if !pin.isEmpty { pin.removeLast() }
        case "OK":
            if app.unlock(pin: pin) { pin = ""; showPad = false }
            else { withAnimation(.default) { wrong.toggle() }; pin = "" }
        default: if pin.count < 8 { pin.append(key) }
        }
    }
}

struct Shake: GeometryEffect {
    var animatableData: CGFloat
    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: 10 * sin(animatableData * .pi * 6), y: 0))
    }
}

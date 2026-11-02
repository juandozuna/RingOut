import SwiftUI

/// S3 — Live (home).
struct LiveView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(spacing: 0) {
            StatusBanner()
            ForEach(app.banners) { banner in
                BannerRow(banner: banner) { app.performBannerAction(banner.id) }
            }
            HStack(spacing: 16) {
                ChannelStrip(channel: 0)
                ChannelStrip(channel: 1)
            }
            .padding(16)
            if app.show.simulated {
                SimulatedRoomBar()
            }
        }
        .background(Tokens.Color.bgBase)
        .background(TwoFingerSwipeDown { app.showSettings = true })
        .simultaneousGesture(TapGesture().onEnded { app.touch() })
    }
}

struct BannerRow: View {
    var banner: AppModel.Banner
    var action: () -> Void

    var body: some View {
        let color: Color = switch banner.level {
        case .critical: Tokens.Color.ring
        case .warning: Tokens.Color.working
        case .info: Tokens.Color.accent
        }
        HStack(spacing: 12) {
            Image(systemName: banner.level == .info ? "info.circle.fill" : "exclamationmark.triangle.fill")
            Text(banner.text).font(Tokens.Font.label(15)).lineLimit(2)
            Spacer()
            if let title = banner.actionTitle {
                Button(title, action: action)
                    .font(Tokens.Font.label(15, weight: .bold))
                    .buttonStyle(.plain)
                    .padding(.horizontal, 14)
                    .frame(minHeight: 36)
                    .background(Capsule().fill(Color.black.opacity(0.25)))
            }
        }
        .foregroundStyle(Color.black)
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background(color)
    }
}

/// Demo-mode control bar: drive the simulated room so the engine has
/// something to fight. "Console gain" is relative to where bypass starts ringing.
struct SimulatedRoomBar: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        HStack(spacing: 24) {
            Label("Simulated room", systemImage: "waveform.badge.magnifyingglass")
                .font(Tokens.Font.label(15))
                .foregroundStyle(Tokens.Color.textSecondary)
            ForEach(0..<app.effectiveChannels, id: \.self) { ch in
                HStack(spacing: 10) {
                    Text("Ch \(ch + 1) gain").font(Tokens.Font.label(13)).foregroundStyle(Tokens.Color.textSecondary).fixedSize()
                    Slider(value: Binding(get: { app.simLoopGain[ch] }, set: { app.setSimLoopGain($0, channel: ch) }), in: -12...9, step: 0.5)
                        .tint(app.simLoopGain[ch] > 0 ? Tokens.Color.ring : Tokens.Color.accent)
                        .frame(width: 170)
                        .accessibilityIdentifier("simGain\(ch + 1)")
                    Text(String(format: "%+.1f dB", app.simLoopGain[ch]))
                        .font(Tokens.Font.numeral(15))
                        .foregroundStyle(app.simLoopGain[ch] > 0 ? Tokens.Color.ring : Tokens.Color.textPrimary)
                        .frame(width: 70, alignment: .leading)
                    Menu {
                        Button("Speech") { app.setSimSource(RO_SIM_SPEECH, channel: ch) }
                        Button("Singing") { app.setSimSource(RO_SIM_SINGING, channel: ch) }
                        Button("Room only") { app.setSimSource(RO_SIM_SILENCE, channel: ch) }
                    } label: {
                        Text(sourceName(app.simSource[ch]))
                            .font(Tokens.Font.label(13))
                            .fixedSize()
                            .padding(.horizontal, 10).frame(minHeight: 32)
                            .background(Capsule().fill(Tokens.Color.bgElevated))
                    }
                }
            }
            Spacer()
            @Bindable var app = app
            Toggle(isOn: $app.monitorAudible) {
                Label("Listen", systemImage: "speaker.wave.2.fill").font(Tokens.Font.label(13))
            }
            .toggleStyle(.button)
            .tint(Tokens.Color.accent)
        }
        .padding(.horizontal, 20)
        .frame(height: 56)
        .background(Tokens.Color.bgStrip)
    }

    private func sourceName(_ s: ro_sim_source) -> String {
        switch s {
        case RO_SIM_SINGING: "Singing"
        case RO_SIM_SILENCE: "Room only"
        default: "Speech"
        }
    }
}

/// Installs a two-finger swipe-down recognizer on the hosting window without
/// stealing touches from the controls.
struct TwoFingerSwipeDown: UIViewRepresentable {
    var action: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(action: action) }

    func makeUIView(context: Context) -> UIView {
        let v = HookView()
        v.coordinator = context.coordinator
        return v
    }

    func updateUIView(_ uiView: UIView, context: Context) { context.coordinator.action = action }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var action: () -> Void
        weak var recognizer: UISwipeGestureRecognizer?
        init(action: @escaping () -> Void) { self.action = action }
        @objc func fire() { action() }
        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
    }

    final class HookView: UIView {
        weak var coordinator: Coordinator?
        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard let window, let coordinator, coordinator.recognizer == nil else { return }
            let g = UISwipeGestureRecognizer(target: coordinator, action: #selector(Coordinator.fire))
            g.direction = .down
            g.numberOfTouchesRequired = 2
            g.cancelsTouchesInView = false
            g.delegate = coordinator
            window.addGestureRecognizer(g)
            coordinator.recognizer = g
        }
        override func willMove(toWindow newWindow: UIWindow?) {
            if newWindow == nil, let g = coordinator?.recognizer { g.view?.removeGestureRecognizer(g) }
            super.willMove(toWindow: newWindow)
        }
    }
}

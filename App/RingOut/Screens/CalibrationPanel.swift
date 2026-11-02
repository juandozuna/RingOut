import SwiftUI

/// Shared by wizard step 4 and the S4 sheet.
struct CalibrationPanel: View {
    @Environment(AppModel.self) private var app
    @Bindable var calibrator: Calibrator

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                HStack(alignment: .top, spacing: 16) {
                    ForEach(0..<app.effectiveChannels, id: \.self) { ch in signalCard(ch) }
                }
                HStack(alignment: .top, spacing: 16) {
                    latencyCard
                    stressCard
                }
            }
            .padding(.horizontal, 40)
            .padding(.vertical, 20)
        }
    }

    private func card<C: View>(_ title: String, _ systemImage: String, done: Bool, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label(title, systemImage: systemImage).font(Tokens.Font.subhead).foregroundStyle(Tokens.Color.textPrimary)
                Spacer()
                if done { Image(systemName: "checkmark.circle.fill").font(.system(size: 24)).foregroundStyle(Tokens.Color.safe) }
            }
            content()
        }
        .padding(20)
        .frame(maxWidth: .infinity, minHeight: 230, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 20).fill(Tokens.Color.bgStrip))
    }

    private func signalCard(_ ch: Int) -> some View {
        let snap = app.snapshots[ch]
        return card("Send signal · \(app.show.channels[ch].name)", "waveform", done: calibrator.signalOK(ch)) {
            Text(app.show.simulated ? "The simulated talker is feeding this input." : "Talk or play program into this channel from the console. Aim for peaks around −18 dBFS.")
                .font(Tokens.Font.body(15)).foregroundStyle(Tokens.Color.textSecondary)
            GeometryReader { g in
                let w = g.size.width
                let x: (Float) -> CGFloat = { db in CGFloat(min(max((db + 60) / 60, 0), 1)) * w }
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.black.opacity(0.4))
                    Rectangle().fill(Tokens.Color.safe.opacity(0.25)).frame(width: x(-6) - x(-24)).offset(x: x(-24))
                    Capsule().fill(snap.inputPeak > -6 ? Tokens.Color.meterRed : Tokens.Color.meterGreen).frame(width: max(x(snap.inputPeak), 4))
                    Rectangle().fill(Tokens.Color.textPrimary).frame(width: 2).offset(x: x(-18))
                }
            }
            .frame(height: 28)
            HStack {
                Text(String(format: "%.0f dBFS", max(snap.inputPeak, -99))).font(Tokens.Font.numeral(28, weight: .bold)).foregroundStyle(Tokens.Color.textPrimary)
                Spacer()
                Text(calibrator.signalOK(ch) ? "In the target band" : "Target −18 dBFS")
                    .font(Tokens.Font.label(15)).foregroundStyle(calibrator.signalOK(ch) ? Tokens.Color.safe : Tokens.Color.textSecondary)
            }
        }
    }

    private var latencyCard: some View {
        card("Measure latency", "timer", done: { if case .measured = calibrator.latency { true } else { false } }()) {
            Text(app.show.simulated ? "The simulated rig has no loopback cable, so this shows the Core Audio estimate." : "Patch the loopback cable from Out 2 to In 2, then measure. Five clicks, about 4 seconds.")
                .font(Tokens.Font.body(15)).foregroundStyle(Tokens.Color.textSecondary)
            switch calibrator.latency {
            case .idle:
                PrimaryButton(title: "Measure", systemImage: "play.fill") { calibrator.measureLatency() }
            case .measuring:
                HStack(spacing: 12) { ProgressView().tint(Tokens.Color.accent); Text("Listening for clicks…").foregroundStyle(Tokens.Color.textSecondary) }
            case .measured(let s), .estimated(let s):
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(String(format: "%.2f ms", Double(s) / app.audio.sampleRate * 1000))
                        .font(Tokens.Font.numeral(34, weight: .bold)).foregroundStyle(Tokens.Color.textPrimary)
                    Text("\(Int(s)) samples\({ if case .estimated = calibrator.latency { " · estimated" } else { "" } }())")
                        .font(Tokens.Font.label(15)).foregroundStyle(Tokens.Color.textSecondary)
                }
                .accessibilityIdentifier("latencyResult")
                Button("Measure again") { calibrator.measureLatency() }.foregroundStyle(Tokens.Color.accent)
            case .failed:
                Text("No clicks came back. Check the cable is Out 2 → In 2 and the input gain is up.")
                    .font(Tokens.Font.body(15)).foregroundStyle(Tokens.Color.working)
                PrimaryButton(title: "Try again", systemImage: "arrow.clockwise") { calibrator.measureLatency() }
            }
        }
    }

    private var stressCard: some View {
        card("Stress test", "flame", done: calibrator.stress == .passed) {
            Text("Runs the engine at \(app.audio.actualFrames) samples for \(calibrator.proMode ? "10 minutes" : "60 seconds"). Passes with zero overloads.")
                .font(Tokens.Font.body(15)).foregroundStyle(Tokens.Color.textSecondary)
            LoadGraph(values: calibrator.stressLoad, maxCount: Int(calibrator.stressDuration * 4))
                .frame(height: 60)
            HStack {
                Text("DSP peak \(Int(calibrator.peakLoad * 100))% · overloads \(calibrator.stressOverloads)")
                    .font(Tokens.Font.numeral(15)).foregroundStyle(Tokens.Color.textSecondary)
                Spacer()
                Toggle("Pro (10 min)", isOn: $calibrator.proMode).fixedSize().disabled(calibrator.stress == .running)
                    .font(Tokens.Font.label(13)).tint(Tokens.Color.accent)
            }
            switch calibrator.stress {
            case .idle:
                PrimaryButton(title: "Start stress test", systemImage: "play.fill") { calibrator.runStress() }
                    .accessibilityIdentifier("startStress")
            case .running:
                ProgressView(value: calibrator.stressProgress).tint(Tokens.Color.accent)
            case .passed:
                Label("Passed", systemImage: "checkmark.seal.fill").font(Tokens.Font.label(17)).foregroundStyle(Tokens.Color.safe)
            case .failed(let msg):
                Text(msg).font(Tokens.Font.body(15)).foregroundStyle(Tokens.Color.working)
                PrimaryButton(title: "Run again", systemImage: "arrow.clockwise") { calibrator.runStress() }
            }
        }
    }
}

struct LoadGraph: View {
    var values: [Float]
    var maxCount: Int
    var color: Color = Tokens.Color.accent
    var ceiling: Float = 1

    var body: some View {
        Canvas { ctx, size in
            ctx.fill(Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 8), with: .color(.black.opacity(0.35)))
            let y40 = size.height * CGFloat(1 - 0.4 / ceiling)
            ctx.stroke(Path { p in p.move(to: CGPoint(x: 0, y: y40)); p.addLine(to: CGPoint(x: size.width, y: y40)) },
                       with: .color(Tokens.Color.working.opacity(0.5)), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
            guard values.count > 1 else { return }
            let n = max(maxCount, values.count)
            var path = Path()
            for (i, v) in values.enumerated() {
                let pt = CGPoint(x: CGFloat(i) / CGFloat(n - 1) * size.width, y: size.height * CGFloat(1 - min(v / ceiling, 1)))
                i == 0 ? path.move(to: pt) : path.addLine(to: pt)
            }
            ctx.stroke(path, with: .color(color), lineWidth: 1.5)
        }
    }
}

/// S4 — Calibration re-run from Settings, presented over Live.
struct CalibrationSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var calibrator: Calibrator?

    var body: some View {
        NavigationStack {
            Group {
                if let calibrator { CalibrationPanel(calibrator: calibrator) }
            }
            .background(Tokens.Color.bgBase)
            .navigationTitle("Calibration")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { AudioRunningBadge(running: app.audio.isRunning) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        if let c = calibrator { c.stop(); app.storeCalibration(c.result()) }
                        dismiss()
                    }
                }
            }
        }
        .onAppear { calibrator = Calibrator(app: app) }
    }
}

import SwiftUI

/// S2 — Setup wizard: Connect · Wiring · Checks · Calibrate · Done.
struct SetupWizardView: View {
    @Environment(AppModel.self) private var app
    @State private var step = 0
    @State private var draft = ShowFile.makeDefault()
    @State private var directMonitorOff = false
    @State private var saveName = ""
    @State private var calibrator: Calibrator?
    @State private var startError: String?

    private let titles = ["Connect hardware", "Choose wiring", "Check settings", "Calibrate", "Done"]

    var body: some View {
        VStack(spacing: 0) {
            header
            ZStack {
                switch step {
                case 0: ConnectStep(draft: $draft)
                case 1: WiringStep(draft: $draft)
                case 2: ChecksStep(draft: draft, directMonitorOff: $directMonitorOff)
                case 3: if let calibrator { CalibrationPanel(calibrator: calibrator) }
                default: DoneStep(draft: draft, saveName: $saveName)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .opacity))
            footer
        }
        .background(Tokens.Color.bgBase)
        .overlay(alignment: .topTrailing) {
            if app.audio.isRunning { AudioRunningBadge(running: true).padding(16) }
        }
        .gesture(DragGesture(minimumDistance: 60).onEnded { g in
            if g.translation.width < -120, canAdvance { advance() }
            if g.translation.width > 120, step > 0 { withAnimation { step -= 1 } }
        })
        .onAppear {
            draft = app.show
            if draft.name == "Untitled show" { saveName = "" } else { saveName = draft.name }
        }
        .alert("Audio couldn’t start", isPresented: Binding(get: { startError != nil }, set: { if !$0 { startError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(startError ?? "") }
    }

    private var header: some View {
        VStack(spacing: 14) {
            HStack {
                Text("Step \(step + 1) of 5 · \(titles[step])")
                    .font(Tokens.Font.label(15))
                    .foregroundStyle(Tokens.Color.textSecondary)
                Spacer()
            }
            HStack(spacing: 8) {
                ForEach(0..<5) { i in
                    Capsule().fill(i <= step ? Tokens.Color.accent : Tokens.Color.bgElevated).frame(height: 5)
                }
            }
            ChecklistChips(done: step >= 4 ? 3 : min(step, 2))
        }
        .padding(.horizontal, 40)
        .padding(.top, 24)
    }

    private var footer: some View {
        HStack {
            if step > 0 {
                Button { withAnimation { step -= 1 } } label: {
                    Label("Back", systemImage: "chevron.left").font(Tokens.Font.label(17))
                        .frame(minHeight: Tokens.Size.target)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Tokens.Color.textSecondary)
            } else {
                Button("Cancel") { app.phase = UserDefaults.standard.bool(forKey: AppModel.setupCompleteKey) ? .live : .welcome }
                    .font(Tokens.Font.label(17))
                    .foregroundStyle(Tokens.Color.textSecondary)
                    .frame(minHeight: Tokens.Size.target)
            }
            Spacer()
            if step < 4 {
                PrimaryButton(title: step == 3 ? "Finish" : "Next", systemImage: "arrow.right", enabled: canAdvance) { advance() }
                    .accessibilityIdentifier("wizardNext")
            } else {
                PrimaryButton(title: "Go live", systemImage: "dot.radiowaves.left.and.right", color: Tokens.Color.safe) {
                    calibrator?.stop()
                    app.finishSetup(with: app.show, saveAs: saveName.isEmpty ? nil : saveName)
                }
                .accessibilityIdentifier("goLive")
            }
        }
        .padding(.horizontal, 40)
        .padding(.vertical, 24)
    }

    private var canAdvance: Bool {
        switch step {
        case 0:
            if draft.simulated { return true }
            if case .found = app.audio.interfaceStatus { return true }
            return false
        case 2: return draft.simulated || directMonitorOff
        default: return true
        }
    }

    private func advance() {
        switch step {
        case 0:
            if case .found(let p) = app.audio.interfaceStatus, !draft.simulated {
                draft.interface = InterfaceIdentity(name: p.name, uid: p.uid, portType: p.portType)
            } else if draft.simulated {
                draft.interface = nil
            }
            if !app.stage(draft, startAudio: true) {
                startError = app.lastStartError ?? "Unknown error"
                return
            }
        case 1, 2:
            app.stage(draft, startAudio: true)
            if step == 2 { calibrator = Calibrator(app: app) }
        case 3:
            calibrator?.stop()
            if let r = calibrator?.result() { app.storeCalibration(r) }
            draft = app.show
        default: break
        }
        withAnimation(.easeOut(duration: 0.25)) { step += 1 }
    }
}

// MARK: - Step 1

private struct ConnectStep: View {
    @Environment(AppModel.self) private var app
    @Binding var draft: ShowFile

    var body: some View {
        let status = draft.simulated ? .simulated : app.audio.interfaceStatus
        VStack(spacing: 28) {
            SetupRing(state: ringState(status)) {
                VStack(spacing: 10) {
                    RigIllustration(highlight: status == .none ? 2 : nil)
                    if case .found = status { Image(systemName: "checkmark.circle.fill").font(.system(size: 30)).foregroundStyle(Tokens.Color.safe) }
                }
            }
            Text(headline(status))
                .font(Tokens.Font.headline)
                .foregroundStyle(Tokens.Color.textPrimary)
                .multilineTextAlignment(.center)
                .accessibilityIdentifier("connectHeadline")
            Text(subline(status))
                .font(Tokens.Font.body(17))
                .foregroundStyle(Tokens.Color.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 620)

            if case .notAnInterface = status, !app.audio.availableInputs.isEmpty {
                Menu {
                    ForEach(app.audio.availableInputs, id: \.uid) { port in
                        Button(port.name) { app.audio.preferInput(uid: port.uid) }
                    }
                } label: {
                    Label("Which device?", systemImage: "list.bullet").font(Tokens.Font.label(17))
                        .padding(.horizontal, 18).frame(minHeight: Tokens.Size.target)
                        .background(Capsule().fill(Tokens.Color.bgElevated))
                }
            }

            HStack(spacing: 10) {
                Image(systemName: app.device.onMains ? "powerplug.fill" : "battery.50")
                Text(powerText).font(Tokens.Font.label(17))
            }
            .foregroundStyle(app.device.onMains ? Tokens.Color.safe : Tokens.Color.working)

            Toggle(isOn: $draft.simulated) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Use simulated rig (no hardware)").font(Tokens.Font.label(17)).foregroundStyle(Tokens.Color.textPrimary)
                    Text("Runs the engine inside a simulated room with a feedback loop. For demos, training and the simulator.")
                        .font(Tokens.Font.body(13)).foregroundStyle(Tokens.Color.textSecondary)
                }
            }
            .tint(Tokens.Color.accent)
            .frame(maxWidth: 560)
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 16).fill(Tokens.Color.bgStrip))
            .accessibilityIdentifier("simulatedToggle")
        }
        .padding(.horizontal, 40)
        .task {
            while !Task.isCancelled {
                app.audio.refreshRoute()
                app.device.poll()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private var powerText: String {
        switch app.device.power {
        case .mains: "Charging via hub"
        case .battery(let l): "On battery (\(Int(l * 100))%) — connect PD power to the hub"
        case .unknown: "Power source unknown"
        }
    }

    private func ringState(_ s: InterfaceStatus) -> RingState {
        switch s {
        case .found, .simulated: .found
        case .notAnInterface: .warning
        case .none: .searching
        }
    }

    private func headline(_ s: InterfaceStatus) -> String {
        switch s {
        case .found(let p): "Found \(p.name)"
        case .simulated: "Simulated rig ready"
        case .notAnInterface: "Found a device but it isn’t an audio interface"
        case .none: "Plug in your interface"
        }
    }

    private func subline(_ s: InterfaceStatus) -> String {
        switch s {
        case .found(let p): "USB Audio Class device, \(p.channels) input channel(s). Keep it on a USB 3 data port of the hub."
        case .simulated: "No hardware needed. A synthetic talker and a room with a PA will feed the engine."
        case .notAnInterface(let n): "Current route: \(n). Pick your USB interface, and avoid hubs with their own audio output."
        case .none: "Hub into the iPad, PD power into the hub, interface into a USB 3 port on the hub."
        }
    }
}

// MARK: - Step 2

private struct WiringStep: View {
    @Binding var draft: ShowFile

    var body: some View {
        VStack(spacing: 28) {
            Text("How is RingOut wired?").font(Tokens.Font.headline).foregroundStyle(Tokens.Color.textPrimary)
            HStack(spacing: 20) {
                ForEach(Topology.allCases) { t in
                    Button { select(t) } label: { TopologyCard(topology: t, selected: draft.topology == t) }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("topology\(t.rawValue)")
                }
            }
            .padding(.horizontal, 40)
            VStack(spacing: 10) {
                Text("Channels").font(Tokens.Font.label(15)).foregroundStyle(Tokens.Color.textSecondary)
                Picker("Channels", selection: $draft.channelCount) {
                    Text("1 channel").tag(1)
                    Text("2 channels").tag(2)
                }
                .pickerStyle(.segmented)
                .frame(width: 320)
            }
        }
    }

    private func select(_ t: Topology) {
        let old = draft.topology
        draft.topology = t
        for i in 0..<2 where draft.channels[i].name == old.stripName(i) {
            draft.channels[i].name = t.stripName(i)
        }
    }
}

struct TopologyCard: View {
    var topology: Topology
    var selected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(topology.rawValue)
                    .font(Tokens.Font.numeral(22, weight: .bold))
                    .foregroundStyle(Color.black)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(selected ? Tokens.Color.accent : Tokens.Color.textSecondary))
                Spacer()
                if selected { Image(systemName: "checkmark.circle.fill").font(.system(size: 26)).foregroundStyle(Tokens.Color.accent) }
            }
            Text(topology.title).font(Tokens.Font.subhead).foregroundStyle(Tokens.Color.textPrimary)
            WiringDiagram(topology: topology)
            Text(topology.summary).font(Tokens.Font.body(15)).foregroundStyle(Tokens.Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(22)
        .frame(maxWidth: .infinity, minHeight: 300, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 20).fill(Tokens.Color.bgStrip))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(selected ? Tokens.Color.accent : Tokens.Color.hairline, lineWidth: selected ? 3 : 1))
    }
}

struct WiringDiagram: View {
    var topology: Topology
    var body: some View {
        let nodes: [(String, String)] = switch topology {
        case .consoleInsert: [("slider.horizontal.3", "Send"), ("ipad.landscape", "RingOut"), ("slider.horizontal.3", "Return")]
        case .micInLineOut: [("music.mic", "Mic"), ("ipad.landscape", "RingOut"), ("slider.horizontal.3", "Line in")]
        case .groupInsert: [("person.3.fill", "Automix"), ("ipad.landscape", "RingOut"), ("slider.horizontal.3", "Return")]
        }
        HStack(spacing: 6) {
            ForEach(Array(nodes.enumerated()), id: \.offset) { i, n in
                VStack(spacing: 4) {
                    Image(systemName: n.0).font(.system(size: 22)).foregroundStyle(i == 1 ? Tokens.Color.accent : Tokens.Color.textPrimary)
                    Text(n.1).font(Tokens.Font.label(11)).foregroundStyle(Tokens.Color.textSecondary)
                }
                .frame(maxWidth: .infinity)
                if i < nodes.count - 1 {
                    Image(systemName: "arrow.right").font(.system(size: 12, weight: .bold)).foregroundStyle(Tokens.Color.textSecondary)
                }
            }
        }
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.black.opacity(0.3)))
    }
}

// MARK: - Step 3

struct SetupCheck: Identifiable {
    enum Status { case pass, warn, fail, info }
    var id: String
    var title: String
    var detail: String
    var status: Status
    var fix: String?
}

private struct ChecksStep: View {
    @Environment(AppModel.self) private var app
    var draft: ShowFile
    @Binding var directMonitorOff: Bool
    @State private var expanded: String?

    var checks: [SetupCheck] {
        let a = app.audio
        var c: [SetupCheck] = []
        c.append(SetupCheck(id: "session", title: "Audio session active", detail: a.isRunning ? "Running at \(Int(a.sampleRate)) Hz" : (a.lastError ?? "Not running"),
                            status: a.isRunning ? .pass : .fail, fix: "Close other audio apps (AUM, Loopy, video calls) that hold the audio session, then go back and forward again."))
        let bufStatus: SetupCheck.Status = a.actualFrames == a.requestedFrames ? .pass : (a.actualFrames <= 128 ? .warn : .fail)
        c.append(SetupCheck(id: "buffer", title: "Buffer = \(a.requestedFrames) (actual \(a.actualFrames))",
                            detail: a.actualFrames == a.requestedFrames ? "iPadOS granted the requested buffer." : "iPadOS gave \(a.actualFrames) samples instead of \(a.requestedFrames).",
                            status: draft.simulated ? .info : bufStatus,
                            fix: "Something is overriding the buffer. Turn off Settings › Accessibility › Sound Recognition and Vocal Shortcuts, and quit other audio apps. Above 128 samples RingOut will not run live."))
        let cb = a.lastCallbackFrames
        let match = cb == 0 || cb == a.actualFrames
        c.append(SetupCheck(id: "match", title: "Input/output buffer match", detail: cb == 0 ? "Waiting for callbacks…" : "Callback delivers \(cb) frames, session reports \(a.actualFrames).",
                            status: match ? .pass : .fail,
                            fix: "A mismatch is the signature of iPadOS accessibility audio features. Turn off Sound Recognition and Vocal Shortcuts in Settings › Accessibility."))
        c.append(SetupCheck(id: "a11y", title: "No accessibility audio features interfering",
                            detail: match && a.actualFrames <= a.requestedFrames ? "No buffer override detected." : "Buffer override detected.",
                            status: match && a.actualFrames <= a.requestedFrames ? .pass : .warn,
                            fix: "Settings › Accessibility › Sound Recognition → Off. Settings › Accessibility › Vocal Shortcuts → Off."))
        c.append(SetupCheck(id: "latency", title: "Interface reports latency",
                            detail: a.interfaceReportsLatency ? String(format: "In %.2f ms · Out %.2f ms", a.reportedInputLatency * 1000, a.reportedOutputLatency * 1000) : "Latency unknown — measure it with the loopback cable in the next step.",
                            status: a.interfaceReportsLatency ? .pass : .warn, fix: nil))
        c.append(SetupCheck(id: "power", title: "Mains power", detail: app.device.onMains ? "Charging through the hub." : "Running on battery.",
                            status: app.device.onMains ? .pass : .warn, fix: "Use a hub with ≥ 85 W PD pass-through and a 100 W brick so the iPad stays at 100 % under load."))
        return c
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                ForEach(checks) { check in
                    CheckRow(check: check, expanded: expanded == check.id) {
                        expanded = expanded == check.id ? nil : check.id
                    }
                }
                if !draft.simulated {
                    DirectMonitorCard(confirmed: $directMonitorOff)
                }
            }
            .padding(.horizontal, 40)
            .padding(.vertical, 20)
            .frame(maxWidth: 900)
            .frame(maxWidth: .infinity)
        }
        .task {
            while !Task.isCancelled {
                app.audio.refreshRoute()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
}

struct CheckRow: View {
    var check: SetupCheck
    var expanded: Bool
    var toggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: toggle) {
                HStack(spacing: 14) {
                    Image(systemName: icon).font(.system(size: 24, weight: .semibold)).foregroundStyle(color)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(check.title).font(Tokens.Font.label(17)).foregroundStyle(Tokens.Color.textPrimary)
                        Text(check.detail).font(Tokens.Font.body(15)).foregroundStyle(Tokens.Color.textSecondary)
                    }
                    Spacer()
                    if check.fix != nil && check.status != .pass {
                        Image(systemName: expanded ? "chevron.up" : "chevron.down").foregroundStyle(Tokens.Color.textSecondary)
                    }
                }
                .frame(minHeight: Tokens.Size.target)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded, let fix = check.fix, check.status != .pass {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "wrench.and.screwdriver.fill").foregroundStyle(Tokens.Color.accent)
                    Text(fix).font(Tokens.Font.body(15)).foregroundStyle(Tokens.Color.textPrimary)
                    Spacer()
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                    .font(Tokens.Font.label(15))
                    .foregroundStyle(Tokens.Color.accent)
                }
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 12).fill(Tokens.Color.bgElevated))
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 16).fill(Tokens.Color.bgStrip))
    }

    private var icon: String {
        switch check.status {
        case .pass: "checkmark.circle.fill"
        case .warn: "exclamationmark.triangle.fill"
        case .fail: "xmark.octagon.fill"
        case .info: "info.circle.fill"
        }
    }

    private var color: Color {
        switch check.status {
        case .pass: Tokens.Color.safe
        case .warn: Tokens.Color.working
        case .fail: Tokens.Color.ring
        case .info: Tokens.Color.textSecondary
        }
    }
}

/// Picture of a direct-monitor knob at zero; the user confirms.
struct DirectMonitorCard: View {
    @Binding var confirmed: Bool
    var body: some View {
        HStack(spacing: 24) {
            ZStack {
                Circle().fill(Tokens.Color.bgElevated).frame(width: 96, height: 96)
                Circle().stroke(Tokens.Color.textSecondary.opacity(0.4), lineWidth: 2).frame(width: 96, height: 96)
                Capsule().fill(Tokens.Color.accent).frame(width: 6, height: 36).offset(y: -22).rotationEffect(.degrees(-135))
                Text("0").font(Tokens.Font.numeral(13)).foregroundStyle(Tokens.Color.textSecondary).offset(x: -46, y: 42)
                Text("MAX").font(Tokens.Font.label(11)).foregroundStyle(Tokens.Color.textSecondary).offset(x: 46, y: 42)
            }
            .frame(width: 140, height: 120)
            VStack(alignment: .leading, spacing: 6) {
                Text("Direct monitor off").font(Tokens.Font.label(17)).foregroundStyle(Tokens.Color.textPrimary)
                Text("Turn the interface’s Direct Monitor / Air monitor knob fully to zero (or switch it off). Otherwise a dry copy leaks around RingOut and the result sounds like a tin can.")
                    .font(Tokens.Font.body(15)).foregroundStyle(Tokens.Color.textSecondary)
                Toggle("Direct monitor is at zero", isOn: $confirmed)
                    .tint(Tokens.Color.safe)
                    .font(Tokens.Font.label(17))
                    .accessibilityIdentifier("directMonitorToggle")
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 16).fill(Tokens.Color.bgStrip))
    }
}

// MARK: - Step 5

private struct DoneStep: View {
    @Environment(AppModel.self) private var app
    var draft: ShowFile
    @Binding var saveName: String

    var body: some View {
        VStack(spacing: 24) {
            SetupRing(state: .found) {
                Image(systemName: "checkmark").font(.system(size: 80, weight: .bold)).foregroundStyle(Tokens.Color.safe)
            }
            Text("Ready to go live").font(Tokens.Font.headline).foregroundStyle(Tokens.Color.textPrimary)
            Grid(alignment: .leading, horizontalSpacing: 40, verticalSpacing: 12) {
                row("Interface", app.audio.interfaceName)
                row("Topology", "\(app.show.topology.rawValue) · \(app.show.topology.title), \(app.effectiveChannels) channel(s)")
                row("Buffer", "\(app.audio.actualFrames) samples")
                row("Latency", String(format: "%.2f ms (%@)", app.latencyMS, app.latencyIsMeasured ? "measured" : "estimated"))
                row("CPU headroom", app.show.calibration.map { "\(Int((1 - $0.peakDSPLoad) * 100))% (peak DSP \(Int($0.peakDSPLoad * 100))%)" } ?? "Not tested")
                row("Thermal", app.device.thermalLabel)
            }
            .padding(24)
            .background(RoundedRectangle(cornerRadius: 20).fill(Tokens.Color.bgStrip))
            HStack {
                Text("Save as show file").font(Tokens.Font.label(17)).foregroundStyle(Tokens.Color.textSecondary)
                TextField("Show name (e.g. Sunday 9am)", text: $saveName)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 320)
            }
        }
    }

    @ViewBuilder private func row(_ k: String, _ v: String) -> some View {
        GridRow {
            Text(k).font(Tokens.Font.label(17)).foregroundStyle(Tokens.Color.textSecondary)
            Text(v).font(Tokens.Font.numeral(17)).foregroundStyle(Tokens.Color.textPrimary)
        }
    }
}

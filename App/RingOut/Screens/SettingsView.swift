import SwiftUI
import UniformTypeIdentifiers

/// S6 — Settings, iPad split layout.
struct SettingsView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    enum Group: String, CaseIterable, Identifiable {
        case audio = "Audio", channels = "Channels", shows = "Show files", lock = "Lock", power = "Power & thermal", license = "License", about = "About & diagnostics"
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .audio: "waveform"
            case .channels: "slider.vertical.3"
            case .shows: "doc.on.doc"
            case .lock: "lock.fill"
            case .power: "bolt.fill"
            case .license: "checkmark.seal.fill"
            case .about: "info.circle.fill"
            }
        }
    }

    @State private var selection: Group? = .audio

    var body: some View {
        NavigationSplitView {
            List(Group.allCases, selection: $selection) { g in
                Label(g.rawValue, systemImage: g.symbol)
                    .font(Tokens.Font.label(17))
                    .frame(minHeight: Tokens.Size.target)
                    .tag(g)
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { AudioRunningBadge(running: app.audio.isRunning) }
            }
        } detail: {
            Form {
                switch selection ?? .audio {
                case .audio: AudioSettings()
                case .channels: ChannelSettingsSection()
                case .shows: ShowFilesSection()
                case .lock: LockSettings()
                case .power: PowerSettings()
                case .license: LicenseSettings()
                case .about: AboutSettings()
                }
            }
            .navigationTitle((selection ?? .audio).rawValue)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.accessibilityIdentifier("settingsDone") }
            }
        }
        .tint(Tokens.Color.accent)
    }
}

private struct AudioSettings: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        Section("Buffer size") {
            Picker("Buffer", selection: Binding(get: { app.show.bufferFrames }, set: { v in app.update { $0.bufferFrames = v } })) {
                ForEach(ShowFile.validBuffers, id: \.self) { f in
                    let ms = (app.audio.reportedInputLatency + app.audio.reportedOutputLatency + 2 * Double(f) / app.audio.sampleRate) * 1000
                    Text("\(f) samples · ≈\(String(format: "%.1f", ms)) ms").tag(f)
                }
            }
            .pickerStyle(.inline)
            LabeledContent("Actual buffer", value: "\(app.audio.actualFrames) samples")
            LabeledContent("Latency now", value: String(format: "%.2f ms (%@)", app.latencyMS, app.latencyIsMeasured ? "measured" : "estimated"))
            Button("Re-run calibration…") {
                app.showSettings = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { app.showCalibration = true }
            }
        }
        Section {
            Picker("Isolator", selection: Binding(get: { app.show.isolator }, set: { v in app.update { $0.isolatorMode = v } })) {
                ForEach(IsolatorMode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .disabled(!app.neuralModelVerified)
        } header: {
            Text("Feedback isolator")
        } footer: {
            Text(app.neuralModelVerified
                 ? "Neural runs a small on-device network, trained on speech and singing through simulated PA loops, that removes feedback the notches miss. Voice passes essentially unchanged; a pure steady sine tone is turned down about 6 dB, so use DSP only for sine-wave line checks. Needs 48 kHz; other rates fall back to DSP."
                 : "The neural model failed its self-test, so the DSP isolator is in use.")
        }
        Section {
            LabeledContent("Sample rate", value: "\(Int(app.audio.sampleRate)) Hz (follows interface)")
            Toggle("High-pass 80 Hz", isOn: Binding(get: { app.show.channels[0].highPass }, set: { v in app.update { $0.channels[0].highPass = v; $0.channels[1].highPass = v } }))
            Toggle("Output limiter (−0.3 dBFS)", isOn: Binding(get: { app.show.limiter }, set: { v in app.update { $0.limiter = v } }))
        }
        Section {
            Button("Run setup wizard again") { app.showSettings = false; app.phase = .wizard }
        }
    }
}

private struct ChannelSettingsSection: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        Section("Wiring") {
            Picker("Topology", selection: Binding(get: { app.show.topology }, set: { v in app.update { $0.topology = v } })) {
                ForEach(Topology.allCases) { t in Text("\(t.rawValue) · \(t.title)").tag(t) }
            }
            Picker("Channels", selection: Binding(get: { app.show.channelCount }, set: { v in app.update { $0.channelCount = v } })) {
                Text("1").tag(1)
                Text("2").tag(2).disabled(!app.license.isPro)
            }
            .pickerStyle(.segmented)
            Toggle("Stereo link", isOn: .constant(false)).disabled(true)
            Text("Stereo link arrives in V1.x.").font(.footnote).foregroundStyle(.secondary)
        }
        ForEach(0..<2, id: \.self) { ch in
            Section("Channel \(ch + 1)") {
                TextField("Name", text: Binding(get: { app.show.channels[ch].name }, set: { app.rename(ch, to: $0) }))
                Picker("Model variant", selection: Binding(get: { app.show.channels[ch].preset }, set: { app.setPreset($0, channel: ch) })) {
                    ForEach(Preset.allCases) { Text($0.title).tag($0) }
                }
                if app.show.topology == .micInLineOut {
                    LabeledContent("Input trim") {
                        Slider(value: Binding(get: { app.show.channels[ch].inputTrimDB }, set: { v in app.update { $0.channels[ch].inputTrimDB = v.rounded() } }), in: -24...24, step: 1)
                            .frame(width: 260)
                        Text(String(format: "%+.0f dB", app.show.channels[ch].inputTrimDB)).monospacedDigit().frame(width: 60)
                    }
                }
                LabeledContent("Fixed notches", value: app.show.channels[ch].fixedNotches.isEmpty ? "None" : app.show.channels[ch].fixedNotches.map { "\(Int($0.frequency)) Hz" }.joined(separator: ", "))
            }
        }
    }
}

private struct ShowFilesSection: View {
    @Environment(AppModel.self) private var app
    @State private var importing = false
    @State private var newName = ""
    @State private var error: String?

    var body: some View {
        Section("Current") {
            LabeledContent("Loaded", value: app.show.name)
            HStack {
                TextField("Save as…", text: $newName)
                Button("Save") {
                    var s = app.show
                    if !newName.isEmpty { s.name = newName; s.id = UUID() }
                    try? app.store.save(s)
                    app.load(s)
                    newName = ""
                }
            }
            ShareLink(item: app.store.url(for: app.show)) { Label("Export current show", systemImage: "square.and.arrow.up") }
                .onAppear { app.saveNow() }
            Button { importing = true } label: { Label("Import from Files", systemImage: "square.and.arrow.down") }
        }
        Section("Saved shows") {
            if app.store.shows.isEmpty { Text("No saved shows yet.").foregroundStyle(.secondary) }
            ForEach(app.store.shows) { s in
                HStack {
                    VStack(alignment: .leading) {
                        Text(s.name).font(Tokens.Font.label(17))
                        Text("\(s.topology.title) · \(s.channelCount) ch · \(s.bufferFrames) smp · \(s.modified.formatted(date: .abbreviated, time: .shortened))")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if s.id == app.show.id { Image(systemName: "checkmark").foregroundStyle(Tokens.Color.accent) }
                    else { Button("Load") { app.load(s) }.buttonStyle(.bordered) }
                }
                .swipeActions {
                    Button("Delete", role: .destructive) { app.store.delete(s) }
                    Button("Duplicate") { try? app.store.duplicate(s) }
                }
                .contextMenu {
                    Button("Duplicate") { try? app.store.duplicate(s) }
                    ShareLink(item: app.store.url(for: s)) { Text("Export") }
                    Button("Delete", role: .destructive) { app.store.delete(s) }
                }
            }
        }
        Section("iCloud Drive") {
            Toggle("Sync show files to iCloud Drive", isOn: Binding(get: { app.store.iCloudEnabled }, set: { app.store.iCloudEnabled = $0 }))
                .disabled(!app.store.iCloudAvailable)
            if !app.store.iCloudAvailable {
                Text("iCloud Drive isn’t available on this device or build. Show files stay in On My iPad › RingOut › Shows.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            do { app.load(try app.store.importShow(from: try result.get())) } catch { self.error = error.localizedDescription }
        }
        .alert("Import failed", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("OK") {} } message: { Text(error ?? "") }
    }
}

private struct LockSettings: View {
    @Environment(AppModel.self) private var app
    @State private var pin = ""
    @State private var confirm = ""

    var body: some View {
        Section("PIN") {
            if app.hasPIN {
                LabeledContent("PIN", value: "Set")
                Button("Lock now") { app.showSettings = false; app.lock() }
                Button("Remove PIN", role: .destructive) { app.setPIN(nil) }
            } else {
                SecureField("New PIN (4–8 digits)", text: $pin).keyboardType(.numberPad)
                SecureField("Confirm PIN", text: $confirm).keyboardType(.numberPad)
                Button("Set PIN") { app.setPIN(pin); pin = ""; confirm = "" }
                    .disabled(!LockPIN.isValid(pin) || pin != confirm)
            }
        }
        Section("Behaviour") {
            Picker("Auto-lock", selection: Binding(get: { app.show.autoLockMinutes }, set: { v in app.update { $0.autoLockMinutes = v } })) {
                Text("Never").tag(0)
                ForEach([2, 5, 10, 30], id: \.self) { Text("After \($0) min").tag($0) }
            }
            Toggle("Allow hold-to-bypass safety release", isOn: Binding(get: { app.show.allowBypassRelease }, set: { v in app.update { $0.allowBypassRelease = v } }))
            Text("When locked, meters, spectrum and state colours stay visible. Dials and buttons are disabled.").font(.footnote).foregroundStyle(.secondary)
        }
    }
}

private struct PowerSettings: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        Section("Power") {
            LabeledContent("Source", value: app.device.onMains ? "Mains" : "Battery")
            if let lvl = app.device.batteryLevel { LabeledContent("Battery", value: "\(Int(lvl * 100))%") }
            if let d = app.device.drainPerHour { LabeledContent("Drain", value: String(format: "%.1f %%/h", d)) }
            Stepper(value: Binding(get: { app.show.batteryWarnHours }, set: { v in app.update { $0.batteryWarnHours = v } }), in: 0.5...4, step: 0.5) {
                LabeledContent("Warn below", value: String(format: "%.1f h remaining", app.show.batteryWarnHours))
            }
        }
        Section("Thermal") {
            LabeledContent("State", value: app.device.thermalLabel)
            Picker("When the iPad gets hot", selection: Binding(get: { app.show.thermalPolicy }, set: { v in app.update { $0.thermalPolicy = v } })) {
                ForEach(ThermalPolicy.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            Text("Auto raises the buffer one step at the next silent gap. Stepping back down is offered, never automatic.").font(.footnote).foregroundStyle(.secondary)
        }
        Section("Display") {
            Toggle("Dim booth (−60% UI luminance)", isOn: Binding(get: { app.show.dimBooth }, set: { v in app.update { $0.dimBooth = v } }))
        }
    }
}

private struct LicenseSettings: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        Section("Status") {
            LabeledContent("License", value: app.license.statusText)
            LabeledContent("Device", value: UIDevice.current.name)
        }
        if !app.license.isPro || app.license.developmentUnlock {
            Section("RingOut Pro") {
                Text("2 channels, all presets, show files, lock and diagnostics export. One-time purchase per Apple ID, works offline.")
                Button(app.license.product.map { "Buy Pro — \($0.displayPrice)" } ?? "Pro unavailable (App Store not reachable)") {
                    Task { await app.license.purchase() }
                }
                .disabled(app.license.product == nil || app.license.purchasing)
                Button("Restore purchases") { Task { await app.license.restore() } }
            }
        }
        Section {
            Text("There is no activation server. Your purchase follows your Apple ID, so replacing an iPad never strands a license. To move it, sign in with the same Apple ID on the new iPad and tap Restore.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }
}

private struct AboutSettings: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        Section {
            LabeledContent("Version", value: "\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"))")
            LabeledContent("Detector", value: "FFT 1024 · 8 auto + 4 fixed notches")
            LabeledContent("Isolator", value: app.show.isolator.title)
            LabeledContent("Neural model", value: "\(Engine.neuralModelId)\(app.neuralModelVerified ? "" : " (self-test failed)")")
        } header: {
            Text("RingOut")
        } footer: {
            Text("The neural model was trained with the CSTR VCTK Corpus (Yamagishi, Veaux, MacDonald, University of Edinburgh) and VocalSet (Wilkins, Seetharaman, Wahl, Pardo), both CC BY 4.0.")
        }
        Section {
            Button("Open diagnostics") { app.showSettings = false; DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { app.showDiagnostics = true } }
        }
    }
}

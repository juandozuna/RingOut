import SwiftUI

struct ChannelStrip: View {
    @Environment(AppModel.self) private var app
    let channel: Int

    @State private var renaming = false
    @State private var draftName = ""

    private var snap: ChannelSnapshot { app.snapshots[channel] }
    private var settings: ChannelSettings { app.show.channels[channel] }
    private var active: Bool { channel < app.effectiveChannels && app.audio.isRunning }

    private var state: ChannelState {
        if !active { return .bypass }
        if app.bypassed[channel] || app.muted[channel] || app.watchdogTripped { return .bypass }
        return snap.state
    }

    var body: some View {
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: Tokens.Size.radius)
                .fill(Tokens.Color.bgStrip)
            RoundedRectangle(cornerRadius: Tokens.Size.radius)
                .fill(state.color.opacity(0.18))
                .animation(.easeOut(duration: 0.25), value: state)
            UnevenRoundedRectangle(topLeadingRadius: Tokens.Size.radius, topTrailingRadius: Tokens.Size.radius)
                .fill(state.color)
                .frame(height: 6)

            if active {
                content
            } else {
                inactive
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("strip\(channel + 1)")
        .alert("Rename channel", isPresented: $renaming) {
            TextField("Name", text: $draftName)
            Button("Save") { app.rename(channel, to: draftName) }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var content: some View {
        VStack(spacing: 14) {
            header
            HStack(alignment: .top, spacing: 14) {
                LevelMeter(peak: snap.inputPeak, rms: snap.inputRMS, hold: snap.inputHold, clip: snap.inputClip, label: "IN") {
                    app.resetMeters(channel)
                }
                VStack(spacing: 8) {
                    SpectrumRibbon(spectrum: snap.spectrum, notches: snap.notches, ringHz: snap.lastRingHz, ringAge: snap.lastRingAge)
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Color.black.opacity(0.35)))
                        .onTapGesture { app.notchDetailChannel = channel }
                    Button { app.notchDetailChannel = channel } label: {
                        HStack(spacing: 6) {
                            Text("\(snap.autoNotches) active · \(snap.fixedNotches) fixed")
                            if snap.gainReduction < -0.5 {
                                Text("· \(String(format: "%.1f", snap.gainReduction)) dB")
                            }
                            Image(systemName: "chevron.right").font(.system(size: 12, weight: .bold))
                        }
                        .font(Tokens.Font.numeral(15, weight: .medium))
                        .foregroundStyle(Tokens.Color.textSecondary)
                        .frame(minHeight: Tokens.Size.target)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("notchReadout\(channel + 1)")
                }
                LevelMeter(peak: snap.outputPeak, rms: snap.outputRMS, hold: snap.outputHold, clip: snap.outputClip, label: "OUT") {
                    app.resetMeters(channel)
                }
            }
            .frame(maxHeight: .infinity)

            HStack(alignment: .center, spacing: 24) {
                StrengthDial(value: settings.strength, enabled: !app.bypassed[channel], tint: Tokens.Color.accent) {
                    app.setStrength($0, channel: channel)
                }
                VStack(alignment: .leading, spacing: 10) {
                    Text("PRESET").font(Tokens.Font.label(11, weight: .bold)).tracking(1).foregroundStyle(Tokens.Color.textSecondary)
                    HStack(spacing: 8) {
                        ForEach(Preset.allCases) { p in
                            Chip(title: p.title, selected: settings.preset == p) { app.setPreset(p, channel: channel) }
                        }
                    }
                    if snap.isolatorActivity > 0.05 {
                        Label("\(snap.isolator == RO_ISOLATOR_DSP ? "Isolator" : "Neural") \(Int(snap.isolatorActivity * 100))%", systemImage: snap.isolator == RO_ISOLATOR_DSP ? "waveform.path.ecg" : "brain")
                            .font(Tokens.Font.label(13))
                            .foregroundStyle(Tokens.Color.textSecondary)
                    }
                }
            }

            HStack(spacing: 14) {
                BigButton(title: "Bypass", systemImage: "arrow.uturn.right", isOn: app.bypassed[channel], onColor: Tokens.Color.bypass) {
                    app.toggleBypass(channel)
                }
                .accessibilityIdentifier("bypass\(channel + 1)")
                BigButton(title: app.muted[channel] ? "Muted" : "Hold to mute", systemImage: "speaker.slash.fill", isOn: app.muted[channel],
                          onColor: Tokens.Color.ring, holdToEngage: true) {
                    app.setMuted(!app.muted[channel], channel: channel)
                }
                .accessibilityIdentifier("mute\(channel + 1)")
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .padding(.bottom, 18)
    }

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(settings.name)
                    .font(Tokens.Font.subhead)
                    .foregroundStyle(Tokens.Color.textPrimary)
                    .onLongPressGesture {
                        draftName = settings.name
                        renaming = true
                    }
                    .accessibilityHint("Long press to rename")
                Text("Topology \(app.show.topology.rawValue) · \(app.show.topology.title)")
                    .font(Tokens.Font.label(13, weight: .medium))
                    .foregroundStyle(Tokens.Color.textSecondary)
            }
            if snap.multiTalker {
                Label("Multi-talker", systemImage: "person.2.fill")
                    .font(Tokens.Font.label(13))
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Capsule().fill(Tokens.Color.bgElevated))
                    .foregroundStyle(Tokens.Color.textPrimary)
            }
            Spacer()
            if snap.loopGainWarning && !app.bypassed[channel] {
                Label("Loop gain too high", systemImage: "exclamationmark.triangle.fill")
                    .font(Tokens.Font.label(15, weight: .bold))
                    .foregroundStyle(Color.black)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Capsule().fill(Tokens.Color.ring))
            } else {
                HStack(spacing: 8) {
                    Circle().fill(state.color).frame(width: 12, height: 12)
                    Text(state.label).font(Tokens.Font.label(17)).foregroundStyle(state.color)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("state\(channel + 1)")
            }
        }
    }

    private var inactive: some View {
        VStack(spacing: 16) {
            Image(systemName: "power").font(.system(size: 44, weight: .semibold)).foregroundStyle(Tokens.Color.bypass)
            Text("\(settings.name) is off").font(Tokens.Font.subhead).foregroundStyle(Tokens.Color.textPrimary)
            Text(app.license.isPro ? (app.audio.isRunning ? "Enable two channels in Settings › Channels." : "Audio is not running.") : "Two channels require RingOut Pro.")
                .font(Tokens.Font.body(15))
                .foregroundStyle(Tokens.Color.textSecondary)
                .multilineTextAlignment(.center)
            if app.license.isPro && app.show.channelCount == 1 && app.audio.isRunning {
                PrimaryButton(title: "Enable channel \(channel + 1)") { app.update { $0.channelCount = 2 } }
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

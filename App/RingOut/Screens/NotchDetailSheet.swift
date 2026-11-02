import SwiftUI

/// S5 — Notch detail for one channel.
struct NotchDetailSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let channel: Int
    @State private var ringOutWarning = false

    private var snap: ChannelSnapshot { app.snapshots[channel] }
    private var ringOut: Bool { app.ringOutActive == channel }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    SpectrumRibbon(spectrum: snap.spectrum, notches: snap.notches, ringHz: snap.lastRingHz, ringAge: snap.lastRingAge,
                                   draggable: true) { slot, hz in app.moveNotch(slot: slot, to: hz, channel: channel) }
                        .frame(height: 320)
                        .padding(14)
                        .background(RoundedRectangle(cornerRadius: 16).fill(Tokens.Color.bgStrip))

                    if ringOut { ringOutPanel }

                    notchTable

                    HStack(alignment: .top, spacing: 24) {
                        settingBox("Notch hold", value: String(format: "%.0f s", app.show.notchHoldSeconds)) {
                            Slider(value: Binding(get: { app.show.notchHoldSeconds }, set: { v in app.update { $0.notchHoldSeconds = v.rounded() } }), in: 2...10, step: 1)
                                .tint(Tokens.Color.accent)
                        }
                        settingBox("Max auto notches", value: "\(app.show.maxAutoNotches)") {
                            Stepper("", value: Binding(get: { app.show.maxAutoNotches }, set: { v in app.update { $0.maxAutoNotches = v } }), in: 4...8)
                                .labelsHidden()
                        }
                    }
                }
                .padding(24)
            }
            .background(Tokens.Color.bgBase)
            .navigationTitle("\(app.show.channels[channel].name) · Notches")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { AudioRunningBadge(running: app.audio.isRunning) }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button("Clear auto") { app.clearAutoNotches(channel) }
                    Button(ringOut ? "Finish ring out" : "Ring out") {
                        if ringOut { app.setRingOut(false, channel: channel) } else { ringOutWarning = true }
                    }
                    .accessibilityIdentifier("ringOutButton")
                    Button("Done") { dismiss() }
                }
            }
            .alert("Ring out this channel?", isPresented: $ringOutWarning) {
                Button("Start ring out", role: .destructive) { app.setRingOut(true, channel: channel) }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Turn the PA to a safe level first. Then slowly raise this channel’s console gain. RingOut pins the first rings it catches as fixed notches (up to 4). Stop raising gain as soon as a fourth notch lands.")
            }
        }
    }

    private var ringOutPanel: some View {
        HStack(spacing: 16) {
            Image(systemName: "dot.radiowaves.up.forward").font(.system(size: 30)).foregroundStyle(Tokens.Color.ring)
            VStack(alignment: .leading, spacing: 4) {
                Text("Ring-out mode — raise console gain slowly").font(Tokens.Font.label(19)).foregroundStyle(Tokens.Color.textPrimary)
                Text("\(snap.fixedNotches) of 4 fixed notches pinned").font(Tokens.Font.numeral(15)).foregroundStyle(Tokens.Color.textSecondary)
            }
            Spacer()
            PrimaryButton(title: "Keep \(snap.fixedNotches) fixed notches", color: Tokens.Color.safe) { app.setRingOut(false, channel: channel) }
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 16).fill(Tokens.Color.ring.opacity(0.18)))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Tokens.Color.ring, lineWidth: 2))
    }

    private var notchTable: some View {
        VStack(spacing: 0) {
            HStack {
                Text("#").frame(width: 40, alignment: .leading)
                Text("Frequency").frame(maxWidth: .infinity, alignment: .leading)
                Text("Depth").frame(maxWidth: .infinity, alignment: .leading)
                Text("Age").frame(maxWidth: .infinity, alignment: .leading)
                Text("Type").frame(maxWidth: .infinity, alignment: .leading)
                Text("").frame(width: 220)
            }
            .font(Tokens.Font.label(13, weight: .bold))
            .foregroundStyle(Tokens.Color.textSecondary)
            .padding(.horizontal, 16).padding(.vertical, 10)
            if snap.notches.isEmpty {
                Text("No notches. The channel is clean.")
                    .font(Tokens.Font.body(15)).foregroundStyle(Tokens.Color.textSecondary)
                    .frame(maxWidth: .infinity, minHeight: 64)
            }
            ForEach(snap.notches) { n in
                Divider().overlay(Tokens.Color.hairline)
                HStack {
                    Text("\(n.slot + 1)").frame(width: 40, alignment: .leading)
                    Text(String(format: "%.1f Hz", n.frequency)).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                    Text(String(format: "%.0f dB", n.depth)).frame(maxWidth: .infinity, alignment: .leading)
                    Text(String(format: "%.0f s", n.age)).frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: 6) {
                        Image(systemName: n.fixed ? "lock.fill" : "bolt.fill")
                        Text(n.fixed ? "Fixed" : "Auto")
                    }
                    .foregroundStyle(n.fixed ? Tokens.Color.bypass : Tokens.Color.working)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: 8) {
                        if !n.fixed {
                            Button("Pin") { app.pinNotch(slot: n.slot, channel: channel) }
                                .disabled(snap.fixedNotches >= 4)
                        }
                        Button("Release", role: .destructive) { app.releaseNotch(slot: n.slot, channel: channel) }
                    }
                    .buttonStyle(.bordered)
                    .fixedSize()
                    .frame(width: 220, alignment: .trailing)
                }
                .font(Tokens.Font.numeral(17))
                .foregroundStyle(Tokens.Color.textPrimary)
                .padding(.horizontal, 16)
                .frame(minHeight: 52)
            }
        }
        .background(RoundedRectangle(cornerRadius: 16).fill(Tokens.Color.bgStrip))
    }

    private func settingBox<C: View>(_ title: String, value: String, @ViewBuilder _ control: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(Tokens.Font.label(17)).foregroundStyle(Tokens.Color.textPrimary)
                Spacer()
                Text(value).font(Tokens.Font.numeral(17)).foregroundStyle(Tokens.Color.textSecondary)
            }
            control()
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 16).fill(Tokens.Color.bgStrip))
    }
}

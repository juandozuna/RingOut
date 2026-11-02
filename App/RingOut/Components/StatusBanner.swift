import SwiftUI

/// S3 top banner (56 pt). Long-press opens Diagnostics.
struct StatusBanner: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        HStack(spacing: 20) {
            // Left: interface + rate
            HStack(spacing: 10) {
                Image(systemName: app.show.simulated ? "waveform.badge.magnifyingglass" : "cable.connector")
                    .foregroundStyle(app.disconnect == nil ? Tokens.Color.safe : Tokens.Color.ring)
                VStack(alignment: .leading, spacing: 0) {
                    Text(app.audio.interfaceName)
                        .font(Tokens.Font.label(17))
                        .foregroundStyle(Tokens.Color.textPrimary)
                        .lineLimit(1)
                    Text("\(String(format: "%.1f", app.audio.sampleRate / 1000)) kHz · \(app.effectiveChannels) ch")
                        .font(Tokens.Font.numeral(13, weight: .medium))
                        .foregroundStyle(Tokens.Color.textSecondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Centre: buffer · latency
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                VStack(spacing: -2) {
                    Text("\(app.audio.actualFrames)")
                        .font(Tokens.Font.numeral(28, weight: .bold))
                        .foregroundStyle(app.audio.actualFrames > 128 ? Tokens.Color.ring : Tokens.Color.textPrimary)
                    Text("samples").font(Tokens.Font.label(11)).foregroundStyle(Tokens.Color.textSecondary)
                }
                Text("·").font(Tokens.Font.numeral(28)).foregroundStyle(Tokens.Color.textSecondary)
                VStack(spacing: -2) {
                    Text(String(format: "%.1f ms", app.latencyMS))
                        .font(Tokens.Font.numeral(28, weight: .bold))
                        .foregroundStyle(app.latencyMS > 8 ? Tokens.Color.working : Tokens.Color.textPrimary)
                    Text("\(app.latencySamples) smp · \(app.latencyIsMeasured ? "measured" : "estimated")")
                        .font(Tokens.Font.label(11)).foregroundStyle(Tokens.Color.textSecondary)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("latencyReadout")

            // Right: CPU ring, thermal, power, lock
            HStack(spacing: 18) {
                CPURing(load: app.dspLoad)
                Image(systemName: thermalSymbol)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(thermalColor)
                    .accessibilityLabel("Thermal \(app.device.thermalLabel)")
                PowerGlyph(power: app.device.power)
                Button {
                    if app.hasPIN { app.lock() } else { app.showSettings = true }
                } label: {
                    Image(systemName: app.locked ? "lock.fill" : app.hasPIN ? "lock.open.fill" : "lock.slash")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(Tokens.Color.textPrimary)
                        .frame(width: Tokens.Size.target, height: Tokens.Size.target)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(app.hasPIN ? "Lock controls" : "Set a lock PIN")
                .accessibilityIdentifier("lockButton")
                Button { app.showSettings = true } label: {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(Tokens.Color.textPrimary)
                        .frame(width: Tokens.Size.target, height: Tokens.Size.target)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Settings")
                .accessibilityIdentifier("settingsButton")
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 20)
        .frame(height: Tokens.Size.banner)
        .background(Tokens.Color.bgStrip)
        .contentShape(Rectangle())
        .onLongPressGesture(minimumDuration: 0.6) { app.showDiagnostics = true }
        .accessibilityAction(named: "Open diagnostics") { app.showDiagnostics = true }
    }

    private var thermalSymbol: String {
        switch app.device.thermal {
        case .nominal: "thermometer.low"
        case .fair: "thermometer.medium"
        default: "thermometer.high"
        }
    }

    private var thermalColor: Color {
        switch app.device.thermal {
        case .nominal: Tokens.Color.safe
        case .fair: Tokens.Color.textPrimary
        case .serious: Tokens.Color.working
        default: Tokens.Color.ring
        }
    }
}

struct CPURing: View {
    var load: Float
    var body: some View {
        let color = load > 0.6 ? Tokens.Color.ring : load > 0.4 ? Tokens.Color.working : Tokens.Color.safe
        ZStack {
            Circle().stroke(Color.white.opacity(0.1), lineWidth: 4)
            Circle().trim(from: 0, to: CGFloat(min(load, 1)))
                .stroke(color, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(Int(load * 100))")
                .font(Tokens.Font.numeral(12, weight: .bold))
                .foregroundStyle(Tokens.Color.textPrimary)
        }
        .frame(width: 36, height: 36)
        .accessibilityElement()
        .accessibilityLabel("DSP load \(Int(load * 100)) percent")
    }
}

struct PowerGlyph: View {
    var power: PowerSource
    var body: some View {
        HStack(spacing: 4) {
            switch power {
            case .mains:
                Image(systemName: "powerplug.fill").foregroundStyle(Tokens.Color.safe)
                Text("Mains").font(Tokens.Font.label(13)).foregroundStyle(Tokens.Color.textSecondary)
            case .battery(let level):
                Image(systemName: level < 0.15 ? "battery.25" : "battery.75")
                    .foregroundStyle(level < 0.15 ? Tokens.Color.ring : Tokens.Color.working)
                Text("\(Int(level * 100))%").font(Tokens.Font.numeral(13)).foregroundStyle(Tokens.Color.textSecondary)
            case .unknown:
                Image(systemName: "bolt.horizontal.circle").foregroundStyle(Tokens.Color.textSecondary)
                Text("Power ?").font(Tokens.Font.label(13)).foregroundStyle(Tokens.Color.textSecondary)
            }
        }
        .font(.system(size: 18, weight: .semibold))
        .accessibilityElement(children: .combine)
    }
}

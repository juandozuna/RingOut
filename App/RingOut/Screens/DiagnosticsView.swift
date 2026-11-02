import SwiftUI

/// S7 — Diagnostics: rolling 10-minute graphs, event log, export.
struct DiagnosticsView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var exported: [URL] = []
    @State private var exportError: String?
    @State private var filter: LogEvent.Kind?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 16) {
                        graph("DSP load (audio thread)", app.log.health.map(\.dspLoad), format: "%.0f%%", scale: 100, color: Tokens.Color.accent)
                        graph("Overloads", app.log.health.map { Float($0.overloads) }, format: "%.0f", scale: 1, color: Tokens.Color.ring, ceiling: max(5, Float(app.overloads)))
                        graph("Buffer (actual)", app.log.health.map { Float($0.bufferFrames) }, format: "%.0f smp", scale: 1, color: Tokens.Color.textPrimary, ceiling: 256)
                        graph("Thermal state", app.log.health.map { Float($0.thermal) }, format: "%.0f", scale: 1, color: Tokens.Color.working, ceiling: 3)
                        graph("Battery", app.log.health.map { max($0.battery, 0) }, format: "%.0f%%", scale: 100, color: Tokens.Color.safe)
                        statusCard
                    }
                    eventLog
                }
                .padding(24)
            }
            .background(Tokens.Color.bgBase)
            .navigationTitle("Diagnostics")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { AudioRunningBadge(running: app.audio.isRunning) }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if exported.isEmpty {
                        Button("Export report") {
                            do { exported = try app.log.exportReport(show: app.show, status: app.statusDictionary) }
                            catch { exportError = error.localizedDescription }
                        }
                    } else {
                        ShareLink(items: exported) { Label("Share report (JSON + PDF)", systemImage: "square.and.arrow.up") }
                    }
                    Button("Done") { dismiss() }.accessibilityIdentifier("diagnosticsDone")
                }
            }
            .alert("Export failed", isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })) { Button("OK") {} } message: { Text(exportError ?? "") }
        }
    }

    private func graph(_ title: String, _ values: [Float], format: String, scale: Float, color: Color, ceiling: Float = 1) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(Tokens.Font.label(15)).foregroundStyle(Tokens.Color.textSecondary)
                Spacer()
                Text(String(format: format, (values.last ?? 0) * scale)).font(Tokens.Font.numeral(17)).foregroundStyle(Tokens.Color.textPrimary)
            }
            LoadGraph(values: values, maxCount: 600, color: color, ceiling: ceiling).frame(height: 90)
            Text("Last 10 minutes").font(Tokens.Font.label(11)).foregroundStyle(Tokens.Color.textSecondary)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 16).fill(Tokens.Color.bgStrip))
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Now").font(Tokens.Font.label(15)).foregroundStyle(Tokens.Color.textSecondary)
            ForEach(app.statusDictionary.sorted(by: { $0.key < $1.key }), id: \.key) { k, v in
                HStack {
                    Text(k).foregroundStyle(Tokens.Color.textSecondary)
                    Spacer()
                    Text(v).foregroundStyle(Tokens.Color.textPrimary).lineLimit(1)
                }
                .font(Tokens.Font.numeral(13, weight: .medium))
            }
        }
        .padding(16)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 16).fill(Tokens.Color.bgStrip))
    }

    private var eventLog: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Event log").font(Tokens.Font.subhead).foregroundStyle(Tokens.Color.textPrimary)
                Spacer()
                Picker("Filter", selection: $filter) {
                    Text("All").tag(LogEvent.Kind?.none)
                    Text("Rings").tag(LogEvent.Kind?.some(.ring))
                    Text("Releases").tag(LogEvent.Kind?.some(.release))
                    Text("Route").tag(LogEvent.Kind?.some(.route))
                    Text("Overloads").tag(LogEvent.Kind?.some(.overload))
                    Text("Thermal").tag(LogEvent.Kind?.some(.thermal))
                }
                .pickerStyle(.segmented)
                .frame(width: 560)
            }
            let events = app.log.events.reversed().filter { filter == nil || $0.kind == filter }.prefix(300)
            VStack(spacing: 0) {
                if events.isEmpty {
                    Text("No events yet.").foregroundStyle(Tokens.Color.textSecondary).frame(maxWidth: .infinity, minHeight: 60)
                }
                ForEach(Array(events)) { e in
                    HStack(spacing: 12) {
                        Image(systemName: e.symbol).frame(width: 24).foregroundStyle(color(e.kind))
                        Text(e.date.formatted(date: .omitted, time: .standard)).font(Tokens.Font.numeral(13)).foregroundStyle(Tokens.Color.textSecondary).frame(width: 90, alignment: .leading)
                        if let c = e.channel { Text("Ch \(c + 1)").font(Tokens.Font.label(13)).foregroundStyle(Tokens.Color.textSecondary).frame(width: 40) }
                        Text(e.message).font(Tokens.Font.body(15)).foregroundStyle(Tokens.Color.textPrimary)
                        Spacer()
                    }
                    .padding(.horizontal, 14)
                    .frame(minHeight: 40)
                    Divider().overlay(Tokens.Color.hairline)
                }
            }
            .background(RoundedRectangle(cornerRadius: 16).fill(Tokens.Color.bgStrip))
        }
    }

    private func color(_ k: LogEvent.Kind) -> Color {
        switch k {
        case .ring, .loopGain, .overload, .watchdog: Tokens.Color.ring
        case .deepen, .thermal, .power: Tokens.Color.working
        case .release: Tokens.Color.safe
        default: Tokens.Color.textSecondary
        }
    }
}

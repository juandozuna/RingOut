import ActivityKit
import SwiftUI
import WidgetKit

@main
struct RingOutWidgetBundle: WidgetBundle {
    var body: some Widget { LiveSessionWidget() }
}

private func stateColor(_ s: Int) -> Color {
    switch s {
    case 1: Color(red: 0.95, green: 0.71, blue: 0.27)
    case 2: Color(red: 1.0, green: 0.30, blue: 0.30)
    case 3: Color(red: 0.49, green: 0.53, blue: 0.58)
    default: Color(red: 0.17, green: 0.84, blue: 0.46)
    }
}

private func stateLabel(_ s: Int) -> String {
    switch s {
    case 1: "Working"
    case 2: "Ring caught"
    case 3: "Bypassed"
    default: "Stable"
    }
}

struct LiveSessionWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: LiveSessionAttributes.self) { context in
            HStack(spacing: 16) {
                Circle().fill(stateColor(context.state.state)).frame(width: 14, height: 14)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Live — \(context.state.channels) channel\(context.state.channels == 1 ? "" : "s") active")
                        .font(.headline)
                    Text("\(context.attributes.interfaceName) · \(context.attributes.showName)")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(String(format: "%.1f ms", context.state.latencyMS)).font(.headline.monospacedDigit())
                    Text("\(stateLabel(context.state.state)) · \(context.state.activeNotches) notches")
                        .font(.caption).foregroundStyle(stateColor(context.state.state))
                }
            }
            .padding()
            .activityBackgroundTint(Color(red: 0.04, green: 0.05, blue: 0.06))
            .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) { Text("RingOut").font(.headline) }
                DynamicIslandExpandedRegion(.trailing) { Text(stateLabel(context.state.state)).foregroundStyle(stateColor(context.state.state)) }
                DynamicIslandExpandedRegion(.bottom) { Text("\(context.state.channels) ch · \(String(format: "%.1f ms", context.state.latencyMS))") }
            } compactLeading: {
                Circle().fill(stateColor(context.state.state)).frame(width: 10, height: 10)
            } compactTrailing: {
                Text("\(context.state.channels) ch")
            } minimal: {
                Circle().fill(stateColor(context.state.state)).frame(width: 10, height: 10)
            }
        }
    }
}

import SwiftUI

/// 160 pt rotary. Drag vertically or rotate around the centre; double-tap
/// returns to 80 %.
struct StrengthDial: View {
    var value: Float
    var enabled = true
    var tint: Color = Tokens.Color.accent
    var size: CGFloat = Tokens.Size.dial
    var onChange: (Float) -> Void

    @State private var dragStart: Float?

    private let sweep: Double = 270
    private var startAngle: Double { 135 }

    var body: some View {
        ZStack {
            Circle().fill(Tokens.Color.bgElevated)
            Circle()
                .trim(from: 0, to: sweep / 360)
                .stroke(Color.white.opacity(0.08), style: StrokeStyle(lineWidth: 12, lineCap: .round))
                .rotationEffect(.degrees(startAngle))
                .padding(10)
            Circle()
                .trim(from: 0, to: CGFloat(Double(value) * sweep / 360))
                .stroke(enabled ? tint : Tokens.Color.bypass, style: StrokeStyle(lineWidth: 12, lineCap: .round))
                .rotationEffect(.degrees(startAngle))
                .padding(10)
            // Default mark at 80 %
            Capsule().fill(Tokens.Color.textSecondary).frame(width: 2, height: 10)
                .offset(y: -size / 2 + 4)
                .rotationEffect(.degrees(startAngle + 90 + 0.8 * sweep))
            VStack(spacing: 0) {
                Text("\(Int((value * 100).rounded()))")
                    .font(Tokens.Font.numeral(size * 0.26, weight: .bold))
                    .foregroundStyle(Tokens.Color.textPrimary)
                    .contentTransition(.numericText())
                Text("STRENGTH %")
                    .font(Tokens.Font.label(11, weight: .bold))
                    .tracking(1)
                    .foregroundStyle(Tokens.Color.textSecondary)
            }
        }
        .frame(width: size, height: size)
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 2)
                .onChanged { g in
                    guard enabled else { return }
                    if dragStart == nil { dragStart = value }
                    let vertical = Float(-g.translation.height / 220)
                    let horizontal = Float(g.translation.width / 400)
                    onChange(min(max((dragStart ?? value) + vertical + horizontal, 0), 1))
                }
                .onEnded { _ in dragStart = nil }
        )
        .simultaneousGesture(TapGesture(count: 2).onEnded { if enabled { onChange(0.8) } })
        .opacity(enabled ? 1 : 0.45)
        .accessibilityElement()
        .accessibilityLabel("Strength")
        .accessibilityValue("\(Int(value * 100)) percent")
        .accessibilityAdjustableAction { dir in
            guard enabled else { return }
            onChange(min(max(value + (dir == .increment ? 0.05 : -0.05), 0), 1))
        }
        .accessibilityIdentifier("strengthDial")
    }
}

import SwiftUI

/// Vertical peak + RMS meter, −60..0 dBFS, with −18 / −6 marks, 2 s peak hold
/// and a clip latch that clears on tap.
struct LevelMeter: View {
    var peak: Float
    var rms: Float
    var hold: Float
    var clip: Bool
    var label: String
    var onClearClip: () -> Void = {}

    private let floor: Float = -60

    private func fraction(_ db: Float) -> CGFloat {
        CGFloat(min(max((db - floor) / -floor, 0), 1))
    }

    var body: some View {
        VStack(spacing: 6) {
            Button(action: onClearClip) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(clip ? Tokens.Color.meterRed : Tokens.Color.bgElevated)
                    .frame(height: 10)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(clip ? "\(label) clip, tap to clear" : "\(label) no clip")

            GeometryReader { geo in
                let h = geo.size.height
                ZStack(alignment: .bottom) {
                    RoundedRectangle(cornerRadius: 4).fill(Color.black.opacity(0.45))
                    // Peak fill with the three meter zones.
                    LinearGradient(
                        stops: [
                            .init(color: Tokens.Color.meterGreen, location: 0),
                            .init(color: Tokens.Color.meterGreen, location: fraction(-18)),
                            .init(color: Tokens.Color.meterAmber, location: fraction(-18)),
                            .init(color: Tokens.Color.meterAmber, location: fraction(-6)),
                            .init(color: Tokens.Color.meterRed, location: fraction(-6)),
                            .init(color: Tokens.Color.meterRed, location: 1),
                        ],
                        startPoint: .bottom, endPoint: .top)
                        .mask(alignment: .bottom) {
                            Rectangle().frame(height: h * fraction(peak))
                        }
                        .opacity(0.45)
                    // RMS body, brighter.
                    LinearGradient(colors: [Tokens.Color.meterGreen, Tokens.Color.meterGreen], startPoint: .bottom, endPoint: .top)
                        .mask(alignment: .bottom) { Rectangle().frame(height: h * fraction(rms)) }
                        .opacity(0.9)
                    // Peak hold line.
                    Rectangle()
                        .fill(hold > -6 ? Tokens.Color.meterRed : Tokens.Color.textPrimary)
                        .frame(height: 2)
                        .offset(y: -h * fraction(hold) + 1)
                        .opacity(hold > floor ? 1 : 0)
                    // −18 and −6 marks.
                    ForEach([-18, -6], id: \.self) { mark in
                        Rectangle().fill(Color.white.opacity(0.55)).frame(height: 1)
                            .offset(y: -h * fraction(Float(mark)))
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            .frame(width: Tokens.Size.meterWidth)

            Text(label)
                .font(Tokens.Font.label(13))
                .foregroundStyle(Tokens.Color.textSecondary)
        }
        .frame(width: Tokens.Size.meterWidth + 12)
        .accessibilityElement(children: .contain)
        .accessibilityValue("\(Int(peak)) dBFS peak")
    }
}

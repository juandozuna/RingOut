import SwiftUI

/// Log-frequency live spectrum, 100 Hz–20 kHz, with notch markers.
/// Active auto notches = amber lines whose height is depth; fixed notches =
/// grey with a lock glyph; a red flash marks a fresh detection for 300 ms.
struct SpectrumRibbon: View {
    var spectrum: [Float]
    var notches: [NotchInfo]
    var ringHz: Float
    var ringAge: Float
    var showAxis = true
    var draggable = false
    var onDragNotch: ((Int, Float) -> Void)? = nil

    static let fMin: Double = 100, fMax: Double = 20_000

    static func x(for hz: Float, width: CGFloat) -> CGFloat {
        let h = min(max(Double(hz), fMin), fMax)
        return CGFloat(log(h / fMin) / log(fMax / fMin)) * width
    }

    static func hz(for x: CGFloat, width: CGFloat) -> Float {
        let t = min(max(Double(x / width), 0), 1)
        return Float(fMin * pow(fMax / fMin, t))
    }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height - (showAxis ? 18 : 0)
            ZStack(alignment: .topLeading) {
                Canvas { ctx, size in
                    let plotH = h
                    // Grid
                    for f: Float in [200, 500, 1000, 2000, 5000, 10000] {
                        let x = Self.x(for: f, width: size.width)
                        ctx.stroke(Path { p in p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: plotH)) },
                                   with: .color(.white.opacity(0.06)), lineWidth: 1)
                    }
                    // Spectrum fill
                    guard spectrum.count > 1 else { return }
                    let n = spectrum.count
                    var path = Path()
                    path.move(to: CGPoint(x: 0, y: plotH))
                    for i in 0..<n {
                        let x = CGFloat(i) / CGFloat(n - 1) * size.width
                        let v = CGFloat(min(max((spectrum[i] + 96) / 96, 0), 1))
                        path.addLine(to: CGPoint(x: x, y: plotH - v * plotH))
                    }
                    path.addLine(to: CGPoint(x: size.width, y: plotH))
                    path.closeSubpath()
                    ctx.fill(path, with: .linearGradient(
                        Gradient(colors: [Tokens.Color.accent.opacity(0.55), Tokens.Color.accent.opacity(0.05)]),
                        startPoint: CGPoint(x: 0, y: 0), endPoint: CGPoint(x: 0, y: plotH)))
                    ctx.stroke(path, with: .color(Tokens.Color.accent.opacity(0.9)), lineWidth: 1.2)

                    // Ring flash
                    if ringHz > 0 && ringAge < 0.3 {
                        let x = Self.x(for: ringHz, width: size.width)
                        ctx.fill(Path(CGRect(x: x - 3, y: 0, width: 6, height: plotH)),
                                 with: .color(Tokens.Color.ring.opacity(Double(1 - ringAge / 0.3))))
                    }
                    // Notches
                    for notch in notches {
                        let x = Self.x(for: notch.frequency, width: size.width)
                        let depth = CGFloat(min(max(-notch.depth / 18, 0.15), 1))
                        let color = notch.fixed ? Tokens.Color.bypass : Tokens.Color.working
                        ctx.stroke(Path { p in p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: plotH * depth)) },
                                   with: .color(color), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    }
                }
                ForEach(notches.filter(\.fixed)) { notch in
                    Image(systemName: "lock.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Tokens.Color.bypass)
                        .position(x: Self.x(for: notch.frequency, width: w), y: min(h * CGFloat(min(max(-notch.depth / 18, 0.15), 1)) + 10, h - 6))
                }
                if draggable {
                    ForEach(notches) { notch in
                        Circle()
                            .fill(notch.fixed ? Tokens.Color.bypass : Tokens.Color.working)
                            .frame(width: 28, height: 28)
                            .overlay(Text("\(notch.slot + 1)").font(Tokens.Font.numeral(12)).foregroundStyle(.black))
                            .position(x: Self.x(for: notch.frequency, width: w), y: 18)
                            .gesture(DragGesture().onChanged { v in
                                onDragNotch?(notch.slot, Self.hz(for: v.location.x, width: w))
                            })
                            .accessibilityLabel("Notch \(notch.slot + 1) at \(Int(notch.frequency)) hertz")
                    }
                }
                if showAxis {
                    ForEach([(100, "100"), (300, "300"), (1000, "1k"), (3000, "3k"), (10000, "10k")], id: \.0) { f, label in
                        Text(label)
                            .font(Tokens.Font.numeral(11, weight: .medium))
                            .foregroundStyle(Tokens.Color.textSecondary)
                            .position(x: min(max(Self.x(for: Float(f), width: w), 10), w - 12), y: h + 9)
                    }
                }
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Spectrum, \(notches.count) notches")
    }
}

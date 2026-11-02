// Renders the RingOut app icon (1024 px PNG + SVG twin).
// Usage: swift tools/make_icon.swift <out.png>
import AppKit

let size = 1024.0
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon-1024.png"
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

// Background
ctx.setFillColor(rgb(0x0B0D10)); ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [rgb(0x1C2027), rgb(0x0B0D10)] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(grad, startCenter: CGPoint(x: 512, y: 560), startRadius: 0, endCenter: CGPoint(x: 512, y: 512), endRadius: 620, options: [])

// Safe ring
ctx.setLineWidth(46)
ctx.setStrokeColor(rgb(0x2BD576, 0.22)); ctx.strokeEllipse(in: CGRect(x: 152, y: 152, width: 720, height: 720))
ctx.setStrokeColor(rgb(0x2BD576)); ctx.setLineCap(.round)
ctx.addArc(center: CGPoint(x: 512, y: 512), radius: 360, startAngle: .pi * 0.62, endAngle: .pi * 2.38, clockwise: false)
ctx.strokePath()

// Spectrum line with a runaway peak
let path = CGMutablePath()
let baseY = 430.0
var pts: [CGPoint] = []
for i in 0...120 {
    let x = 250 + Double(i) / 120 * 524
    let t = Double(i) / 120
    var y = baseY + 60 * sin(t * 9) * exp(-t * 1.2) + 30 * sin(t * 23 + 1)
    let d = (t - 0.58) / 0.035
    y += 300 * exp(-d * d)
    pts.append(CGPoint(x: x, y: y))
}
path.move(to: CGPoint(x: 250, y: 330))
pts.forEach { path.addLine(to: $0) }
path.addLine(to: CGPoint(x: 774, y: 330)); path.closeSubpath()
ctx.addPath(path); ctx.setFillColor(rgb(0x4DA3FF, 0.22)); ctx.fillPath()
let line = CGMutablePath(); line.addLines(between: pts)
ctx.addPath(line); ctx.setStrokeColor(rgb(0x4DA3FF)); ctx.setLineWidth(18); ctx.setLineJoin(.round); ctx.strokePath()

// Ring peak cap (red) and the notch (amber) catching it
let peakX = 250 + 0.58 * 524
ctx.setFillColor(rgb(0xFF4D4D)); ctx.fillEllipse(in: CGRect(x: peakX - 26, y: baseY + 300 - 26 + 8, width: 52, height: 52))
ctx.setStrokeColor(rgb(0xF2B544)); ctx.setLineWidth(22); ctx.setLineCap(.round)
ctx.move(to: CGPoint(x: peakX, y: 720)); ctx.addLine(to: CGPoint(x: peakX, y: 560)); ctx.strokePath()

NSGraphicsContext.current = nil
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")

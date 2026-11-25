// Draws the Jeske Looper icon and writes an .iconset folder.
// Usage: make_icon <output.iconset>
import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset")
try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func render(_ pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    let scale = CGFloat(pixels) / 1024
    ctx.scaleBy(x: scale, y: scale)
    let space = CGColorSpace(name: CGColorSpace.sRGB)!

    // Body (macOS grid: 824 pt squircle centered in 1024).
    let body = CGPath(roundedRect: CGRect(x: 100, y: 100, width: 824, height: 824), cornerWidth: 186, cornerHeight: 186, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: color(0x000000, 0.35))
    ctx.addPath(body)
    ctx.setFillColor(color(0x241A5C))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(body)
    ctx.clip()
    let background = CGGradient(colorsSpace: space, colors: [color(0x8C6BFF), color(0x4B2FD6), color(0x1E1550)] as CFArray,
                                locations: [0, 0.55, 1])!
    ctx.drawLinearGradient(background, start: CGPoint(x: 300, y: 924), end: CGPoint(x: 724, y: 100),
                           options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    let glow = CGGradient(colorsSpace: space, colors: [color(0xFFFFFF, 0.22), color(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 380, y: 820), startRadius: 0,
                           endCenter: CGPoint(x: 380, y: 820), endRadius: 520, options: [])
    ctx.restoreGState()

    // Loop ring with an arrowhead.
    let center = CGPoint(x: 512, y: 512)
    let radius: CGFloat = 268
    let startAngle = CGFloat(68) * .pi / 180
    let endAngle = startAngle - CGFloat(292) * .pi / 180
    ctx.setLineCap(.round)
    ctx.setLineWidth(62)
    ctx.setStrokeColor(color(0xFFFFFF))
    ctx.addArc(center: center, radius: radius, startAngle: startAngle, endAngle: endAngle, clockwise: true)
    ctx.strokePath()

    let tip = CGPoint(x: center.x + radius * cos(endAngle), y: center.y + radius * sin(endAngle))
    let tangent = CGPoint(x: sin(endAngle), y: -cos(endAngle))   // clockwise direction
    let radial = CGPoint(x: cos(endAngle), y: sin(endAngle))
    func point(_ along: CGFloat, _ across: CGFloat) -> CGPoint {
        CGPoint(x: tip.x + tangent.x * along + radial.x * across, y: tip.y + tangent.y * along + radial.y * across)
    }
    ctx.setFillColor(color(0xFFFFFF))
    ctx.setLineJoin(.round)
    ctx.setLineWidth(18)
    ctx.setStrokeColor(color(0xFFFFFF))
    ctx.move(to: point(78, 0))
    ctx.addLine(to: point(-30, 82))
    ctx.addLine(to: point(-30, -82))
    ctx.closePath()
    ctx.drawPath(using: .fillStroke)

    // Waveform bars; the middle one in the record color.
    let heights: [CGFloat] = [96, 196, 290, 196, 96]
    let width: CGFloat = 44, gap: CGFloat = 24
    let total = CGFloat(heights.count) * width + CGFloat(heights.count - 1) * gap
    for (i, h) in heights.enumerated() {
        let x = center.x - total / 2 + CGFloat(i) * (width + gap)
        let bar = CGPath(roundedRect: CGRect(x: x, y: center.y - h / 2, width: width, height: h),
                         cornerWidth: width / 2, cornerHeight: width / 2, transform: nil)
        ctx.addPath(bar)
        ctx.setFillColor(i == 2 ? color(0xFF5A4E) : color(0xFFFFFF, 0.92))
        ctx.fillPath()
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let sizes: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, pixels) in sizes {
    try render(pixels).write(to: output.appendingPathComponent("\(name).png"))
}
print("Ícone gerado em \(output.path)")

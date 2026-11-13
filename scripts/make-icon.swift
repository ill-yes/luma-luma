import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
let sizes = [16, 32, 128, 256, 512]
let palette = [
    NSColor(srgbRed: 0.10, green: 0.16, blue: 0.35, alpha: 1),
    NSColor(srgbRed: 0.31, green: 0.25, blue: 0.66, alpha: 1)
]

for size in sizes {
    for scale in [1, 2] {
        let pixels = size * scale
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else { fatalError("Cannot create icon context") }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        let n = CGFloat(pixels)
        let body = NSBezierPath(roundedRect: NSRect(x: n * 0.08, y: n * 0.08, width: n * 0.84, height: n * 0.84),
                                xRadius: n * 0.20, yRadius: n * 0.20)
        NSGradient(colors: palette)?.draw(in: body, angle: 45)
        NSColor(srgbRed: 1, green: 0.85, blue: 0.55, alpha: 1).setFill()
        let sun = NSBezierPath(ovalIn: NSRect(x: n * 0.35, y: n * 0.35, width: n * 0.30, height: n * 0.30))
        sun.fill()
        NSColor(srgbRed: 1, green: 0.91, blue: 0.71, alpha: 1).setStroke()
        let rays = NSBezierPath()
        rays.lineWidth = n * 0.035
        rays.lineCapStyle = .round
        for index in 0..<8 {
            let angle = CGFloat(index) * .pi / 4
            rays.move(to: NSPoint(x: n * (0.5 + 0.212 * cos(angle)), y: n * (0.5 + 0.212 * sin(angle))))
            rays.line(to: NSPoint(x: n * (0.5 + 0.275 * cos(angle)), y: n * (0.5 + 0.275 * sin(angle))))
        }
        rays.stroke()
        NSGraphicsContext.restoreGraphicsState()
        let suffix = scale == 2 ? "@2x" : ""
        let file = output.appendingPathComponent("icon_\(size)x\(size)\(suffix).png")
        guard let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("Cannot encode icon") }
        try png.write(to: file)
    }
}

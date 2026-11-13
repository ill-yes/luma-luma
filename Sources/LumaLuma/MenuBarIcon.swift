import AppKit

@MainActor
enum MenuBarIcon {
    private static let idle = draw(active: false)
    private static let lit = draw(active: true)

    static func image(active: Bool) -> NSImage {
        active ? lit : idle
    }

    private static func draw(active: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.set()

            let sun = NSBezierPath()
            sun.appendArc(withCenter: NSPoint(x: 9, y: 6.25), radius: 4, startAngle: 0, endAngle: 180)
            if active {
                sun.close()
                sun.fill()
            }
            sun.lineWidth = 1.4
            sun.lineCapStyle = .round
            sun.stroke()

            let raysAndHorizon = NSBezierPath()
            raysAndHorizon.lineWidth = 1.4
            raysAndHorizon.lineCapStyle = .round
            raysAndHorizon.move(to: NSPoint(x: 2, y: 3.75))
            raysAndHorizon.line(to: NSPoint(x: 16, y: 3.75))
            raysAndHorizon.move(to: NSPoint(x: 9, y: 12.75))
            raysAndHorizon.line(to: NSPoint(x: 9, y: 15.25))
            raysAndHorizon.move(to: NSPoint(x: 4.4, y: 10.85))
            raysAndHorizon.line(to: NSPoint(x: 2.65, y: 12.6))
            raysAndHorizon.move(to: NSPoint(x: 13.6, y: 10.85))
            raysAndHorizon.line(to: NSPoint(x: 15.35, y: 12.6))
            raysAndHorizon.stroke()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Luma Luma"
        return image
    }
}

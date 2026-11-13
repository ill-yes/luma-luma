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
            sun.appendArc(withCenter: NSPoint(x: 9, y: 8.5), radius: 5.6, startAngle: 0, endAngle: 180)
            sun.close()
            if active {
                sun.fill()
            }
            sun.lineWidth = 1.4
            sun.lineJoinStyle = .round
            sun.stroke()

            let horizon = NSBezierPath(
                roundedRect: NSRect(x: 2, y: 5.5, width: 14, height: 1.4),
                xRadius: 0.7, yRadius: 0.7
            )
            horizon.fill()

            let lowerHorizon = NSBezierPath()
            lowerHorizon.appendArc(withCenter: NSPoint(x: 4.7, y: 3.7), radius: 0.7,
                                   startAngle: 90, endAngle: 270)
            lowerHorizon.line(to: NSPoint(x: 12.3, y: 3))
            lowerHorizon.line(to: NSPoint(x: 13.7, y: 4.4))
            lowerHorizon.close()
            lowerHorizon.fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Luma Luma"
        return image
    }
}

import AppKit
import Metal
import QuartzCore

enum DisplayScope: String, CaseIterable, Identifiable, Sendable {
    case all
    case builtIn
    case external

    var id: Self { self }
}

enum BoostRegion: String, CaseIterable, Identifiable, Sendable {
    case full
    case split
    case frontWindow

    var id: Self { self }
}

struct DisplayRenderSettings {
    let boost: Double
    let dim: Double
    let scope: DisplayScope
    let region: BoostRegion
    let ring: Double
    var ringWidth: Double = 0.45
    var ringWarmth: Double = 0.25
}

struct DisplayRenderReport: Equatable {
    let displayCount: Int
    let edrDisplayCount: Int
    let currentHeadroom: Double
    let potentialHeadroom: Double
}

@MainActor
final class DisplayRenderer {
    private var overlays: [CGDirectDisplayID: ScreenOverlays] = [:]
    private lazy var metal = MetalContext()

    func apply(_ settings: DisplayRenderSettings) -> DisplayRenderReport {
        let displays = NSScreen.screens.compactMap { screen -> (CGDirectDisplayID, NSScreen)? in
            guard let id = screen.lumaLumaDisplayID else { return nil }
            let isBuiltIn = CGDisplayIsBuiltin(id) != 0
            switch settings.scope {
            case .all: return (id, screen)
            case .builtIn: return isBuiltIn ? (id, screen) : nil
            case .external: return isBuiltIn ? nil : (id, screen)
            }
        }
        let boost = settings.boost.clamped(to: 0...1)
        let dim = settings.dim.clamped(to: 0...0.95)
        let ring = settings.ring.clamped(to: 0...1)
        let activeDisplays = Set(displays.map(\.0))
        let edrDisplays = displays.filter { $0.1.maximumPotentialExtendedDynamicRangeColorComponentValue > 1 }
        let report = DisplayRenderReport(
            displayCount: displays.count,
            edrDisplayCount: edrDisplays.count,
            currentHeadroom: edrDisplays.map { Double($0.1.maximumExtendedDynamicRangeColorComponentValue) }.max() ?? 1,
            potentialHeadroom: edrDisplays.map { Double($0.1.maximumPotentialExtendedDynamicRangeColorComponentValue) }.max() ?? 1
        )

        guard boost > 0 || dim > 0 || ring > 0 else {
            clear()
            return report
        }
        for id in overlays.keys.filter({ !activeDisplays.contains($0) }) {
            overlays.removeValue(forKey: id)?.clear()
        }

        let frontWindow = boost > 0 && settings.region == .frontWindow ? frontWindowFrame() : nil
        for (id, screen) in displays {
            let overlay = overlays[id] ?? ScreenOverlays()
            overlays[id] = overlay
            let potential = Double(screen.maximumPotentialExtendedDynamicRangeColorComponentValue)
            let current = Double(screen.maximumExtendedDynamicRangeColorComponentValue)
            // Present an HDR frame to activate EDR before current headroom has risen above 1.
            let available = current > 1.001 ? min(current, potential) : potential
            let gain = 1 + max(0, min(available, 3) - 1) * boost
            let frame = boostFrame(on: screen, region: settings.region, frontWindow: frontWindow)
            overlay.setBoost(gain, frame: frame, metal: gain > 1 && !frame.isEmpty ? metal : nil)
            overlay.setDimming(dim, frame: screen.frame)
            overlay.setRing(
                ring,
                width: settings.ringWidth.clamped(to: 0...1),
                warmth: settings.ringWarmth.clamped(to: 0...1),
                frame: screen.visibleFrame
            )
        }
        return report
    }

    func clear() {
        for overlay in overlays.values {
            overlay.clear()
        }
        overlays.removeAll()
    }

    private func boostFrame(on screen: NSScreen, region: BoostRegion, frontWindow: CGRect?) -> CGRect {
        let frame = screen.frame
        switch region {
        case .full:
            return frame
        case .split:
            return CGRect(x: frame.midX, y: frame.minY, width: frame.width / 2, height: frame.height)
        case .frontWindow:
            return frontWindow.map { frame.intersection($0) } ?? .zero
        }
    }

    private func frontWindowFrame() -> CGRect? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let primaryScreen = NSScreen.screens.first,
              let windows = CGWindowListCopyWindowInfo(
                  [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
              ) as? [[String: Any]]
        else { return nil }

        for window in windows {
            guard window[kCGWindowOwnerPID as String] as? Int32 == app.processIdentifier,
                  window[kCGWindowLayer as String] as? Int == 0,
                  (window[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  !rect.isEmpty
            else { continue }

            // Window server bounds have their origin at the top left of the primary display.
            return CGRect(
                x: primaryScreen.frame.minX + rect.minX,
                y: primaryScreen.frame.maxY - rect.maxY,
                width: rect.width,
                height: rect.height
            )
        }
        return nil
    }
}

@MainActor
private final class ScreenOverlays {
    private var boost: BoostOverlay?
    private var dim: OverlayWindow?
    private var ring: RingOverlay?

    func setBoost(_ gain: Double, frame: CGRect, metal: MetalContext?) {
        guard gain > 1, !frame.isEmpty, let metal else {
            boost?.window.orderOut(nil)
            boost = nil
            return
        }
        let overlay = boost ?? BoostOverlay(frame: frame, metal: metal)
        boost = overlay
        overlay.window.show(in: frame)
        overlay.setGain(gain)
    }

    func setDimming(_ opacity: Double, frame: CGRect) {
        guard opacity > 0 else {
            dim?.orderOut(nil)
            dim = nil
            return
        }
        let window = dim ?? OverlayWindow(frame: frame, belowMenu: 2)
        dim = window
        let color = NSColor.black.withAlphaComponent(opacity)
        if window.backgroundColor != color {
            window.backgroundColor = color
        }
        window.show(in: frame)
    }

    func setRing(_ strength: Double, width: Double, warmth: Double, frame: CGRect) {
        guard strength > 0, !frame.isEmpty else {
            ring?.window.orderOut(nil)
            ring = nil
            return
        }
        let overlay = ring ?? RingOverlay(frame: frame)
        ring = overlay
        overlay.setStyle(strength: strength, width: width, warmth: warmth)
        overlay.window.show(in: frame)
    }

    func clear() {
        boost?.window.orderOut(nil)
        dim?.orderOut(nil)
        ring?.window.orderOut(nil)
    }
}

@MainActor
private final class OverlayWindow: NSWindow {
    init(frame: CGRect, belowMenu: Int) {
        super.init(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        isExcludedFromWindowsMenu = true
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .canJoinAllApplications, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue - belowMenu)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func show(in rect: CGRect) {
        if frame != rect {
            setFrame(rect, display: true)
        }
        if !isVisible {
            orderFrontRegardless()
        }
    }
}

private struct MetalContext {
    let device: any MTLDevice
    let queue: any MTLCommandQueue
    let colorSpace: CGColorSpace

    init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let colorSpace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)
        else { return nil }
        self.device = device
        self.queue = queue
        self.colorSpace = colorSpace
    }
}

@MainActor
private final class BoostOverlay {
    let window: OverlayWindow
    private let metalLayer = CAMetalLayer()
    private let queue: any MTLCommandQueue
    private var requestedGain: Double?

    init(frame: CGRect, metal: MetalContext) {
        queue = metal.queue
        window = OverlayWindow(frame: frame, belowMenu: 3)
        metalLayer.device = metal.device
        metalLayer.pixelFormat = .rgba16Float
        metalLayer.colorspace = metal.colorSpace
        metalLayer.wantsExtendedDynamicRangeContent = true
        metalLayer.isOpaque = false
        metalLayer.compositingFilter = "multiply"
        metalLayer.allowsNextDrawableTimeout = true
        // A uniform color needs only one pixel. Core Animation scales it to the window.
        metalLayer.drawableSize = CGSize(width: 1, height: 1)
        let view = NSView(frame: CGRect(origin: .zero, size: frame.size))
        view.layer = metalLayer
        view.wantsLayer = true
        window.contentView = view
    }

    func setGain(_ gain: Double) {
        guard requestedGain.map({ abs($0 - gain) > 0.001 }) ?? true else { return }
        requestedGain = gain
        draw(gain, retries: 2)
    }

    private func draw(_ gain: Double, retries: Int) {
        guard requestedGain == gain, window.isVisible else { return }
        guard let buffer = queue.makeCommandBuffer(),
              let drawable = metalLayer.nextDrawable()
        else {
            retry(gain, remaining: retries)
            return
        }

        let pass = MTLRenderPassDescriptor()
        guard let color = pass.colorAttachments[0] else {
            retry(gain, remaining: retries)
            return
        }
        color.texture = drawable.texture
        color.loadAction = .clear
        color.storeAction = .store
        color.clearColor = MTLClearColorMake(gain, gain, gain, 1)
        guard let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else {
            retry(gain, remaining: retries)
            return
        }
        encoder.endEncoding()
        buffer.present(drawable)
        buffer.addCompletedHandler { [weak self] buffer in
            guard buffer.status == .error else { return }
            Task { @MainActor [weak self] in
                self?.retry(gain, remaining: retries)
            }
        }
        buffer.commit()
    }

    private func retry(_ gain: Double, remaining: Int) {
        guard requestedGain == gain, window.isVisible else { return }
        guard remaining > 0 else {
            requestedGain = nil
            return
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            self?.draw(gain, retries: remaining - 1)
        }
    }
}

@MainActor
private final class RingOverlay {
    let window: OverlayWindow
    private let view: RingView

    init(frame: CGRect) {
        window = OverlayWindow(frame: frame, belowMenu: 1)
        view = RingView(frame: CGRect(origin: .zero, size: frame.size))
        window.contentView = view
    }

    func setStyle(strength: Double, width: Double, warmth: Double) {
        view.setStyle(strength: strength, width: width, warmth: warmth)
    }
}

@MainActor
private final class RingView: NSView {
    private let shape = CAShapeLayer()
    private var widthFraction = 0.0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        shape.fillRule = .evenOdd
        layer?.addSublayer(shape)
    }

    required init?(coder: NSCoder) {
        return nil
    }

    override func layout() {
        super.layout()
        let edge = min(bounds.width, bounds.height)
        let thickness = edge * widthFraction
        let opening = bounds.insetBy(dx: thickness, dy: thickness)
        let radius = min(thickness * 0.8, 48)
        let path = CGMutablePath()
        path.addRect(bounds)
        path.addRoundedRect(in: opening, cornerWidth: radius, cornerHeight: radius)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shape.frame = bounds
        shape.path = path
        CATransaction.commit()
    }

    func setStyle(strength: Double, width: Double, warmth: Double) {
        let color = NSColor(
            red: 1, green: 1 - warmth * 0.22, blue: 1 - warmth * 0.50, alpha: strength
        ).cgColor
        if shape.fillColor != color {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            shape.fillColor = color
            CATransaction.commit()
        }
        let widthFraction = 0.045 + 0.155 * width
        if self.widthFraction != widthFraction {
            self.widthFraction = widthFraction
            needsLayout = true
        }
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        isFinite ? min(max(self, range.lowerBound), range.upperBound) : range.lowerBound
    }
}

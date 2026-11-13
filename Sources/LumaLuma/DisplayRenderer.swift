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
    let targetBoostDisplayCount: Int
    let activeBoostDisplayCount: Int
    let hasPendingBoost: Bool
    let gammaStatus: GammaBoostStatus?
    let gammaRestorationStatus: GammaBoostStatus?
    let currentHeadroom: Double
    let potentialHeadroom: Double
}

@MainActor
final class DisplayRenderer {
    var onBoostStateChanged: (() -> Void)?

    private var overlays: [CGDirectDisplayID: ScreenOverlays] = [:]
    private lazy var metal = MetalContext()
    private let gamma = GammaBoostSession()
    private var hdrTrigger: BoostOverlay?
    private var hdrTriggerDisplay: CGDirectDisplayID?

    init() {
        gamma.onStatusChanged = { [weak self] in self?.onBoostStateChanged?() }
    }

    func apply(_ settings: DisplayRenderSettings) -> DisplayRenderReport {
        let displays = NSScreen.screens(in: settings.scope)
        let boost = settings.boost.clamped(to: 0...1)
        let dim = settings.dim.clamped(to: 0...0.95)
        let ring = settings.ring.clamped(to: 0...1)
        let edrDisplays = displays.map(\.screen).filter { $0.maximumPotentialExtendedDynamicRangeColorComponentValue > 1 }
        let gammaDisplay = boost > 0 && settings.region == .full
            ? displays.first {
                CGDisplayIsBuiltin($0.id) != 0 && $0.screen.maximumPotentialExtendedDynamicRangeColorComponentValue > 1
            }
            : nil
        let gammaStatus = gammaDisplay.map { updateGamma(on: $0, strength: boost) }
        if gammaDisplay == nil { stopGamma() }
        var targetBoostDisplayCount = 0

        if boost > 0 || dim > 0 || ring > 0 {
            let selected = Set(displays.map(\.id))
            for id in overlays.keys.filter({ !selected.contains($0) }) {
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
                let gain = id == gammaDisplay?.id ? 1 : 1 + max(0, min(available, 3) - 1) * boost
                let frame = boostFrame(on: screen, region: settings.region, frontWindow: frontWindow)
                let wantsBoost = gain > 1 && !frame.isEmpty
                if wantsBoost { targetBoostDisplayCount += 1 }
                overlay.setBoost(gain, frame: frame, metal: wantsBoost ? metal : nil) { [weak self] in
                    self?.onBoostStateChanged?()
                }
                overlay.setDimming(dim, frame: screen.frame)
                overlay.setRing(
                    ring,
                    width: settings.ringWidth.clamped(to: 0...1),
                    warmth: settings.ringWarmth.clamped(to: 0...1),
                    frame: screen.visibleFrame
                )
            }
        } else {
            clearOverlays()
        }

        return DisplayRenderReport(
            displayCount: displays.count,
            edrDisplayCount: edrDisplays.count,
            targetBoostDisplayCount: targetBoostDisplayCount + (gammaDisplay == nil ? 0 : 1),
            activeBoostDisplayCount: overlays.values.count { $0.boostState == .active } + (gammaStatus == .active ? 1 : 0),
            hasPendingBoost: gammaStatus == .starting || overlays.values.contains { $0.boostState == .pending },
            gammaStatus: gammaStatus,
            gammaRestorationStatus: gamma.restorationStatus,
            currentHeadroom: edrDisplays.map { Double($0.maximumExtendedDynamicRangeColorComponentValue) }.max() ?? 1,
            potentialHeadroom: edrDisplays.map { Double($0.maximumPotentialExtendedDynamicRangeColorComponentValue) }.max() ?? 1
        )
    }

    func clear(waitForGammaRestoration: Bool = false) {
        stopGamma(waitForRestoration: waitForGammaRestoration)
        clearOverlays()
    }

    private func clearOverlays() {
        for overlay in overlays.values {
            overlay.clear()
        }
        overlays.removeAll()
    }

    private func updateGamma(
        on display: (id: CGDirectDisplayID, screen: NSScreen),
        strength: Double
    ) -> GammaBoostStatus {
        if hdrTriggerDisplay != display.id {
            removeHDRTrigger()
        }
        let status = gamma.update(
            displayID: display.id,
            strength: strength,
            currentHeadroom: display.screen.maximumExtendedDynamicRangeColorComponentValue,
            triggerReady: hdrTrigger?.state == .active
        )
        guard gamma.needsTrigger, let metal else {
            if !gamma.isRestoring { removeHDRTrigger() }
            return status
        }
        let visible = display.screen.visibleFrame
        let frame = CGRect(x: visible.maxX - 9, y: visible.minY + 8, width: 1, height: 1)
        let trigger = hdrTrigger ?? BoostOverlay(frame: frame, metal: metal, multiply: false) { [weak self] in
            self?.onBoostStateChanged?()
        }
        hdrTrigger = trigger
        hdrTriggerDisplay = display.id
        trigger.window.show(in: frame)
        trigger.setGain(1.5)
        return status
    }

    private func stopGamma(waitForRestoration: Bool = false) {
        gamma.stop(waitForRestoration: waitForRestoration)
        if waitForRestoration || !gamma.isRestoring { removeHDRTrigger() }
    }

    private func removeHDRTrigger() {
        hdrTrigger?.close()
        hdrTrigger = nil
        hdrTriggerDisplay = nil
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

    var boostState: BoostOverlay.State? { boost?.state }

    func setBoost(_ gain: Double, frame: CGRect, metal: MetalContext?, onStateChanged: @escaping () -> Void) {
        guard let metal else {
            boost?.close()
            boost = nil
            return
        }
        let overlay = boost ?? BoostOverlay(frame: frame, metal: metal, onStateChanged: onStateChanged)
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
        boost?.close()
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
    enum State {
        case pending
        case active
        case unavailable
    }

    private static let retryDelays: [Duration] = [
        .milliseconds(150), .milliseconds(400), .seconds(2), .seconds(5), .seconds(15)
    ]

    let window: OverlayWindow
    private(set) var state = State.pending
    private let frames: BoostFrameRenderer
    private let onStateChanged: () -> Void
    private var requestedGain: Double?
    private var rendering = false
    private var failures = 0
    private var retryTask: Task<Void, Never>?

    init(
        frame: CGRect,
        metal: MetalContext,
        multiply: Bool = true,
        onStateChanged: @escaping () -> Void
    ) {
        self.onStateChanged = onStateChanged
        window = OverlayWindow(frame: frame, belowMenu: 3)
        let metalLayer = CAMetalLayer()
        metalLayer.device = metal.device
        metalLayer.pixelFormat = .rgba16Float
        metalLayer.colorspace = metal.colorSpace
        metalLayer.wantsExtendedDynamicRangeContent = true
        metalLayer.isOpaque = false
        if multiply { metalLayer.compositingFilter = "multiply" }
        metalLayer.allowsNextDrawableTimeout = true
        // A uniform color needs only one pixel. Core Animation scales it to the window.
        metalLayer.drawableSize = CGSize(width: 1, height: 1)
        let view = NSView(frame: CGRect(origin: .zero, size: frame.size))
        view.layer = metalLayer
        view.wantsLayer = true
        window.contentView = view
        frames = BoostFrameRenderer(layer: metalLayer, commandQueue: metal.queue)
    }

    func setGain(_ gain: Double) {
        guard requestedGain.map({ abs($0 - gain) > 0.001 }) ?? true else { return }
        requestedGain = gain
        draw()
    }

    func close() {
        requestedGain = nil
        retryTask?.cancel()
        retryTask = nil
        window.orderOut(nil)
    }

    private func draw() {
        guard let gain = requestedGain, window.isVisible, !rendering, retryTask == nil else { return }
        rendering = true
        frames.render(gain: gain) { [weak self] frame in
            Task { @MainActor [weak self] in
                self?.renderCompleted(frame, gain: gain)
            }
        }
    }

    private func renderCompleted(_ frame: RenderedBoostFrame?, gain: Double) {
        rendering = false
        guard let requestedGain, window.isVisible else { return }
        guard let frame else {
            scheduleRetry()
            return
        }
        failures = 0
        guard gain == requestedGain else {
            draw()
            return
        }
        frame.present()
        if state != .active {
            state = .active
            onStateChanged()
        }
    }

    private func scheduleRetry() {
        let delay = Self.retryDelays[failures]
        failures = min(failures + 1, Self.retryDelays.count - 1)
        retryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            retryTask = nil
            draw()
        }
        if failures >= 3, state != .unavailable {
            state = .unavailable
            onStateChanged()
        }
    }
}

// Core Animation setup and attachment stay on the main actor. The only operation on the
// layer from this serial queue is drawable acquisition, which can block for up to a second.
private final class BoostFrameRenderer: @unchecked Sendable {
    private let layer: CAMetalLayer
    private let commandQueue: any MTLCommandQueue
    private let submissionQueue = DispatchQueue(label: "dev.illyes.lumaluma.metal", qos: .userInitiated)

    init(layer: CAMetalLayer, commandQueue: any MTLCommandQueue) {
        self.layer = layer
        self.commandQueue = commandQueue
    }

    func render(gain: Double, completion: @escaping @Sendable (RenderedBoostFrame?) -> Void) {
        submissionQueue.async {
            autoreleasepool {
                let pass = MTLRenderPassDescriptor()
                guard let buffer = self.commandQueue.makeCommandBuffer(),
                      let color = pass.colorAttachments[0],
                      let drawable = self.layer.nextDrawable() else {
                    completion(nil)
                    return
                }
                color.texture = drawable.texture
                color.loadAction = .clear
                color.storeAction = .store
                color.clearColor = MTLClearColorMake(gain, gain, gain, 1)
                guard let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else {
                    completion(nil)
                    return
                }
                encoder.endEncoding()
                let frame = RenderedBoostFrame(drawable: drawable)
                buffer.addCompletedHandler { buffer in
                    completion(buffer.status == .completed ? frame : nil)
                }
                buffer.commit()
            }
        }
    }
}

// The GPU writes the drawable first, then the main actor alone may present it.
private struct RenderedBoostFrame: @unchecked Sendable {
    let drawable: any CAMetalDrawable

    @MainActor
    func present() {
        drawable.present()
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

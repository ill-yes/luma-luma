import AppKit
import Metal
import QuartzCore

struct DisplayRenderTarget {
    let id: CGDirectDisplayID
    let screen: NSScreen
    let boost: Double
    let dim: Double
    let region: BoostRegion
    let ring: Double
    let ringWidth: Double
    let ringWarmth: Double
}

enum DisplayBoostPath: Equatable {
    case gamma
    case overlay
}

enum DisplayBoostStatus: Equatable {
    case off
    case preparing
    case active
    case restoring
    case unsupported
    case waitingForWindow
    case unavailable
    case conflict
    case failed
    case restorationFailed

    init(gammaStatus: GammaBoostStatus) {
        switch gammaStatus {
        case .starting: self = .preparing
        case .active: self = .active
        case .unavailable: self = .unavailable
        case .conflict: self = .conflict
        case .failed: self = .failed
        case .restorationFailed: self = .restorationFailed
        }
    }
}

struct DisplayRenderResult: Equatable {
    let requestedBoost: Double
    let appliedGain: Double?
    let boostPath: DisplayBoostPath?
    let boostStatus: DisplayBoostStatus
    let currentHeadroom: Double
    let potentialHeadroom: Double
    let hasActiveEffect: Bool
}

struct DisplayRenderReport: Equatable {
    let displayCount: Int
    let edrDisplayCount: Int
    let targetBoostDisplayCount: Int
    let activeBoostDisplayCount: Int
    let hasPendingBoost: Bool
    let gammaStatus: GammaBoostStatus?
    let gammaRestorationStatus: GammaBoostStatus?
    let isRestoringCurve: Bool
    let currentHeadroom: Double
    let potentialHeadroom: Double
    let displays: [CGDirectDisplayID: DisplayRenderResult]
}

@MainActor
final class DisplayRenderer {
    var onBoostStateChanged: (() -> Void)?

    private var overlays: [CGDirectDisplayID: ScreenOverlays] = [:]
    private lazy var metal = MetalContext()
    private let gamma = GammaBoostSession()
    private var hdrTrigger: BoostOverlay?
    private var hdrTriggerDisplay: CGDirectDisplayID?
    private var lastGamma: (displayID: CGDirectDisplayID, status: GammaBoostStatus)?

    init() {
        gamma.onStatusChanged = { [weak self] in
            guard let self else { return }
            if !gamma.isRestoring && !gamma.needsTrigger { removeHDRTrigger() }
            onBoostStateChanged?()
        }
    }

    var isRestoringCurve: Bool { gamma.isRestoring }

    func isRestoringCurve(on displayID: CGDirectDisplayID) -> Bool {
        gamma.isRestoring(on: displayID)
    }

    func restoreBrightness(on displayID: CGDirectDisplayID, completion: @escaping (GammaEndResult) -> Void) {
        overlays[displayID]?.removeBoost()
        if lastGamma?.displayID == displayID { lastGamma = nil }
        gamma.restore(on: displayID) { [weak self] result in
            if let self, hdrTriggerDisplay == displayID, !gamma.needsTrigger { removeHDRTrigger() }
            completion(result)
        }
    }

    func forgetDisplay(_ id: CGDirectDisplayID) {
        clearDisplay(id)
        gamma.forgetDisplay(id)
    }

    func reassociateDisplay(from oldID: CGDirectDisplayID, to newID: CGDirectDisplayID) {
        guard oldID != newID else { return }
        clearDisplay(oldID)
        clearDisplay(newID)
        gamma.reassociateDisplay(from: oldID, to: newID)
    }

    private func clearDisplay(_ id: CGDirectDisplayID) {
        overlays.removeValue(forKey: id)?.clear()
        if lastGamma?.displayID == id { lastGamma = nil }
        if hdrTriggerDisplay == id { removeHDRTrigger() }
    }

    func keyBoostState(
        displayID: CGDirectDisplayID,
        screen: NSScreen,
        region: BoostRegion,
        requested: Bool
    ) -> BrightnessKeyRouting.BoostState {
        guard screen.maximumPotentialExtendedDynamicRangeColorComponentValue > 1, metal != nil else {
            return .unavailable
        }
        if region == .frontWindow,
           boostFrame(on: screen, region: region, frontWindow: frontWindowFrame()).isEmpty {
            return .unavailable
        }
        guard requested else { return .ready }
        if region == .full, CGDisplayIsBuiltin(displayID) != 0 {
            return keyState(for: lastGamma?.displayID == displayID ? lastGamma?.status : nil)
        }
        guard gamma.restorationFailure(on: displayID) == nil else { return .unavailable }
        switch overlays[displayID]?.boostState {
        case .active: return .active
        case .pending, nil: return .starting
        case .unavailable: return .unavailable
        }
    }

    private func keyState(for status: GammaBoostStatus?) -> BrightnessKeyRouting.BoostState {
        switch status {
        case .active: return .active
        case .starting, nil: return .starting
        default: return .unavailable
        }
    }

    func apply(_ targets: [DisplayRenderTarget]) -> DisplayRenderReport {
        let gammaTarget = targets.first {
            $0.boost.clamped(to: 0...1) > 0 && $0.region == .full && CGDisplayIsBuiltin($0.id) != 0
                && $0.screen.maximumPotentialExtendedDynamicRangeColorComponentValue > 1
        }
        lastGamma = nil
        if let gammaTarget, metal != nil {
            lastGamma = (gammaTarget.id, updateGamma(on: gammaTarget))
        } else {
            stopGamma()
        }
        let selected = Set(targets.map(\.id))
        for id in overlays.keys.filter({ !selected.contains($0) }) {
            overlays.removeValue(forKey: id)?.clear()
        }

        let needsFrontWindow = targets.contains { $0.boost > 0 && $0.region == .frontWindow }
        let frontWindow = needsFrontWindow ? frontWindowFrame() : nil
        var results: [CGDirectDisplayID: DisplayRenderResult] = [:]
        var targetBoostDisplayCount = 0
        for target in targets {
            let id = target.id
            let screen = target.screen
            let boost = target.boost.clamped(to: 0...1)
            let dim = target.dim.clamped(to: 0...0.95)
            let ring = target.ring.clamped(to: 0...1)
            let potential = max(1, Double(screen.maximumPotentialExtendedDynamicRangeColorComponentValue))
            let current = max(1, Double(screen.maximumExtendedDynamicRangeColorComponentValue))
            let frame = boost > 0 ? boostFrame(on: screen, region: target.region, frontWindow: frontWindow) : .zero
            let wantsBoost = boost > 0 && potential > 1 && !frame.isEmpty
            if wantsBoost { targetBoostDisplayCount += 1 }
            let restoring = gamma.isRestoring(on: id)
            let usesGamma = gammaTarget?.id == id
            let overlayAllowed = wantsBoost && !usesGamma && !restoring && gamma.restorationFailure(on: id) == nil
            let overlayMetal = overlayAllowed ? metal : nil
            if overlayMetal != nil || dim > 0 || ring > 0 {
                let overlay = overlays[id] ?? ScreenOverlays()
                overlays[id] = overlay
                // Present an HDR frame to activate EDR before current headroom has risen above 1.
                let available = current > 1.001 ? min(current, potential) : potential
                let gain = 1 + (min(available, 3) - 1) * boost
                overlay.setBoost(gain, frame: frame, metal: overlayMetal) { [weak self] in
                    self?.onBoostStateChanged?()
                }
                overlay.setDimming(dim, frame: screen.frame)
                overlay.setRing(
                    ring,
                    width: target.ringWidth.clamped(to: 0...1),
                    warmth: target.ringWarmth.clamped(to: 0...1),
                    frame: screen.visibleFrame
                )
            } else {
                overlays.removeValue(forKey: id)?.clear()
            }

            let path: DisplayBoostPath? = wantsBoost ? (usesGamma ? .gamma : .overlay) : nil
            let appliedGain = usesGamma ? gamma.appliedGain(on: id) : overlays[id]?.appliedBoostGain
            let status = boostStatus(on: id, strength: boost, potential: potential, frame: frame, path: path)
            results[id] = DisplayRenderResult(
                requestedBoost: boost, appliedGain: appliedGain,
                boostPath: restoring ? .gamma : path, boostStatus: status,
                currentHeadroom: current, potentialHeadroom: potential,
                hasActiveEffect: appliedGain != nil || dim > 0 || (ring > 0 && !screen.visibleFrame.isEmpty)
            )
        }

        let edrDisplays = results.values.filter { $0.potentialHeadroom > 1 }
        return DisplayRenderReport(
            displayCount: targets.count,
            edrDisplayCount: edrDisplays.count,
            targetBoostDisplayCount: targetBoostDisplayCount,
            activeBoostDisplayCount: results.values.count { $0.appliedGain != nil },
            hasPendingBoost: results.values.contains { $0.boostStatus == .preparing },
            gammaStatus: lastGamma?.status,
            gammaRestorationStatus: gamma.restorationStatus,
            isRestoringCurve: gamma.isRestoring,
            currentHeadroom: edrDisplays.map(\.currentHeadroom).max() ?? 1,
            potentialHeadroom: edrDisplays.map(\.potentialHeadroom).max() ?? 1,
            displays: results
        )
    }

    private func boostStatus(
        on id: CGDirectDisplayID,
        strength: Double,
        potential: Double,
        frame: CGRect,
        path: DisplayBoostPath?
    ) -> DisplayBoostStatus {
        if gamma.isRestoring(on: id) { return .restoring }
        if path == .gamma, let lastGamma, lastGamma.displayID == id {
            return DisplayBoostStatus(gammaStatus: lastGamma.status)
        }
        if let failure = gamma.restorationFailure(on: id) {
            return DisplayBoostStatus(gammaStatus: failure)
        }
        guard strength > 0 else { return .off }
        guard potential > 1 else { return .unsupported }
        guard !frame.isEmpty else { return .waitingForWindow }
        switch overlays[id]?.boostState {
        case .pending: return .preparing
        case .active: return .active
        case .unavailable, nil: return .unavailable
        }
    }

    func clear(waitForGammaRestoration: Bool = false) {
        lastGamma = nil
        stopGamma(waitForRestoration: waitForGammaRestoration)
        clearOverlays()
    }

    private func clearOverlays() {
        for overlay in overlays.values {
            overlay.clear()
        }
        overlays.removeAll()
    }

    private func updateGamma(on display: DisplayRenderTarget) -> GammaBoostStatus {
        let status = gamma.update(
            displayID: display.id,
            strength: display.boost,
            currentHeadroom: display.screen.maximumExtendedDynamicRangeColorComponentValue,
            triggerReady: hdrTriggerDisplay == display.id && hdrTrigger?.state == .active
        )
        if gamma.isRestoring { return status }
        guard gamma.needsTrigger, let metal else {
            removeHDRTrigger()
            return status
        }
        if hdrTriggerDisplay != display.id { removeHDRTrigger() }
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
    var appliedBoostGain: Double? { boost?.appliedGain }

    func setBoost(_ gain: Double, frame: CGRect, metal: MetalContext?, onStateChanged: @escaping () -> Void) {
        guard let metal else {
            removeBoost()
            return
        }
        let overlay = boost ?? BoostOverlay(frame: frame, metal: metal, onStateChanged: onStateChanged)
        boost = overlay
        overlay.window.show(in: frame)
        overlay.setGain(gain)
    }

    func removeBoost() {
        boost?.close()
        boost = nil
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
        removeBoost()
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
    private(set) var appliedGain: Double?
    private let frames: BoostFrameRenderer
    private let onStateChanged: () -> Void
    private var requestedGain: Double?
    private var presentation: UUID?
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
        presentation = nil
        appliedGain = nil
        retryTask?.cancel()
        retryTask = nil
        window.orderOut(nil)
    }

    private func draw() {
        guard let gain = requestedGain, window.isVisible, !rendering, presentation == nil, retryTask == nil else {
            return
        }
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
        guard gain == requestedGain else {
            draw()
            return
        }
        guard let frame else {
            scheduleRetry()
            return
        }
        let token = UUID()
        presentation = token
        frame.present { [weak self] didPresent in
            Task { @MainActor [weak self] in
                self?.presentationCompleted(token, gain: gain, didPresent: didPresent)
            }
        }
    }

    private func presentationCompleted(_ token: UUID, gain: Double, didPresent: Bool) {
        guard presentation == token, let requestedGain, window.isVisible else { return }
        presentation = nil
        guard didPresent else {
            if gain == requestedGain { scheduleRetry() } else { draw() }
            return
        }
        failures = 0
        let changed = state != .active || appliedGain != gain
        state = .active
        appliedGain = gain
        if changed { onStateChanged() }
        if gain != requestedGain { draw() }
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
        if failures >= 3, appliedGain == nil, state != .unavailable {
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
    func present(completion: @escaping @Sendable (Bool) -> Void) {
        drawable.addPresentedHandler { completion($0.presentedTime > 0) }
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

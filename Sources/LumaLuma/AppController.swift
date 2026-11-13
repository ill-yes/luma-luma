import AppKit
import Combine
import IOKit.ps
import ServiceManagement
import SwiftUI
import os

@MainActor
final class AppController: NSObject, NSApplicationDelegate, ObservableObject {
    let preferences = Preferences()
    @Published private var lighting = LightingState()
    @Published private(set) var report: DisplayRenderReport?
    @Published private(set) var loginEnabled = false
    @Published private(set) var shortcutError: String?
    @Published private(set) var loginMessage: String?
    @Published private(set) var paused = false
    @Published var settingsTab: SettingsTab = .general
    @Published private(set) var selectedDisplayID: CGDirectDisplayID?
    @Published private(set) var profileDisplays: [DisplayControlChoice] = []
    @Published private(set) var ambientStatus = "Automatic boost is off"
    @Published private var nativeLevels: [CGDirectDisplayID: Double] = [:]
    @Published private var displayBoost = DisplayBoostSession()
    @Published private var brightnessError: String?
    var mode: LightingMode { lighting.mode }
    var selectedEffect: LightingEffect { lighting.selectedEffect }
    var isEnabled: Bool { lighting.isEnabled }
    var isRestoringCurve: Bool { renderer.isRestoringCurve }
    var hasActiveEffect: Bool {
        !paused && mode != .off && report?.displays.values.contains(where: \.hasActiveEffect) == true
    }

    private let log = Logger(subsystem: "dev.illyes.lumaluma", category: "display")
    private let renderer = DisplayRenderer()
    private var brightnessIndicator: BrightnessIndicator?
    private lazy var hardware = AppleBrightness()
    private lazy var shortcuts = ShortcutController(
        onAction: { [weak self] action in self?.perform(action) },
        onBrightnessKey: { [weak self] increase, fine in
            self?.handleBrightnessKey(increase: increase, fine: fine) ?? false
        }
    )
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var controlsWindow: NSWindow?
    private var preferencesWindow: NSWindow?
    private var preferenceChanges: AnyCancellable?
    private var tick: Timer?
    private var ambientTimer: Timer?
    private var powerTimer: Timer?
    private var powerSource: CFRunLoopSource?
    private var renderingQueued = false
    private var automationResult: Bool?
    private var previousRule: PowerRule?
    private var previousThreshold: Int?
    private var previousDefaultBoost: Double?
    private var previousAmbientEnabled = false
    private var powerOwnsBoost = false
    private var ambientPolicy = AmbientBoostPolicy()
    private var ambientDisplayID: CGDirectDisplayID?
    private var ambientFailure: String?
    private var displays: [ConnectedDisplay] = []
    private var knownIdentities: [CGDirectDisplayID: UUID] = [:]
    private var connectionProfiles: [CGDirectDisplayID: DisplayProfile] = [:]
    @Published private var brightnessTransition = BrightnessTransition()
    private var brightnessChangeQueued = false
    private var systemSleeping = false
    private var screensSleeping = false
    private var locked = false
    private var sessionInactive = false
    private var ready = false
    private var pendingURLs: [URL] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        renderer.onBoostStateChanged = { [weak self] in self?.queueRefresh() }
        installStatusItem()
        installApplicationMenu()
        installNotifications()
        powerSource = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let controller = Unmanaged<AppController>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { controller.refreshAutomation() }
        }, Unmanaged.passUnretained(self).toOpaque())?.takeRetainedValue()
        if let powerSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), powerSource, .commonModes)
        }
        updateLoginStatus()
        ready = true
        updateDisplayInventory()
        updatePreferences(initial: true)
        if !pendingURLs.isEmpty {
            let urls = pendingURLs
            pendingURLs.removeAll()
            application(NSApplication.shared, open: urls)
        } else if !UserDefaults.standard.bool(forKey: "hasOpenedLumaLuma") {
            showControls()
        }
        UserDefaults.standard.set(true, forKey: "hasOpenedLumaLuma")
        preferenceChanges = preferences.objectWillChange.sink { [weak self] in
            Task { @MainActor in self?.updatePreferences() }
        }
        updateRefreshTimer()
    }

    func applicationWillTerminate(_ notification: Notification) {
        ready = false
        tick?.invalidate()
        ambientTimer?.invalidate()
        powerTimer?.invalidate()
        brightnessTransition.cancel()
        if let powerSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), powerSource, .commonModes)
        }
        preferenceChanges?.cancel()
        shortcuts.stop()
        brightnessIndicator?.hide()
        renderer.onBoostStateChanged = nil
        renderer.clear(waitForGammaRestoration: true)
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        DistributedNotificationCenter.default().removeObserver(self)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        showControls()
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard ready else {
            pendingURLs.append(contentsOf: urls)
            return
        }
        for url in urls {
            guard url.scheme == "lumaluma", url.path.isEmpty, url.query == nil,
                  url.user == nil, url.password == nil, url.port == nil, url.fragment == nil else { continue }
            switch url.host {
            case "on": select(.boost)
            case "off": select(.off)
            case "toggle": toggle()
            default: continue
            }
        }
    }

    func select(_ next: LightingMode) {
        guard let effect = next.effect else {
            setEnabled(false)
            return
        }
        takeManualControl()
        changeLighting { $0.activate(effect) }
    }

    func selectEffect(_ effect: LightingEffect) {
        guard selectedEffect != effect else { return }
        takeManualControl()
        changeLighting { $0.selectEffect(effect) }
    }

    func setEnabled(_ enabled: Bool) {
        guard isEnabled != enabled else { return }
        takeManualControl(suppressAuto: !enabled)
        changeLighting { $0.setEnabled(enabled) }
    }

    private func changeLighting(_ change: (inout LightingState) -> Bool) {
        var next = lighting
        guard change(&next) else { return }
        if next.mode != mode {
            brightnessTransition.cancel()
            brightnessError = nil
            displayBoost = DisplayBoostSession()
            resetRendering()
        }
        lighting = next
        log.info("Selected effect \(self.selectedEffect.rawValue, privacy: .public); enabled \(self.isEnabled)")
        queueRefresh()
        updateRefreshTimer()
        updateStatusItem()
    }

    private func takeManualControl(suppressAuto: Bool = false) {
        let wasAutomatic = ambientDisplayID != nil
        ambientDisplayID = nil
        powerOwnsBoost = false
        if suppressAuto, preferences.ambientBoostEnabled {
            ambientPolicy.suppressUntilDark()
        } else if wasAutomatic {
            ambientPolicy.pause()
        }
        if wasAutomatic, !suppressAuto { setAmbientStatus("Manual effect is active") }
    }

    private var selectedDisplays: [ConnectedDisplay] {
        displays.filter { preferences.scope.includes(builtIn: $0.builtIn) &&
            displayProfile(for: $0.id).participates != false }
    }

    private var controlledDisplay: ConnectedDisplay? {
        selectedDisplays.first { $0.id == selectedDisplayID }
    }

    var controlDisplays: [DisplayControlChoice] { selectedDisplays.map(\.choice) }

    func selectDisplay(_ id: CGDirectDisplayID?) {
        guard id != selectedDisplayID, controlDisplays.contains(where: { $0.id == id }) else { return }
        brightnessTransition.cancel()
        brightnessError = nil
        selectedDisplayID = id
        queueRefresh()
    }

    private func reconcileControlTarget() {
        let selected = selectedDisplays
        if let target = displayBoost.singleDisplay, !selected.contains(where: { $0.id == target }) {
            if ambientDisplayID != nil {
                stopAmbientBoost()
                ambientPolicy.pause()
            } else {
                changeLighting { $0.setEnabled(false) }
            }
        }
        if !selected.contains(where: { $0.id == selectedDisplayID }) {
            brightnessTransition.cancel()
            brightnessError = nil
            let next = selected.first(where: \.builtIn)?.id ?? selected.first?.id
            if next != selectedDisplayID { selectedDisplayID = next }
        }
        if let pending = brightnessTransition.request, !selected.contains(where: { $0.id == pending.displayID }) {
            brightnessTransition.cancel()
        }
    }

    private func updateDisplayInventory() {
        let connected = ConnectedDisplay.current()
        for display in connected {
            if let identity = display.identity {
                if let previous = knownIdentities[display.id], previous != identity {
                    if displayBoost.singleDisplay == display.id {
                        stopAmbientBoost()
                        changeLighting { $0.setEnabled(false) }
                    }
                    renderer.forgetDisplay(display.id)
                    displayBoost.levels[display.id] = nil
                    connectionProfiles[display.id] = nil
                }
                if let oldID = knownIdentities.first(where: { $0.value == identity && $0.key != display.id })?.key {
                    renderer.reassociateDisplay(from: oldID, to: display.id)
                    knownIdentities[oldID] = nil
                }
                knownIdentities[display.id] = identity
            }
        }
        let liveIDs = Set(connected.map(\.id))
        displayBoost.levels = displayBoost.levels.filter { liveIDs.contains($0.key) }
        connectionProfiles = connectionProfiles.filter { id, _ in
            connected.contains { $0.id == id && $0.identity == nil }
        }
        displays = connected
        profileDisplays = connected.map(\.choice)
        reconcileControlTarget()
    }

    func displayProfile(for id: CGDirectDisplayID) -> DisplayProfile {
        if let identity = displays.first(where: { $0.id == id })?.identity {
            return preferences.displayProfiles[identity] ?? DisplayProfile()
        }
        return connectionProfiles[id] ?? DisplayProfile()
    }

    func isDisplayProfilePersistent(_ id: CGDirectDisplayID) -> Bool {
        displays.first(where: { $0.id == id })?.identity != nil
    }

    func setDisplayProfile(_ profile: DisplayProfile, for id: CGDirectDisplayID) {
        guard let display = displays.first(where: { $0.id == id }) else { return }
        let profile = profile.validated
        let previous = displayProfile(for: id)
        guard previous != profile else { return }
        if previous.boost != profile.boost { displayBoost.levels[id] = nil }
        if let identity = display.identity {
            preferences.setDisplayProfile(profile, for: identity)
        } else {
            connectionProfiles[id] = profile
            objectWillChange.send()
        }
        reconcileControlTarget()
        queueRefresh()
        updateRefreshTimer()
    }

    private func setProfileValue<Value>(
        _ key: WritableKeyPath<DisplayProfile, Value?>, to value: Value, for id: CGDirectDisplayID
    ) {
        var profile = displayProfile(for: id)
        profile[keyPath: key] = value
        setDisplayProfile(profile, for: id)
    }

    var controlBoostRegion: BoostRegion {
        selectedDisplayID.flatMap { displayProfile(for: $0).region } ?? preferences.region
    }

    func setControlBoostRegion(_ value: BoostRegion) {
        if let id = selectedDisplayID { setProfileValue(\.region, to: value, for: id) }
    }

    var controlDimming: Double {
        selectedDisplayID.flatMap { displayProfile(for: $0).dim } ?? preferences.dim
    }

    func setControlDimming(_ value: Double) {
        if let id = selectedDisplayID { setProfileValue(\.dim, to: value, for: id) }
    }

    var controlRingStrength: Double {
        selectedDisplayID.flatMap { displayProfile(for: $0).ringStrength } ?? preferences.ringStrength
    }

    func setControlRingStrength(_ value: Double) {
        if let id = selectedDisplayID { setProfileValue(\.ringStrength, to: value, for: id) }
    }

    private func savedBoost(for id: CGDirectDisplayID) -> Double {
        displayProfile(for: id).boost ?? preferences.boost
    }

    private func requestedBoost(for id: CGDirectDisplayID) -> Double {
        guard mode == .boost else { return 0 }
        return displayBoost.strength(
            for: id, saved: displayProfile(for: id).boost ?? lighting.keyboardBoost ?? preferences.boost
        )
    }

    var brightnessControl: BrightnessControl? {
        guard let display = controlledDisplay else { return nil }
        let level = nativeLevels[display.id]
        let hasNativeControl = level != nil && hardware.supportsBrightnessControl(on: display.id)
        let requested = requestedBoost(for: display.id)
        let terminalFailure = report?.displays[display.id]?.boostStatus.isTerminalFailure == true
        let pending = brightnessTransition.request.flatMap { $0.displayID == display.id ? $0.destination : nil }
        if hasNativeControl, let level {
            let controlMode: BrightnessControl.Mode = display.supportsHDR ? .combined : .native
            let atMaximum = BrightnessControl.isNativeMaximum(level)
            let nativeValue = atMaximum ? 1 : level
            let hasBoost = requested > 0 && !terminalFailure
            let value: Double
            switch pending {
            case .native: value = nativeValue
            case .boost(let strength): value = 1 + strength
            case nil: value = controlMode == .combined && hasBoost ? 1 + requested : nativeValue
            }
            let showsHDRRange = controlMode == .combined &&
                (atMaximum || hasBoost || value > 1 || renderer.isRestoringCurve(on: display.id))
            return BrightnessControl(mode: controlMode, value: value, canAdjust: !paused,
                                     nativeLevel: level, showsHDRRange: showsHDRRange)
        }
        if display.supportsHDR {
            let value = mode == .boost ? requested : savedBoost(for: display.id)
            return BrightnessControl(mode: .boost, value: value, canAdjust: !paused,
                                     nativeLevel: nil, showsHDRRange: false)
        }
        return nil
    }

    var brightnessControlStatus: String? {
        if let brightnessError { return brightnessError }
        if brightnessTransition.restoration != nil { return "Restoring display before changing brightness…" }
        guard let id = selectedDisplayID, let status = report?.displays[id]?.boostStatus,
              status.isTerminalFailure || status == .waitingForWindow else { return nil }
        return status.title
    }

    func setBrightnessControl(_ value: Double) {
        guard !paused, let display = controlledDisplay, let control = brightnessControl,
              let destination = BrightnessDestination(value: value, mode: control.mode) else { return }
        if control.mode == .combined, case .boost = destination, !control.showsHDRRange { return }
        brightnessError = nil
        if control.mode == .boost {
            guard case .boost(let strength) = destination else { return }
            setControlBoost(strength, on: display.id)
            return
        }
        brightnessTransition.submit(destination, for: display.id)
        if control.mode == .combined, !control.showsHDRRange, destination == .native(1) {
            // The current drag can use a synchronous readback before its next event.
            processBrightnessChange()
        } else {
            queueBrightnessChange()
        }
    }

    private func queueBrightnessChange() {
        guard !brightnessChangeQueued, brightnessTransition.restoration == nil else { return }
        brightnessChangeQueued = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            brightnessChangeQueued = false
            processBrightnessChange()
        }
    }

    private func processBrightnessChange(restored: Bool = false) {
        guard let request = brightnessTransition.request, brightnessTransition.restoration == nil else { return }
        guard !paused, let selected = controlledDisplay, selected.id == request.displayID,
              let display = ConnectedDisplay.current().first(where: {
                  $0.id == selected.id && $0.identity == selected.identity
              }) else {
            brightnessTransition.cancel()
            return
        }
        let id = display.id
        switch request.destination {
        case .boost(let strength):
            guard renderer.keyBoostState(displayID: id, screen: display.screen,
                                        region: controlBoostRegion, requested: false) != .unavailable else {
                finishBrightnessChange(error: "HDR is unavailable for this display and area")
                return
            }
            if !restored, renderer.isRestoringCurve(on: id) {
                awaitDisplayRestoration(on: id)
                return
            }
            guard hardware.brightness(of: id).map(BrightnessControl.isNativeMaximum) == true ||
                writeNativeBrightness(1, on: id) else {
                finishBrightnessChange(error: "Could not confirm 100% macOS brightness")
                return
            }
            takeManualControl()
            if mode != .boost {
                changeLighting { $0.activate(.boost) }
                displayBoost.singleDisplay = id
            } else if report?.displays[id]?.boostStatus.isTerminalFailure == true {
                renderer.restoreBrightness(on: id) { _ in }
            }
            setControlBoost(strength, on: id)
            finishBrightnessChange()
        case .native(let level):
            let lowering = level < (hardware.brightness(of: id) ?? 0)
            if display.builtIn, requestedBoost(for: id) > 0 || lowering {
                takeManualControl(suppressAuto: true)
            }
            if mode == .boost { displayBoost.levels[id] = 0 }
            if !restored {
                awaitDisplayRestoration(on: id)
                return
            }
            guard writeNativeBrightness(level, on: id) else {
                disableBoostWhenIdle()
                finishBrightnessChange(error: "Could not set macOS brightness")
                return
            }
            disableBoostWhenIdle()
            finishBrightnessChange()
        }
    }

    private func awaitDisplayRestoration(on id: CGDirectDisplayID) {
        let token = brightnessTransition.awaitRestoration()
        queueRefresh()
        renderer.restoreBrightness(on: id) { [weak self] outcome in
            guard let self, brightnessTransition.finishRestoration(token) != nil else { return }
            switch outcome {
            case .notNeeded, .restored:
                processBrightnessChange(restored: true)
            case .conflict:
                disableBoostWhenIdle()
                finishBrightnessChange(error: "Display curve changed by another app")
            case .failed:
                disableBoostWhenIdle()
                finishBrightnessChange(error: "Could not confirm display curve restoration")
            }
        }
    }

    private func disableBoostWhenIdle() {
        if mode == .boost, !selectedDisplays.contains(where: { requestedBoost(for: $0.id) > 0 }) {
            changeLighting { $0.setEnabled(false) }
        }
    }

    private func setControlBoost(_ strength: Double, on id: CGDirectDisplayID) {
        if mode == .boost, strength > 0 {
            takeManualControl()
            displayBoost.include(id, among: selectedDisplays.map(\.id))
        }
        setProfileValue(\.boost, to: strength, for: id)
        displayBoost.levels[id] = nil
        queueRefresh()
        updateRefreshTimer()
    }

    private func writeNativeBrightness(_ level: Double, on id: CGDirectDisplayID) -> Bool {
        guard hardware.supportsBrightnessControl(on: id),
              hardware.setBrightness(level, reference: id, followers: []).referenceSucceeded,
              let actual = hardware.brightness(of: id) else { return false }
        nativeLevels[id] = actual
        return level < 1 || BrightnessControl.isNativeMaximum(actual)
    }

    private func finishBrightnessChange(error: String? = nil) {
        brightnessTransition.cancel()
        brightnessError = error
        queueRefresh()
        updateRefreshTimer()
    }

    var diagnosticRows: [DisplayDiagnosticRow] {
        let participating = Set(selectedDisplays.map(\.id))
        return displays.map { display in
            let result = paused ? nil : report?.displays[display.id]
            let status: String
            if paused {
                status = "Display inactive"
            } else if renderer.isRestoringCurve(on: display.id) {
                status = "Restoring display…"
            } else if let result, result.boostStatus != .off {
                status = result.boostStatus.title
            } else if !participating.contains(display.id) {
                status = "Excluded from effects"
            } else if result?.hasActiveEffect == true {
                status = mode.title
            } else {
                status = "Standard display brightness"
            }
            return DisplayDiagnosticRow(
                id: display.id, name: display.screen.localizedName, nativeBrightness: nativeLevels[display.id],
                requestedBoost: participating.contains(display.id) ? result?.requestedBoost ?? 0 : 0,
                appliedGain: result?.appliedGain,
                currentHeadroom: result?.currentHeadroom ?? Double(display.screen.maximumExtendedDynamicRangeColorComponentValue),
                potentialHeadroom: result?.potentialHeadroom ?? Double(display.screen.maximumPotentialExtendedDynamicRangeColorComponentValue),
                path: result?.boostPath == .gamma ? "RGB transfer curve" :
                    (result?.boostPath == .overlay ? "Metal overlay" : nil),
                status: status
            )
        }
    }

    func copyDiagnostics() {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development build"
        let system = ProcessInfo.processInfo.operatingSystemVersion
        var lines = [
            "Luma Luma \(version)",
            "macOS \(system.majorVersion).\(system.minorVersion).\(system.patchVersion)",
            ambientStatus
        ]
        for (index, row) in diagnosticRows.enumerated() {
            let builtIn = displays.first(where: { $0.id == row.id })?.builtIn == true
            lines.append("")
            lines.append("Display \(index + 1) (\(builtIn ? "built-in" : "external"))")
            lines.append(row.status)
            let fields: [(String, Double?)] = [
                ("macOS brightness", row.nativeBrightness), ("Requested boost", row.requestedBoost),
                ("Applied factor", row.appliedGain), ("Current HDR headroom", row.currentHeadroom),
                ("Potential HDR headroom", row.potentialHeadroom)
            ]
            for (label, value) in fields {
                lines.append("\(label): \(value.map { String(format: "%.3f", $0) } ?? "Unavailable")")
            }
            if let path = row.path { lines.append("Render path: \(path)") }
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
    }

    func toggle() {
        setEnabled(!isEnabled)
    }

    private func resetRendering() {
        renderer.clear()
        report = nil
    }

    func setLoginEnabled(_ enabled: Bool) {
        do {
            if enabled {
                if SMAppService.mainApp.status != .requiresApproval {
                    try SMAppService.mainApp.register()
                }
            } else {
                try SMAppService.mainApp.unregister()
            }
            loginMessage = SMAppService.mainApp.status == .requiresApproval
                ? "Approve Luma Luma in System Settings → Login Items." : nil
        } catch {
            loginMessage = error.localizedDescription
        }
        updateLoginStatus()
    }

    @objc func showPreferences() {
        popover?.performClose(nil)
        if preferencesWindow == nil {
            preferencesWindow = makeWindow(title: "Luma Luma Settings", style: [.titled, .closable, .miniaturizable]) {
                PreferencesHost(controller: self)
            }
        }
        updateLoginStatus()
        NSApplication.shared.activate(ignoringOtherApps: true)
        preferencesWindow?.makeKeyAndOrderFront(nil)
        queueRefresh()
        updateRefreshTimer()
    }

    func showDiagnostics() {
        settingsTab = .diagnostics
        showPreferences()
    }

    @objc func showControls() {
        popover?.performClose(nil)
        if controlsWindow == nil {
            controlsWindow = makeWindow(title: "Luma Luma", style: [.titled, .closable]) {
                StatusView(controller: self, preferences: preferences)
            }
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
        controlsWindow?.makeKeyAndOrderFront(nil)
        queueRefresh()
        updateRefreshTimer()
    }

    private func makeWindow<Content: View>(
        title: String,
        style: NSWindow.StyleMask,
        content: () -> Content
    ) -> NSWindow {
        let window = NSWindow(contentViewController: NSHostingController(rootView: content()))
        window.title = title
        window.styleMask = style
        window.level = .statusBar
        window.isReleasedWhenClosed = false
        window.center()
        return window
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        let controls = NSMenuItem(title: "Show Controls", action: #selector(showControls), keyEquivalent: "")
        controls.target = self
        menu.addItem(controls)
        let item = NSMenuItem(title: "Settings…", action: #selector(showPreferences), keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return menu
    }

    @objc func quit() {
        NSApplication.shared.terminate(nil)
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem = item
        item.button?.target = self
        item.button?.action = #selector(statusPressed)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        updateStatusItem()
    }

    private func updateStatusItem() {
        let button = statusItem?.button
        button?.image = MenuBarIcon.image(active: hasActiveEffect)
        button?.toolTip = "Luma Luma · \(mode.title)"
        button?.setAccessibilityLabel("Luma Luma")
        button?.setAccessibilityValue(paused ? "Paused" : mode.title)
    }

    @objc private func statusPressed() {
        if NSApplication.shared.currentEvent?.type == .rightMouseUp {
            popover?.performClose(nil)
            toggle()
        } else {
            showMenu()
        }
    }

    private func showMenu() {
        guard let button = statusItem?.button else { return }
        if popover?.isShown == true {
            popover?.performClose(nil)
            return
        }
        if popover == nil {
            let popup = NSPopover()
            popup.behavior = .transient
            popup.contentViewController = NSHostingController(rootView: StatusView(
                controller: self, preferences: preferences
            ))
            popover = popup
        }
        popover?.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover?.contentViewController?.view.window?.level = .statusBar
        queueRefresh()
        updateRefreshTimer()
    }

    private func installApplicationMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let menu = NSMenu(title: "Luma Luma")
        let controls = NSMenuItem(title: "Show Controls", action: #selector(showControls), keyEquivalent: "0")
        let settings = NSMenuItem(title: "Settings…", action: #selector(showPreferences), keyEquivalent: ",")
        let quit = NSMenuItem(title: "Quit Luma Luma", action: #selector(quit), keyEquivalent: "q")
        controls.target = self
        settings.target = self
        quit.target = self
        menu.addItem(controls)
        menu.addItem(settings)
        menu.addItem(.separator())
        menu.addItem(quit)
        appItem.submenu = menu
        main.addItem(appItem)
        NSApplication.shared.mainMenu = main
    }

    private func updateLoginStatus() {
        let enabled = SMAppService.mainApp.status == .enabled || SMAppService.mainApp.status == .requiresApproval
        if enabled != loginEnabled { loginEnabled = enabled }
    }

    private func updatePreferences(initial: Bool = false) {
        guard ready else { return }
        reconcileControlTarget()
        if previousDefaultBoost != preferences.boost {
            previousDefaultBoost = preferences.boost
            changeLighting { $0.useManualBoost() }
        }
        let policy: NSApplication.ActivationPolicy = preferences.showDockIcon ? .regular : .accessory
        if NSApplication.shared.activationPolicy() != policy {
            NSApplication.shared.setActivationPolicy(policy)
        }
        var error = shortcuts.update(bindings: preferences.shortcuts)
        let needsNativeKeys = preferences.nativeBrightnessKeys || preferences.syncHardwareBrightness
        if !shortcuts.setBrightnessKeysEnabled(needsNativeKeys), needsNativeKeys {
            let missing = "Allow Luma Luma in Privacy & Security → Accessibility, then turn the option off and back on."
            error = [error, missing].compactMap { $0 }.joined(separator: " ")
        }
        if error != shortcutError { shortcutError = error }
        if !preferences.showBrightnessIndicator { brightnessIndicator?.hide() }
        let ambientChanged = previousAmbientEnabled != preferences.ambientBoostEnabled
        let ruleChanged = previousRule != preferences.powerRule || previousThreshold != preferences.batteryThreshold
        previousRule = preferences.powerRule
        previousThreshold = preferences.batteryThreshold
        previousAmbientEnabled = preferences.ambientBoostEnabled
        if ambientChanged {
            ambientPolicy = AmbientBoostPolicy()
            ambientFailure = nil
            if preferences.ambientBoostEnabled, powerOwnsBoost {
                powerOwnsBoost = false
                changeLighting { $0.setEnabled(false) }
            } else if !preferences.ambientBoostEnabled {
                stopAmbientBoost()
                setAmbientStatus("Automatic boost is off")
            }
        }
        if ambientChanged || ruleChanged {
            automationResult = nil
            refreshAutomation()
        }
        if initial, !preferences.ambientBoostEnabled, preferences.powerRule == .manual,
           preferences.startEnabled, mode == .off {
            select(.boost)
        }
        queueRefresh()
        updateRefreshTimer()
    }

    private func updateRefreshTimer() {
        updateAutomationTimers()
        let interval: TimeInterval
        if paused {
            tick?.invalidate()
            tick = nil
            return
        }
        if mode == .boost, selectedDisplays.contains(where: { requestedBoost(for: $0.id) > 0 }) {
            interval = 0.25
        } else if controlsAreVisible {
            interval = 0.5
        } else {
            tick?.invalidate()
            tick = nil
            return
        }
        guard tick?.timeInterval != interval else { return }
        tick?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.refreshDisplays()
                self.updateRefreshTimer()
            }
        }
        timer.tolerance = interval * 0.1
        RunLoop.main.add(timer, forMode: .common)
        tick = timer
    }

    private var controlsAreVisible: Bool {
        popover?.isShown == true || controlsWindow?.isVisible == true || preferencesWindow?.isVisible == true
    }

    private func updateAutomationTimers() {
        updateAmbientTimer()
        guard !paused, powerSource == nil, preferences.powerRule != .manual,
              !preferences.ambientBoostEnabled else {
            powerTimer?.invalidate()
            powerTimer = nil
            return
        }
        guard powerTimer == nil else { return }
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshAutomation() }
        }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        powerTimer = timer
    }

    private func updateAmbientTimer() {
        guard preferences.ambientBoostEnabled, !paused, displays.contains(where: \.builtIn) else {
            ambientTimer?.invalidate()
            ambientTimer = nil
            return
        }
        guard ambientTimer == nil else { return }
        let timer = Timer(timeInterval: AmbientBoostPolicy.pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshAmbientBoost() }
        }
        timer.tolerance = 0.15
        RunLoop.main.add(timer, forMode: .common)
        ambientTimer = timer
    }

    private func powerAllowsBoost() -> Bool? {
        guard preferences.powerRule != .manual else { return true }
        guard let power = PowerSnapshot.read() else { return nil }
        return power.isOnAC || (preferences.powerRule == .batteryThreshold &&
            (power.batteryPercentage ?? -1) >= preferences.batteryThreshold)
    }

    private func refreshAutomation() {
        guard !paused else { return }
        if preferences.ambientBoostEnabled {
            refreshAmbientBoost()
            return
        }
        guard preferences.powerRule != .manual, let shouldEnable = powerAllowsBoost() else { return }
        guard automationResult != shouldEnable else { return }
        automationResult = shouldEnable
        if mode == .off, shouldEnable {
            changeLighting { $0.activate(.boost) }
            powerOwnsBoost = true
        } else if mode == .boost, !shouldEnable {
            powerOwnsBoost = false
            changeLighting { $0.setEnabled(false) }
        }
    }

    private func refreshAmbientBoost() {
        guard preferences.ambientBoostEnabled, !paused else { return }
        let target = selectedDisplays.first { $0.builtIn && $0.supportsHDR && CGDisplayIsActive($0.id) != 0 }
        let lux = target == nil ? nil : AmbientLightSensor.readLux()
        let nativeBrightness = target.flatMap { hardware.brightness(of: $0.id) }
        let atMaximum = nativeBrightness.map { $0 >= 0.999 } == true
        let powerAllowed = powerAllowsBoost() == true
        let hasConfiguredBoost = target.map { savedBoost(for: $0.id) > 0 } == true
        if let owned = ambientDisplayID, owned != target?.id {
            stopAmbientBoost()
            ambientPolicy.pause()
        }
        let canTakeControl = ambientDisplayID != nil || (mode == .off && brightnessTransition.request == nil)
        let eligible = target != nil && powerAllowed && hasConfiguredBoost && canTakeControl
        let wantsBoost = ambientPolicy.update(
            lux: lux, eligible: eligible, nativeBrightness: nativeBrightness,
            sensitivity: preferences.ambientSensitivity
        )

        if ambientDisplayID != nil, !wantsBoost {
            stopAmbientBoost()
        }
        if !ambientPolicy.isSuppressed { ambientFailure = nil }
        if wantsBoost, mode == .off, let target {
            changeLighting { $0.activate(.boost) }
            ambientDisplayID = target.id
            displayBoost.singleDisplay = target.id
            queueRefresh()
            updateRefreshTimer()
        }

        let status: String
        if let ambientFailure {
            status = ambientFailure
        } else if target == nil {
            status = "Select an active built-in HDR display"
        } else if lux == nil {
            status = "Ambient light reading unavailable"
        } else if ambientPolicy.isSuppressed {
            status = "Paused until the surroundings darken"
        } else if ambientDisplayID != nil {
            status = "Automatic boost requested"
        } else if !canTakeControl {
            status = "Manual effect is active"
        } else if !powerAllowed {
            status = "Waiting for the power rule"
        } else if !atMaximum {
            status = "Waiting for 100% macOS brightness"
        } else if !hasConfiguredBoost {
            status = "Set a boost strength above zero"
        } else {
            status = "Monitoring ambient light"
        }
        setAmbientStatus(status)
    }

    private func stopAmbientBoost() {
        guard ambientDisplayID != nil else { return }
        ambientDisplayID = nil
        changeLighting { $0.setEnabled(false) }
    }

    private func setAmbientStatus(_ status: String) {
        if ambientStatus != status { ambientStatus = status }
    }

    private func refreshDisplays() {
        guard ready, !paused else { return }
        if controlsAreVisible {
            let levels = Dictionary(uniqueKeysWithValues: displays.compactMap { display in
                hardware.brightness(of: display.id).map { (display.id, $0) }
            })
            if levels != nativeLevels { nativeLevels = levels }
        }
        let targets = selectedDisplays.map { display in
            let profile = displayProfile(for: display.id)
            return DisplayRenderTarget(
                id: display.id, screen: display.screen, boost: requestedBoost(for: display.id),
                dim: mode == .eclipse ? profile.dim ?? preferences.dim : 0,
                region: profile.region ?? preferences.region,
                ring: mode == .ring ? profile.ringStrength ?? preferences.ringStrength : 0,
                ringWidth: profile.ringWidth ?? preferences.ringWidth,
                ringWarmth: profile.ringWarmth ?? preferences.ringWarmth
            )
        }
        let rendered = renderer.apply(targets)
        if let id = ambientDisplayID, let result = rendered.displays[id], result.boostStatus.isTerminalFailure {
            ambientFailure = result.boostStatus.title
            ambientPolicy.suppressUntilDark()
            stopAmbientBoost()
            setAmbientStatus(ambientFailure ?? "Automatic boost unavailable")
            return
        }
        if rendered != report {
            report = rendered
            log.info("Mode \(self.mode.rawValue, privacy: .public); selected displays \(rendered.displayCount); rendered boost \(rendered.activeBoostDisplayCount) / \(rendered.targetBoostDisplayCount); headroom \(rendered.currentHeadroom, format: .fixed(precision: 2)) / \(rendered.potentialHeadroom, format: .fixed(precision: 2))")
        }
        updateStatusItem()
    }

    private func queueRefresh() {
        guard ready, !renderingQueued else { return }
        renderingQueued = true
        Task { @MainActor in
            renderingQueued = false
            refreshDisplays()
        }
    }

    private func perform(_ action: ShortcutAction) {
        switch action {
        case .toggle: toggle()
        case .increase, .decrease:
            guard !paused, let display = controlledDisplay else { return }
            changeLevel(by: action == .increase ? 0.0625 : -0.0625, on: display)
        }
    }

    private func changeLevel(by amount: Double, on display: ConnectedDisplay) {
        let value: Double
        takeManualControl()
        switch mode {
        case .off:
            guard amount > 0 else { return }
            select(.boost)
            value = savedBoost(for: display.id)
        case .boost:
            value = min(1, max(0, requestedBoost(for: display.id) + amount))
            setControlBoost(value, on: display.id)
        case .eclipse:
            let dim = min(0.95, max(0, (displayProfile(for: display.id).dim ?? preferences.dim) - amount))
            setProfileValue(\.dim, to: dim, for: display.id)
            value = 1 - dim
        case .ring:
            value = min(1, max(0, (displayProfile(for: display.id).ringStrength ?? preferences.ringStrength) + amount))
            setProfileValue(\.ringStrength, to: value, for: display.id)
        }
        queueRefresh()
        updateRefreshTimer()
        showBrightness(value, on: display.screen)
    }

    private func showBrightness(_ value: Double, percentage: Int? = nil, on screen: NSScreen) {
        if preferences.showBrightnessIndicator {
            let indicator = brightnessIndicator ?? BrightnessIndicator()
            brightnessIndicator = indicator
            let indicatingBoost = percentage != nil
            indicator.show(
                label: indicatingBoost ? LightingMode.boost.title : mode.title,
                symbol: indicatingBoost ? LightingMode.boost.symbol : mode.symbol,
                value: value, percentage: percentage, on: screen
            )
        }
    }

    private func handleBrightnessKey(increase: Bool, fine: Bool) -> Bool {
        guard !paused else { return false }
        let step = BrightnessKeyRouting.step(fine: fine)
        let change = increase ? step : -step
        let selected = selectedDisplays
        guard let reference = selected.first(where: \.builtIn) ?? selected.first else {
            return false
        }
        let level = hardware.brightness(of: reference.id)
        let screen = reference.screen
        if preferences.nativeBrightnessKeys {
            switch mode {
            case .off, .boost:
                let strength = requestedBoost(for: reference.id)
                let state = renderer.keyBoostState(
                    displayID: reference.id, screen: screen, region: displayProfile(for: reference.id).region ?? preferences.region,
                    requested: strength > 0
                )
                let decision = BrightnessKeyRouting.decide(
                    increase: increase, fine: fine, hardwareLevel: level, strength: strength,
                    boostState: state, restoring: renderer.isRestoringCurve(on: reference.id)
                )
                switch decision {
                case .waitForRestoration:
                    return true
                case .setBoost(let value):
                    applyKeyboardBoost(value, on: reference)
                    return true
                case .system:
                    break
                }
            case .eclipse where (displayProfile(for: reference.id).dim ?? preferences.dim) > 0 ||
                (!increase && (level ?? 1) <= 0.001):
                changeLevel(by: change, on: reference)
                return true
            case .ring:
                changeLevel(by: change, on: reference)
                return true
            default: break
            }
        }
        if brightnessTransition.request?.displayID == reference.id {
            brightnessTransition.cancel()
        }
        guard preferences.syncHardwareBrightness, let level else { return false }
        guard !renderer.isRestoringCurve(on: reference.id) else { return false }
        let followers = selected.map(\.id).filter {
            $0 != reference.id && !renderer.isRestoringCurve(on: $0) && hardware.brightness(of: $0) != nil
        }
        guard !followers.isEmpty else { return false }
        let result = hardware.setBrightness(level + change, reference: reference.id, followers: followers)
        if !result.failedFollowers.isEmpty {
            log.info("Brightness sync updated the reference; \(result.failedFollowers.count) other displays did not update")
        }
        return result.referenceSucceeded
    }

    private func applyKeyboardBoost(_ value: Double, on display: ConnectedDisplay) {
        takeManualControl(suppressAuto: value == 0)
        brightnessTransition.cancel()
        let groupControl = displayBoost.singleDisplay == nil && displayBoost.levels.isEmpty &&
            selectedDisplays.allSatisfy { displayProfile(for: $0.id).boost == nil }
        if groupControl {
            if value == 0 {
                changeLighting { $0.setEnabled(false) }
            } else {
                changeLighting { $0.activate(.boost, keyboardBoost: value) }
            }
        } else if value == 0 {
            displayBoost.levels[display.id] = 0
            if !selectedDisplays.contains(where: { requestedBoost(for: $0.id) > 0 }) {
                changeLighting { $0.setEnabled(false) }
            } else {
                renderer.restoreBrightness(on: display.id) { _ in }
            }
        } else {
            if mode != .boost {
                changeLighting { $0.activate(.boost) }
            }
            displayBoost.include(display.id, among: selectedDisplays.map(\.id))
            displayBoost.levels[display.id] = value
        }
        queueRefresh()
        updateRefreshTimer()
        let builtInFull = display.builtIn && (displayProfile(for: display.id).region ?? preferences.region) == .full
        let percentage = builtInFull ? Int(((1 + 0.45 * value) * 100).rounded()) : nil
        showBrightness(value, percentage: percentage, on: display.screen)
    }

    private func installNotifications() {
        let local = NotificationCenter.default
        local.addObserver(self, selector: #selector(displaysChanged),
                          name: NSApplication.didChangeScreenParametersNotification, object: nil)
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(self, selector: #selector(willSleep),
                              name: NSWorkspace.willSleepNotification, object: nil)
        workspace.addObserver(self, selector: #selector(didWake),
                              name: NSWorkspace.didWakeNotification, object: nil)
        workspace.addObserver(self, selector: #selector(screensDidSleep),
                              name: NSWorkspace.screensDidSleepNotification, object: nil)
        workspace.addObserver(self, selector: #selector(screensDidWake),
                              name: NSWorkspace.screensDidWakeNotification, object: nil)
        workspace.addObserver(self, selector: #selector(sessionResigned),
                              name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        workspace.addObserver(self, selector: #selector(sessionActivated),
                              name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        let distributed = DistributedNotificationCenter.default()
        distributed.addObserver(self, selector: #selector(screenLocked),
                                name: Notification.Name("com.apple.screenIsLocked"), object: nil)
        distributed.addObserver(self, selector: #selector(screenUnlocked),
                                name: Notification.Name("com.apple.screenIsUnlocked"), object: nil)
    }

    @objc private func displaysChanged() {
        brightnessTransition.cancel()
        brightnessError = nil
        updateDisplayInventory()
        refreshAutomation()
        queueRefresh()
        updateRefreshTimer()
    }
    @objc private func willSleep() { systemSleeping = true; updatePause() }
    @objc private func didWake() { systemSleeping = false; updatePause() }
    @objc private func screensDidSleep() { screensSleeping = true; updatePause() }
    @objc private func screensDidWake() { screensSleeping = false; updatePause() }
    @objc private func screenLocked() { locked = true; updatePause() }
    @objc private func screenUnlocked() { locked = false; updatePause() }
    @objc private func sessionResigned() { sessionInactive = true; updatePause() }
    @objc private func sessionActivated() { sessionInactive = false; updatePause() }

    private func updatePause() {
        let shouldPause = systemSleeping || screensSleeping || locked || sessionInactive
        guard paused != shouldPause else { return }
        paused = shouldPause
        if paused {
            brightnessTransition.cancel()
            brightnessError = nil
            ambientPolicy.pause()
            stopAmbientBoost()
            if preferences.ambientBoostEnabled { setAmbientStatus("Paused while the display is inactive") }
            renderer.clear(waitForGammaRestoration: true)
            report = nil
            brightnessIndicator?.hide()
            updateStatusItem()
        } else {
            updateDisplayInventory()
            refreshAutomation()
            queueRefresh()
        }
        updateRefreshTimer()
    }
}

private extension DisplayBoostStatus {
    var isTerminalFailure: Bool {
        switch self {
        case .unsupported, .unavailable, .conflict, .failed, .restorationFailed: true
        default: false
        }
    }

    var title: String {
        switch self {
        case .off: "Standard display brightness"
        case .preparing: "Preparing HDR…"
        case .active: "HDR boost active"
        case .restoring: "Restoring display…"
        case .unsupported: "HDR is unavailable on this display"
        case .waitingForWindow: "Waiting for a frontmost window"
        case .unavailable: "HDR did not become available"
        case .conflict: "Display curve changed by another app"
        case .failed: "Could not apply HDR boost"
        case .restorationFailed: "Could not confirm display curve restoration"
        }
    }
}

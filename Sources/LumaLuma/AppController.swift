import AppKit
import Combine
import IOKit.ps
import ServiceManagement
import SwiftUI
import os

enum LightingMode: String, CaseIterable {
    case off, boost, eclipse, ring

    var title: String {
        switch self {
        case .off: "Off"
        case .boost: "Boost"
        case .eclipse: "Eclipse"
        case .ring: "Ring Light"
        }
    }

    var symbol: String {
        switch self {
        case .off: "sun.max"
        case .boost: "sun.max.fill"
        case .eclipse: "moon.fill"
        case .ring: "circle.circle"
        }
    }
}

@MainActor
final class AppController: NSObject, NSApplicationDelegate, ObservableObject {
    let preferences = Preferences()
    @Published private(set) var mode: LightingMode = .off
    @Published private(set) var report: DisplayRenderReport?
    @Published private(set) var loginEnabled = false
    @Published private(set) var shortcutError: String?
    @Published private(set) var loginMessage: String?
    @Published private(set) var paused = false

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
    private var powerSource: CFRunLoopSource?
    private var renderingQueued = false
    private var automationResult: Bool?
    private var previousRule: PowerRule?
    private var previousThreshold: Int?
    private var lastMode: LightingMode = .boost
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
        guard next != mode else { return }
        if next != .off { lastMode = next }
        mode = next
        log.info("Selected mode \(next.rawValue, privacy: .public)")
        updateStatusItem()
        queueRefresh()
        updateRefreshTimer()
    }

    func toggle() {
        select(mode == .off ? lastMode : .off)
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
        let symbol = NSImage(systemSymbolName: mode.symbol, accessibilityDescription: "Luma Luma")
        symbol?.isTemplate = true
        statusItem?.button?.image = symbol
        statusItem?.button?.toolTip = "Luma Luma · \(mode.title)"
        statusItem?.button?.setAccessibilityLabel("Luma Luma")
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
        let ruleChanged = previousRule != preferences.powerRule || previousThreshold != preferences.batteryThreshold
        previousRule = preferences.powerRule
        previousThreshold = preferences.batteryThreshold
        if ruleChanged {
            automationResult = nil
            refreshAutomation()
        }
        if initial, preferences.powerRule == .manual, preferences.startEnabled, mode == .off {
            select(.boost)
        }
        queueRefresh()
        updateRefreshTimer()
    }

    private func updateRefreshTimer() {
        let refreshBoost = mode == .boost && preferences.boost > 0 &&
            (preferences.region == .frontWindow || (preferences.region == .full && preferences.scope != .external))
        let pollPower = powerSource == nil && preferences.powerRule != .manual
        guard !paused, refreshBoost || pollPower else {
            tick?.invalidate()
            tick = nil
            return
        }
        let interval = refreshBoost ? 0.25 : 5.0
        guard tick?.timeInterval != interval else { return }
        tick?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                if pollPower { self?.refreshAutomation() }
                if refreshBoost { self?.refreshDisplays() }
            }
        }
        timer.tolerance = interval * 0.1
        RunLoop.main.add(timer, forMode: .common)
        tick = timer
    }

    private func refreshAutomation() {
        guard preferences.powerRule != .manual, !paused, let power = PowerSnapshot.read() else { return }
        let shouldEnable = power.isOnAC || (
            preferences.powerRule == .batteryThreshold
                && (power.batteryPercentage ?? -1) >= preferences.batteryThreshold
        )
        guard automationResult != shouldEnable else { return }
        automationResult = shouldEnable
        if mode == .off, shouldEnable { select(.boost) }
        if mode == .boost, !shouldEnable { select(.off) }
    }

    private func refreshDisplays() {
        guard ready, !paused else { return }
        let rendered = renderer.apply(DisplayRenderSettings(
            boost: mode == .boost ? preferences.boost : 0,
            dim: mode == .eclipse ? preferences.dim : 0,
            scope: preferences.scope,
            region: preferences.region,
            ring: mode == .ring ? preferences.ringStrength : 0,
            ringWidth: preferences.ringWidth,
            ringWarmth: preferences.ringWarmth
        ))
        if rendered != report {
            report = rendered
            log.info("Mode \(self.mode.rawValue, privacy: .public); selected displays \(rendered.displayCount); rendered boost \(rendered.activeBoostDisplayCount) / \(rendered.targetBoostDisplayCount); headroom \(rendered.currentHeadroom, format: .fixed(precision: 2)) / \(rendered.potentialHeadroom, format: .fixed(precision: 2))")
        }
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
            guard !paused,
                  let screen = NSScreen.screens(in: preferences.scope).first?.screen
            else { return }
            changeLevel(by: action == .increase ? 0.0625 : -0.0625, on: screen)
        }
    }

    private func changeLevel(by amount: Double, on screen: NSScreen) {
        let value: Double
        switch mode {
        case .off:
            guard amount > 0 else { return }
            select(.boost)
            value = preferences.boost
        case .boost:
            value = min(1, max(0, preferences.boost + amount))
            if value != preferences.boost { preferences.boost = value }
        case .eclipse:
            let dim = min(0.95, max(0, preferences.dim - amount))
            if dim != preferences.dim { preferences.dim = dim }
            value = 1 - dim
        case .ring:
            value = min(1, max(0, preferences.ringStrength + amount))
            if value != preferences.ringStrength { preferences.ringStrength = value }
        }
        if preferences.showBrightnessIndicator {
            let indicator = brightnessIndicator ?? BrightnessIndicator()
            brightnessIndicator = indicator
            indicator.show(label: mode.title, symbol: mode.symbol, value: value, on: screen)
        }
    }

    private func handleBrightnessKey(increase: Bool, fine: Bool) -> Bool {
        guard !paused else { return false }
        let step = fine ? 1.0 / 64 : 1.0 / 16
        let change = increase ? step : -step
        let selected = NSScreen.screens(in: preferences.scope)
        guard let screen = selected.first?.screen else { return false }
        let controllable = selected.compactMap { display in
            hardware.brightness(of: display.id).map { (display.id, $0) }
        }
        let level = controllable.first?.1
        if preferences.nativeBrightnessKeys {
            switch mode {
            case .boost where (report?.edrDisplayCount ?? 0) > 0
                && (preferences.region != .frontWindow || (report?.targetBoostDisplayCount ?? 0) > 0):
                guard increase ? (level ?? 0) >= 0.999 : preferences.boost > 0 else { break }
                changeLevel(by: change, on: screen)
                return true
            case .eclipse where preferences.dim > 0 || (!increase && (level ?? 1) <= 0.001):
                changeLevel(by: change, on: screen)
                return true
            case .ring:
                changeLevel(by: change, on: screen)
                return true
            default: break
            }
        }
        guard preferences.syncHardwareBrightness, let level, controllable.count > 1 else { return false }
        return hardware.setBrightness(level + change, displays: controllable.map(\.0))
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

    @objc private func displaysChanged() { queueRefresh() }
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
        updateRefreshTimer()
        if paused {
            renderer.clear(waitForGammaRestoration: true)
            brightnessIndicator?.hide()
        } else {
            refreshAutomation()
            queueRefresh()
        }
    }
}

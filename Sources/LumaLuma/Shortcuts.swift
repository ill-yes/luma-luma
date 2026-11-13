import AppKit
import Carbon
import CoreGraphics
import IOKit.hidsystem
import SwiftUI

enum ShortcutAction: String, CaseIterable, Codable, Hashable {
    case toggle
    case increase
    case decrease

    var title: String {
        switch self {
        case .toggle: "Toggle"
        case .increase: "Increase brightness"
        case .decrease: "Decrease brightness"
        }
    }
}

struct KeyBinding: Codable, Hashable {
    let keyCode: UInt32
    let modifiers: UInt32
    let displayName: String
}

@MainActor
final class ShortcutController {
    private static let signature: OSType = 0x4C4C4748

    private struct Registration {
        let binding: KeyBinding
        let id: UInt32
        let reference: EventHotKeyRef
    }

    private let onAction: (ShortcutAction) -> Void
    private let onBrightnessKey: (Bool, Bool) -> Bool
    private var registrations: [ShortcutAction: Registration] = [:]
    private var pressedToggleID: UInt32?
    private var handler: EventHandlerRef?
    private var nextID: UInt32 = 1
    private var brightnessTap: CFMachPort?
    private var brightnessSource: CFRunLoopSource?
    private var consumedBrightnessKeys: Set<Int32> = []

    init(
        onAction: @escaping (ShortcutAction) -> Void,
        onBrightnessKey: @escaping (_ increase: Bool, _ fine: Bool) -> Bool
    ) {
        self.onAction = onAction
        self.onBrightnessKey = onBrightnessKey
    }

    func update(bindings: [ShortcutAction: KeyBinding]) -> String? {
        for action in ShortcutAction.allCases where registrations[action]?.binding != bindings[action] {
            if let registration = registrations.removeValue(forKey: action) {
                UnregisterEventHotKey(registration.reference)
                if pressedToggleID == registration.id { pressedToggleID = nil }
            }
        }

        guard !bindings.isEmpty else { return nil }
        guard installHandlerIfNeeded() else { return "Global shortcuts are unavailable." }

        var errors: [String] = []
        for action in ShortcutAction.allCases {
            guard registrations[action] == nil, let binding = bindings[action] else { continue }
            let duplicate = registrations.values.contains {
                $0.binding.keyCode == binding.keyCode && $0.binding.modifiers == binding.modifiers
            }
            if duplicate {
                errors.append("\(binding.displayName) is already assigned in Luma Luma.")
                continue
            }

            var reference: EventHotKeyRef?
            let id = nextID
            nextID &+= 1
            let status = RegisterEventHotKey(
                binding.keyCode, binding.modifiers, EventHotKeyID(signature: Self.signature, id: id),
                GetApplicationEventTarget(), UInt32(kEventHotKeyExclusive), &reference
            )
            if status == noErr, let reference {
                registrations[action] = Registration(binding: binding, id: id, reference: reference)
            } else {
                errors.append("Couldn’t register \(binding.displayName) for \(action.title.lowercased()).")
            }
        }
        return errors.isEmpty ? nil : errors.joined(separator: " ")
    }

    func setBrightnessKeysEnabled(_ enabled: Bool) -> Bool {
        guard enabled else {
            removeBrightnessTap()
            return true
        }
        guard AXIsProcessTrusted() else {
            removeBrightnessTap()
            return false
        }
        if let brightnessTap, CGEvent.tapIsEnabled(tap: brightnessTap) {
            return true
        }
        removeBrightnessTap()

        let mask = CGEventMask(1) << NSEvent.EventType.systemDefined.rawValue
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, context in
                let forwarded = Unmanaged.passUnretained(event)
                guard let context else { return forwarded }
                let controller = Unmanaged<ShortcutController>.fromOpaque(context).takeUnretainedValue()
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    let timedOut = type == .tapDisabledByTimeout
                    MainActor.assumeIsolated { controller.tapDisabled(timedOut: timedOut) }
                    return forwarded
                }
                guard type.rawValue == NSEvent.EventType.systemDefined.rawValue,
                      let systemEvent = NSEvent(cgEvent: event),
                      systemEvent.subtype.rawValue == NX_SUBTYPE_AUX_CONTROL_BUTTONS
                else { return forwarded }

                let data = UInt32(truncatingIfNeeded: systemEvent.data1)
                let key = Int32(data >> 16)
                guard key == NX_KEYTYPE_BRIGHTNESS_UP || key == NX_KEYTYPE_BRIGHTNESS_DOWN
                else { return forwarded }

                let state = (data >> 8) & 0xFF
                let repeatPress = data & 1 != 0
                let modifiers = systemEvent.modifierFlags.intersection([.command, .control, .option, .shift])
                let shouldConsume = MainActor.assumeIsolated {
                    controller.handleBrightnessKey(
                        key, state: state, repeatPress: repeatPress, modifiers: modifiers
                    )
                }
                return shouldConsume ? nil : forwarded
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ), let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else { return false }

        brightnessTap = tap
        brightnessSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    func stop() {
        _ = update(bindings: [:])
        if let handler {
            RemoveEventHandler(handler)
            self.handler = nil
        }
        removeBrightnessTap()
    }

    private func installHandlerIfNeeded() -> Bool {
        guard handler == nil else { return true }
        let events = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, context in
                guard let event, let context else { return OSStatus(eventNotHandledErr) }
                var identifier = EventHotKeyID()
                let status = GetEventParameter(
                    event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                    nil, MemoryLayout<EventHotKeyID>.size, nil, &identifier
                )
                guard status == noErr else { return status }
                let controller = Unmanaged<ShortcutController>.fromOpaque(context).takeUnretainedValue()
                let eventSignature = identifier.signature
                let eventID = identifier.id
                let pressed = GetEventKind(event) == UInt32(kEventHotKeyPressed)
                return MainActor.assumeIsolated {
                    controller.handleHotKey(signature: eventSignature, id: eventID, pressed: pressed)
                }
            },
            events.count, events, Unmanaged.passUnretained(self).toOpaque(), &handler
        )
        return status == noErr
    }

    private func handleHotKey(signature: OSType, id: UInt32, pressed: Bool) -> OSStatus {
        guard signature == Self.signature,
              let (action, registration) = registrations.first(where: { $0.value.id == id })
        else { return OSStatus(eventNotHandledErr) }
        if action == .toggle {
            guard pressed else {
                if pressedToggleID == id { pressedToggleID = nil }
                return noErr
            }
            guard pressedToggleID != id else { return noErr }
            pressedToggleID = id
        }
        guard pressed else { return noErr }
        if let recorder = NSApp.keyWindow?.firstResponder as? ShortcutRecordButton, recorder.isRecording {
            recorder.finish(with: registration.binding)
        } else {
            onAction(action)
        }
        return noErr
    }

    private func tapDisabled(timedOut: Bool) {
        consumedBrightnessKeys.removeAll()
        if timedOut, AXIsProcessTrusted(), let brightnessTap {
            CGEvent.tapEnable(tap: brightnessTap, enable: true)
        }
    }

    private func removeBrightnessTap() {
        if let brightnessSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), brightnessSource, .commonModes)
            self.brightnessSource = nil
        }
        if let brightnessTap {
            CGEvent.tapEnable(tap: brightnessTap, enable: false)
            CFMachPortInvalidate(brightnessTap)
            self.brightnessTap = nil
        }
        consumedBrightnessKeys.removeAll()
    }

    private func handleBrightnessKey(
        _ key: Int32, state: UInt32, repeatPress: Bool, modifiers: NSEvent.ModifierFlags
    ) -> Bool {
        if state == UInt32(NX_KEYUP) {
            return consumedBrightnessKeys.remove(key) != nil
        }
        guard state == UInt32(NX_KEYDOWN) else { return false }

        let plain = modifiers.isEmpty
        let fine = modifiers == [.option, .shift]
        if repeatPress {
            guard consumedBrightnessKeys.contains(key) else { return false }
            if plain || fine {
                _ = onBrightnessKey(key == NX_KEYTYPE_BRIGHTNESS_UP, fine)
            }
            return true
        }
        consumedBrightnessKeys.remove(key)
        guard plain || fine, onBrightnessKey(key == NX_KEYTYPE_BRIGHTNESS_UP, fine) else {
            return false
        }
        consumedBrightnessKeys.insert(key)
        return true
    }
}

struct ShortcutRecorder: View {
    @Binding var binding: KeyBinding?

    var body: some View {
        HStack(spacing: 6) {
            RecordShortcutButton(binding: $binding)
                .frame(minWidth: 126, minHeight: 24)
            if binding != nil {
                Button {
                    binding = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Remove shortcut")
                .help("Remove shortcut")
            }
        }
    }
}

private struct RecordShortcutButton: NSViewRepresentable {
    @Binding var binding: KeyBinding?

    func makeNSView(context: Context) -> ShortcutRecordButton {
        ShortcutRecordButton(frame: .zero)
    }

    func updateNSView(_ button: ShortcutRecordButton, context: Context) {
        button.onRecord = { binding = $0 }
        button.bindingTitle = binding?.displayName
    }
}

private final class ShortcutRecordButton: NSButton {
    private static let modifiers: [(NSEvent.ModifierFlags, UInt32, String)] = [
        (.control, UInt32(controlKey), "⌃"),
        (.option, UInt32(optionKey), "⌥"),
        (.shift, UInt32(shiftKey), "⇧"),
        (.command, UInt32(cmdKey), "⌘"),
    ]

    private static let namedKeys: [Int: String] = [
        kVK_Return: "↩", kVK_Tab: "⇥", kVK_Space: "Space", kVK_Delete: "⌫",
        kVK_ForwardDelete: "⌦", kVK_Home: "↖", kVK_End: "↘",
        kVK_PageUp: "⇞", kVK_PageDown: "⇟", kVK_LeftArrow: "←", kVK_RightArrow: "→",
        kVK_DownArrow: "↓", kVK_UpArrow: "↑",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5",
        kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10",
        kVK_F11: "F11", kVK_F12: "F12", kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15",
        kVK_F16: "F16", kVK_F17: "F17", kVK_F18: "F18", kVK_F19: "F19", kVK_F20: "F20",
    ]

    var onRecord: ((KeyBinding) -> Void)?
    var bindingTitle: String? {
        didSet { if !isRecording { showBinding() } }
    }
    private(set) var isRecording = false
    override var acceptsFirstResponder: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        bezelStyle = .rounded
        controlSize = .small
        target = self
        action = #selector(beginRecording)
        toolTip = "Click and press a keyboard shortcut. Press Escape to cancel."
        showBinding()
    }

    required init?(coder: NSCoder) {
        return nil
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if let window {
            cancelRecording()
            NotificationCenter.default.removeObserver(
                self, name: NSWindow.didResignKeyNotification, object: window
            )
        }
        if let newWindow {
            NotificationCenter.default.addObserver(
                self, selector: #selector(cancelRecording),
                name: NSWindow.didResignKeyNotification, object: newWindow
            )
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func resignFirstResponder() -> Bool {
        cancelRecording()
        return super.resignFirstResponder()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if isRecording { return record(event) }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if !isRecording || !record(event) { super.keyDown(with: event) }
    }

    func finish(with binding: KeyBinding) {
        isRecording = false
        bindingTitle = binding.displayName
        onRecord?(binding)
    }

    @objc private func beginRecording() {
        guard window?.makeFirstResponder(self) == true else { return }
        isRecording = true
        title = "Press shortcut…"
    }

    @objc private func cancelRecording() {
        guard isRecording else { return }
        isRecording = false
        showBinding()
    }

    private func record(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        let code = Int(event.keyCode)
        if code == kVK_Escape {
            cancelRecording()
            return true
        }
        let modifiers = Self.modifiers.filter { event.modifierFlags.contains($0.0) }
        guard !modifiers.isEmpty else {
            title = "Add a modifier"
            return true
        }

        let flags = modifiers.reduce(UInt32(0)) { $0 | $1.1 }
        let symbols = modifiers.map { $0.2 }.joined()
        let key = Self.namedKeys[code] ?? event.charactersIgnoringModifiers?.uppercased()
        guard let key, !key.isEmpty, key.unicodeScalars.allSatisfy({
            !$0.properties.isWhitespace && $0.properties.generalCategory != .control
        }) else { return true }
        finish(with: KeyBinding(keyCode: UInt32(code), modifiers: flags, displayName: symbols + key))
        return true
    }

    private func showBinding() {
        title = bindingTitle ?? "Record shortcut"
    }
}

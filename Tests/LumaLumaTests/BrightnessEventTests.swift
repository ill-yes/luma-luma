import AppKit
import IOKit.hidsystem

@main
struct BrightnessEventTests {
    @MainActor
    static func main() {
        testNativePressKeepsItsReleaseAfterTakingOverRepeats()
        testConsumedPressHandsOffExactlyOnce()
        testFailedHandoffKeepsTheReleaseConsumed()
        testUnrelatedEventsPassThrough()
        testResetDiscardsOutstandingPresses()
        testReplacementPreservesMediaKeyData()
        testSavedDuplicatesKeepFirstAction()
        testAssignmentRejectsAnUnavailableSavedDuplicate()
        testReplacementRegistersBeforeRemovingTheCurrentShortcut()
        print("Brightness event routing and shortcut assignment checks passed.")
    }

    private static func testNativePressKeepsItsReleaseAfterTakingOverRepeats() {
        for key in [NX_KEYTYPE_BRIGHTNESS_UP, NX_KEYTYPE_BRIGHTNESS_DOWN] {
            var presses = BrightnessKeyPresses()
            expect(presses.route(key: key, state: UInt32(NX_KEYDOWN), isRepeat: false, modifiers: []) { _, _ in
                false
            }, .forward)
            expect(presses.route(
                key: key, state: UInt32(NX_KEYDOWN), isRepeat: true, modifiers: [.shift, .option]
            ) { increase, fine in
                precondition(increase == (key == NX_KEYTYPE_BRIGHTNESS_UP) && fine)
                return true
            }, .consume)
            expect(presses.route(
                key: key, state: UInt32(NX_KEYUP), isRepeat: false, modifiers: [], adjust: unexpectedAdjustment
            ), .forward)
        }
    }

    private static func testConsumedPressHandsOffExactlyOnce() {
        var presses = BrightnessKeyPresses()
        let key = NX_KEYTYPE_BRIGHTNESS_DOWN
        expect(presses.route(key: key, state: UInt32(NX_KEYDOWN), isRepeat: false, modifiers: []) { _, _ in true },
               .consume)
        expect(presses.route(key: key, state: UInt32(NX_KEYDOWN), isRepeat: true, modifiers: []) { _, _ in true },
               .consume)
        expect(presses.route(key: key, state: UInt32(NX_KEYDOWN), isRepeat: true, modifiers: []) { _, _ in false },
               .beginNativePress)
        presses.didBeginNativePress(for: key)
        expect(presses.route(
            key: key, state: UInt32(NX_KEYDOWN), isRepeat: true, modifiers: [], adjust: unexpectedAdjustment
        ), .forward)
        expect(presses.route(
            key: key, state: UInt32(NX_KEYUP), isRepeat: false, modifiers: [], adjust: unexpectedAdjustment
        ), .forward)
    }

    private static func testFailedHandoffKeepsTheReleaseConsumed() {
        var presses = BrightnessKeyPresses()
        let key = NX_KEYTYPE_BRIGHTNESS_DOWN
        expect(presses.route(key: key, state: UInt32(NX_KEYDOWN), isRepeat: false, modifiers: []) { _, _ in true },
               .consume)
        expect(presses.route(key: key, state: UInt32(NX_KEYDOWN), isRepeat: true, modifiers: []) { _, _ in false },
               .beginNativePress)
        // Conversion failed, so no down reached macOS.
        expect(presses.route(
            key: key, state: UInt32(NX_KEYUP), isRepeat: false, modifiers: [], adjust: unexpectedAdjustment
        ), .consume)
        expect(presses.route(key: key, state: UInt32(NX_KEYDOWN), isRepeat: false, modifiers: []) { _, _ in false },
               .forward)
    }

    private static func testUnrelatedEventsPassThrough() {
        var presses = BrightnessKeyPresses()
        let key = NX_KEYTYPE_BRIGHTNESS_UP
        expect(presses.route(
            key: NX_KEYTYPE_SOUND_UP, state: UInt32(NX_KEYDOWN), isRepeat: false,
            modifiers: [], adjust: unexpectedAdjustment
        ), .forward)
        expect(presses.route(
            key: key, state: UInt32(NX_KEYDOWN), isRepeat: true, modifiers: [], adjust: unexpectedAdjustment
        ), .forward)
        expect(presses.route(
            key: key, state: UInt32(NX_KEYDOWN), isRepeat: false, modifiers: [.command], adjust: unexpectedAdjustment
        ), .forward)
        expect(presses.route(
            key: key, state: UInt32(NX_KEYDOWN), isRepeat: true, modifiers: [], adjust: unexpectedAdjustment
        ), .forward)
    }

    private static func testResetDiscardsOutstandingPresses() {
        var presses = BrightnessKeyPresses()
        let key = NX_KEYTYPE_BRIGHTNESS_UP
        expect(presses.route(key: key, state: UInt32(NX_KEYDOWN), isRepeat: false, modifiers: []) { _, _ in true },
               .consume)
        presses.reset()
        expect(presses.route(
            key: key, state: UInt32(NX_KEYDOWN), isRepeat: true, modifiers: [], adjust: unexpectedAdjustment
        ), .forward)
        expect(presses.route(
            key: key, state: UInt32(NX_KEYUP), isRepeat: false, modifiers: [], adjust: unexpectedAdjustment
        ), .forward)
    }

    private static func testReplacementPreservesMediaKeyData() {
        let data1 = (Int(NX_KEYTYPE_BRIGHTNESS_DOWN) << 16) | (Int(NX_KEYDOWN) << 8) | 1
        guard let original = NSEvent.otherEvent(
            with: .systemDefined, location: .zero, modifierFlags: [.shift, .option], timestamp: 42,
            windowNumber: 0, context: nil, subtype: Int16(NX_SUBTYPE_AUX_CONTROL_BUTTONS), data1: data1, data2: -1
        ), let replacement = BrightnessKeyPresses.nativeDown(replacingRepeat: original),
           let decoded = NSEvent(cgEvent: replacement) else {
            preconditionFailure("Could not round-trip a media key event")
        }
        precondition(decoded.type == original.type)
        precondition(decoded.subtype == original.subtype)
        precondition(decoded.data1 == data1 - 1)
        precondition(decoded.data2 == original.data2)
        precondition(decoded.modifierFlags == original.modifierFlags)
        precondition(decoded.timestamp == original.timestamp)
    }

    private static func testSavedDuplicatesKeepFirstAction() {
        let toggle = KeyBinding(keyCode: 1, modifiers: 256, displayName: "⌘A")
        let duplicate = KeyBinding(keyCode: 1, modifiers: 256, displayName: "Command A")
        let different = KeyBinding(keyCode: 1, modifiers: 512, displayName: "⇧A")
        let saved: [ShortcutAction: KeyBinding] = [.increase: duplicate, .decrease: different, .toggle: toggle]
        let normalized = ShortcutController.normalizedBindings(saved)
        precondition(normalized == [.toggle: toggle, .decrease: different])
        precondition(ShortcutController.normalizedBindings(normalized) == normalized)
    }

    @MainActor
    private static func testAssignmentRejectsAnUnavailableSavedDuplicate() {
        let current = KeyBinding(keyCode: 1, modifiers: 256, displayName: "⌘A")
        let unavailable = KeyBinding(keyCode: 2, modifiers: 256, displayName: "⌘B")
        let duplicate = KeyBinding(keyCode: 2, modifiers: 256, displayName: "Command B")
        var attempts: [KeyBinding] = []
        var removed: [KeyBinding] = []
        let controller = ShortcutController(onAction: { _ in }, onBrightnessKey: { _, _ in false }) { binding, _ in
            attempts.append(binding)
            guard binding != unavailable else { return nil }
            return { removed.append(binding) }
        }
        let saved: [ShortcutAction: KeyBinding] = [.toggle: current, .increase: unavailable]
        precondition(controller.update(bindings: saved) != nil)
        precondition(attempts == [current, unavailable])
        precondition(controller.setBinding(duplicate, for: .toggle, bindings: saved)?.contains("already assigned") == true)
        precondition(attempts == [current, unavailable] && removed.isEmpty)
        controller.stop()
        precondition(removed == [current])
    }

    @MainActor
    private static func testReplacementRegistersBeforeRemovingTheCurrentShortcut() {
        let current = KeyBinding(keyCode: 1, modifiers: 256, displayName: "⌘A")
        let unavailable = KeyBinding(keyCode: 2, modifiers: 256, displayName: "⌘B")
        let replacement = KeyBinding(keyCode: 3, modifiers: 256, displayName: "⌘C")
        let relabeled = KeyBinding(keyCode: 3, modifiers: 256, displayName: "Command C")
        var events: [String] = []
        let controller = ShortcutController(onAction: { _ in }, onBrightnessKey: { _, _ in false }) { binding, _ in
            events.append("Register \(binding.displayName)")
            guard binding != unavailable else { return nil }
            return { events.append("Remove \(binding.displayName)") }
        }
        let saved: [ShortcutAction: KeyBinding] = [.toggle: current]
        precondition(controller.update(bindings: saved) == nil)
        precondition(controller.update(bindings: saved) == nil)
        precondition(controller.setBinding(unavailable, for: .toggle, bindings: saved) != nil)
        precondition(controller.update(bindings: saved) == nil)
        precondition(events == ["Register ⌘A", "Register ⌘B"])

        precondition(controller.setBinding(replacement, for: .toggle, bindings: saved) == nil)
        precondition(controller.update(bindings: [.toggle: replacement]) == nil)
        precondition(controller.setBinding(relabeled, for: .toggle, bindings: [.toggle: replacement]) == nil)
        precondition(controller.update(bindings: [.toggle: relabeled]) == nil)
        precondition(events == ["Register ⌘A", "Register ⌘B", "Register ⌘C", "Remove ⌘A"])

        precondition(controller.setBinding(nil, for: .toggle, bindings: [.toggle: relabeled]) == nil)
        precondition(controller.update(bindings: [:]) == nil)
        precondition(events.last == "Remove ⌘C" && events.count == 5)
        precondition(controller.setBrightnessKeysEnabled(false) == .off)
        controller.stop()
    }

    private static func unexpectedAdjustment(_ increase: Bool, _ fine: Bool) -> Bool {
        preconditionFailure("A pass-through event called the brightness controller")
    }

    private static func expect(
        _ actual: BrightnessKeyPresses.Disposition,
        _ expected: BrightnessKeyPresses.Disposition,
        file: StaticString = #file,
        line: UInt = #line
    ) {
        precondition(actual == expected, "Expected \(expected), received \(actual)", file: file, line: line)
    }
}

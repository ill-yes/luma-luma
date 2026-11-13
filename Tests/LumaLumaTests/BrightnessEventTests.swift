import AppKit
import IOKit.hidsystem

@main
struct BrightnessEventTests {
    static func main() {
        testNativePressKeepsItsReleaseAfterTakingOverRepeats()
        testConsumedPressHandsOffExactlyOnce()
        testFailedHandoffKeepsTheReleaseConsumed()
        testUnrelatedEventsPassThrough()
        testResetDiscardsOutstandingPresses()
        testReplacementPreservesMediaKeyData()
        print("Brightness event routing checks passed.")
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

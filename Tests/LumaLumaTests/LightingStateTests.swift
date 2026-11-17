import Foundation

@main
struct LightingStateTests {
    static func main() throws {
        selectionWhileDisabled()
        enabledSelection()
        repeatedRequestsAreIdempotent()
        keyboardStrengthSurvivesNavigation()
        reenablingBoostUsesSavedStrength()
        keyboardStartsBoostFromDisabled()
        rapidOffOnProducesDistinctTransitions()
        automationTransitionsRestoreManualIntent()
        legacyStartupPreferenceProvidesInitialState()
        corruptStoredStateStartsOff()
        try manualBoostAndDisplayStrengthsSurviveReload()
        connectionOnlyTargetStartsOffAfterReload()
        storedStrengthsAreValidated()
        print("Lighting selection, activation and persistence checks passed")
    }

    private static func selectionWhileDisabled() {
        var state = LightingState()
        precondition(state.selectedEffect == .boost && state.mode == .off)
        for effect in LightingEffect.allCases {
            _ = state.selectEffect(effect)
            precondition(state.selectedEffect == effect)
            precondition(!state.isEnabled && state.mode == .off)
        }
    }

    private static func enabledSelection() {
        var state = LightingState()
        precondition(state.setEnabled(true))
        for effect in LightingEffect.allCases {
            _ = state.selectEffect(effect)
            precondition(state.isEnabled && state.mode == effect.mode)
        }
    }

    private static func repeatedRequestsAreIdempotent() {
        var state = LightingState()
        precondition(!state.setEnabled(false))
        precondition(!state.selectEffect(.boost))
        precondition(state.setEnabled(true))
        precondition(!state.setEnabled(true))
        precondition(state.mode == .boost)
        precondition(state.setEnabled(false))
        precondition(!state.setEnabled(false))
    }

    private static func keyboardStrengthSurvivesNavigation() {
        var state = LightingState()
        precondition(state.activate(.boost, keyboardBoost: 1.0 / 16))
        precondition(!state.selectEffect(.boost))
        precondition(!state.setEnabled(true))
        precondition(state.keyboardBoost == 1.0 / 16)
        precondition(state.mode == .boost)
    }

    private static func reenablingBoostUsesSavedStrength() {
        let savedStrength = 1.0
        var state = LightingState()
        _ = state.activate(.boost, keyboardBoost: 0.25)
        precondition((state.keyboardBoost ?? savedStrength) == 0.25)
        _ = state.setEnabled(false)
        _ = state.setEnabled(true)
        precondition((state.keyboardBoost ?? savedStrength) == savedStrength)
        _ = state.activate(.boost, keyboardBoost: 0.5)
        precondition(state.useManualBoost())
        precondition(!state.useManualBoost())
        precondition((state.keyboardBoost ?? savedStrength) == 1.0)
    }

    private static func keyboardStartsBoostFromDisabled() {
        var state = LightingState()
        _ = state.selectEffect(.ring)
        _ = state.activate(.boost, keyboardBoost: 1.0 / 64)
        precondition(state.selectedEffect == .boost && state.isEnabled)
        precondition(state.keyboardBoost == 1.0 / 64)
        _ = state.setEnabled(false)
        precondition(state.selectedEffect == .boost && state.keyboardBoost == nil)
    }

    private static func rapidOffOnProducesDistinctTransitions() {
        var state = LightingState()
        _ = state.selectEffect(.eclipse)
        precondition(state.setEnabled(true) && state.mode == .eclipse)
        precondition(state.setEnabled(false) && state.mode == .off)
        precondition(state.setEnabled(true) && state.mode == .eclipse)
        precondition(state.setEnabled(false) && state.mode == .off)
    }

    private static func automationTransitionsRestoreManualIntent() {
        withDefaults { defaults in
            var boost = LightingState()
            _ = boost.activate(.boost, keyboardBoost: 0.3125)
            let target = DisplayBoostKey.persistent(UUID())
            let on = StoredManualLighting(lighting: boost, displayBoost: DisplayBoostSession(singleDisplay: target))
            var inactive = LightingState()
            _ = inactive.selectEffect(.ring)
            let off = StoredManualLighting(lighting: inactive, displayBoost: DisplayBoostSession())
            let transitions: [(previous: LightingAutomation?, restoresOnManual: Bool)] = [
                (nil, true), (.manual, false), (.power, true), (.ambient, true)
            ]

            for saved in [on, off] {
                saved.save(to: defaults)
                for transition in transitions {
                    let restores = LightingAutomation.manual.shouldRestoreManualState(after: transition.previous)
                    let restored = restores ? StoredManualLighting.load(from: defaults) : nil
                    precondition(restored == (transition.restoresOnManual ? saved : nil))
                    precondition(!LightingAutomation.power.shouldRestoreManualState(after: transition.previous))
                    precondition(!LightingAutomation.ambient.shouldRestoreManualState(after: transition.previous))
                }
            }
        }
    }

    private static func legacyStartupPreferenceProvidesInitialState() {
        withDefaults { defaults in
            precondition(StoredManualLighting.load(from: defaults).lighting.mode == .off)
            defaults.set(true, forKey: "startEnabled")
            precondition(StoredManualLighting.load(from: defaults).lighting.mode == .off)
        }
        withDefaults { defaults in
            defaults.set(true, forKey: "startEnabled")
            let migrated = StoredManualLighting.load(from: defaults)
            precondition(migrated.lighting.mode == .boost)
            precondition(migrated.displayBoost == DisplayBoostSession())
            defaults.set(false, forKey: "startEnabled")
            precondition(StoredManualLighting.load(from: defaults) == migrated)
        }
    }

    private static func corruptStoredStateStartsOff() {
        withDefaults { defaults in
            defaults.set(true, forKey: "startEnabled")
            defaults.set(Data("{}".utf8), forKey: "manualLightingState")
            let stored = StoredManualLighting.load(from: defaults)
            precondition(stored.lighting.mode == .off)
            precondition(stored.displayBoost == DisplayBoostSession())
        }
    }

    private static func manualBoostAndDisplayStrengthsSurviveReload() throws {
        try withDefaults { defaults in
            let primary = UUID()
            let secondary = UUID()
            let first = DisplayBoostKey.persistent(primary)
            let second = DisplayBoostKey.persistent(secondary)
            let profiles = try JSONEncoder().encode([primary: DisplayProfile(boost: 0.75)])
            defaults.set(profiles, forKey: "displayProfiles")
            defaults.set(true, forKey: "startEnabled")
            var lighting = LightingState()
            _ = lighting.activate(.boost, keyboardBoost: 0.3125)

            let group = DisplayBoostSession(levels: [first: 0.5625, second: 0, .connection(9): 1])
            StoredManualLighting(lighting: lighting, displayBoost: group).save(to: defaults)
            let restoredGroup = StoredManualLighting.load(from: defaults)
            precondition(restoredGroup.lighting == lighting)
            precondition(restoredGroup.displayBoost == DisplayBoostSession(levels: [first: 0.5625, second: 0]))
            precondition(defaults.data(forKey: "displayProfiles") == profiles)

            let single = DisplayBoostSession(singleDisplay: second, levels: [second: 0.25])
            StoredManualLighting(lighting: lighting, displayBoost: single).save(to: defaults)
            let restoredSingle = StoredManualLighting.load(from: defaults)
            precondition(restoredSingle.lighting == lighting && restoredSingle.displayBoost == single)

            _ = lighting.setEnabled(false)
            _ = lighting.selectEffect(.ring)
            StoredManualLighting(lighting: lighting, displayBoost: single).save(to: defaults)
            let restoredOff = StoredManualLighting.load(from: defaults)
            precondition(restoredOff.lighting.selectedEffect == .ring && restoredOff.lighting.mode == .off)
            precondition(restoredOff.displayBoost == DisplayBoostSession())
        }
    }

    private static func connectionOnlyTargetStartsOffAfterReload() {
        withDefaults { defaults in
            var lighting = LightingState()
            _ = lighting.activate(.boost, keyboardBoost: 0.5)
            let target = DisplayBoostKey.connection(42)
            let session = DisplayBoostSession(singleDisplay: target, levels: [target: 0.5])
            StoredManualLighting(lighting: lighting, displayBoost: session).save(to: defaults)
            let restored = StoredManualLighting.load(from: defaults)
            precondition(restored.lighting.selectedEffect == .boost && restored.lighting.mode == .off)
            precondition(restored.lighting.keyboardBoost == nil && restored.displayBoost == DisplayBoostSession())
        }
    }

    private static func storedStrengthsAreValidated() {
        var lighting = LightingState()
        _ = lighting.activate(.boost, keyboardBoost: .infinity)
        let first = DisplayBoostKey.persistent(UUID())
        let second = DisplayBoostKey.persistent(UUID())
        let third = DisplayBoostKey.persistent(UUID())
        let displayBoost = DisplayBoostSession(levels: [first: -1, second: 2, third: .nan])
        let stored = StoredManualLighting(lighting: lighting, displayBoost: displayBoost)
        precondition(stored.lighting.keyboardBoost == nil)
        precondition(stored.displayBoost.levels == [first: 0, second: 1])
    }

    private static func withDefaults(_ test: (UserDefaults) throws -> Void) rethrows {
        let name = "dev.illyes.lumaluma.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        try test(defaults)
    }
}

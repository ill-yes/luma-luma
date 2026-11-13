@main
struct LightingStateTests {
    static func main() {
        selectionWhileDisabled()
        enabledSelection()
        repeatedRequestsAreIdempotent()
        keyboardStrengthSurvivesNavigation()
        manualRestartUsesSavedStrength()
        keyboardStartsBoostFromDisabled()
        rapidOffOnProducesDistinctTransitions()
        print("Lighting selection and activation checks passed")
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

    private static func manualRestartUsesSavedStrength() {
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
}

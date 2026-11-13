import Foundation

@main
struct DisplayControlStateTests {
    static func main() throws {
        sliderDestinationsRespectDisplayCapabilities()
        hiddenHDRSpaceIgnoresNewGestures()
        heldDragContinuesAfterConfirmation()
        releasedDragDoesNotStartBoost()
        accessibilityStepsCrossConfirmedMaximum()
        restorationUsesLatestRequestForSameDisplay()
        cancelledRestorationCannotCompleteReplacementRequest()
        switchedDisplayIgnoresPreviousRestoration()
        addingBoostOnAnotherDisplayPreservesExistingTargets()
        try profilesRoundTripWithIndependentOverrides()
        profileValidationPreservesInheritance()
        displayGroupsMatchTheirCoverage()
        print("Display control, transition and profile checks passed")
    }

    private static func hiddenHDRSpaceIgnoresNewGestures() {
        var drag = BrightnessSliderDrag()
        precondition(drag.update(position: 1.4, startPosition: 1.4, showsHDRRange: false) == nil)
        precondition(drag.update(position: 0.8, startPosition: 1.4, showsHDRRange: false) == nil)
        precondition(drag.revealHDRRange() == nil)
        drag.end()
        precondition(drag.update(position: 1.4, startPosition: 1.4, showsHDRRange: true) == 1.4)
    }

    private static func heldDragContinuesAfterConfirmation() {
        var drag = BrightnessSliderDrag()
        precondition(drag.update(position: 0.5, startPosition: 0.5, showsHDRRange: false) == 0.5)
        precondition(drag.update(position: 1.3, startPosition: 0.5, showsHDRRange: false) == 1)
        precondition(drag.update(position: 1.5, startPosition: 0.5, showsHDRRange: false) == nil)
        precondition(drag.revealHDRRange() == 1.5)
        precondition(drag.update(position: 0.75, startPosition: 0.5, showsHDRRange: true) == 0.75)
        precondition(drag.revealHDRRange() == nil)
    }

    private static func releasedDragDoesNotStartBoost() {
        var drag = BrightnessSliderDrag()
        precondition(drag.update(position: 1.5, startPosition: 0.5, showsHDRRange: false) == 1)
        drag.end()
        precondition(drag.revealHDRRange() == nil)
    }

    private static func accessibilityStepsCrossConfirmedMaximum() {
        let below = BrightnessControl(mode: .combined, value: 0.998, canAdjust: true,
                                      nativeLevel: 0.998, showsHDRRange: false)
        let maximum = BrightnessControl(mode: .combined, value: 1, canAdjust: true,
                                        nativeLevel: 1, showsHDRRange: true)
        let boost = BrightnessControl(mode: .combined, value: 1.01, canAdjust: true,
                                      nativeLevel: 1, showsHDRRange: true)
        precondition(below.adjustedValue(increasing: true) == 1)
        precondition(maximum.adjustedValue(increasing: true) == 1.01)
        precondition(boost.adjustedValue(increasing: false) == 1)
        precondition(maximum.adjustedValue(increasing: false) == 0.99)
        precondition(!BrightnessControl.isNativeMaximum(0.998))
        precondition(BrightnessControl.isNativeMaximum(1))
    }

    private static func sliderDestinationsRespectDisplayCapabilities() {
        let nativeMaximum = 1.0
        precondition(BrightnessDestination(value: nativeMaximum.nextDown, mode: .combined) ==
                     .native(nativeMaximum.nextDown))
        precondition(BrightnessDestination(value: nativeMaximum, mode: .combined) == .native(1))
        precondition(BrightnessDestination(value: nativeMaximum.nextUp, mode: .combined) ==
                     .boost(Double.ulpOfOne))
        precondition(BrightnessDestination(value: 1.5, mode: .combined) == .boost(0.5))
        precondition(BrightnessDestination(value: 2.5, mode: .combined) == .boost(1))
        precondition(BrightnessDestination(value: -0.25, mode: .combined) == .native(0))

        precondition(BrightnessDestination(value: 1.5, mode: .native) == .native(1))
        precondition(BrightnessDestination(value: 0.5, mode: .boost) == .boost(0.5))
        precondition(BrightnessDestination(value: 0, mode: .boost) == .boost(0))
        precondition(BrightnessDestination(value: .nan, mode: .native) == nil)
        precondition(BrightnessDestination(value: .infinity, mode: .combined) == nil)
        precondition(BrightnessDestination(value: -.infinity, mode: .boost) == nil)
    }

    private static func restorationUsesLatestRequestForSameDisplay() {
        var transition = BrightnessTransition()
        transition.submit(.native(0.75), for: 1)
        let token = transition.awaitRestoration()

        transition.submit(.native(0.5), for: 1)
        transition.submit(.boost(0.25), for: 1)

        precondition(transition.restoration == token)
        precondition(transition.finishRestoration(token) == .init(displayID: 1, destination: .boost(0.25)))
        precondition(transition.restoration == nil)
        precondition(transition.finishRestoration(token) == nil)
    }

    private static func cancelledRestorationCannotCompleteReplacementRequest() {
        var transition = BrightnessTransition()
        transition.submit(.native(0.75), for: 1)
        let cancelled = transition.awaitRestoration()
        transition.cancel()
        precondition(transition.request == nil && transition.restoration == nil)

        transition.submit(.native(0.25), for: 1)
        let replacement = transition.awaitRestoration()
        precondition(transition.finishRestoration(cancelled) == nil)
        precondition(transition.restoration == replacement)
        precondition(transition.finishRestoration(replacement) == .init(displayID: 1, destination: .native(0.25)))
    }

    private static func switchedDisplayIgnoresPreviousRestoration() {
        var transition = BrightnessTransition()
        transition.submit(.native(0.75), for: 1)
        let previousDisplay = transition.awaitRestoration()
        transition.submit(.native(0.25), for: 2)

        precondition(transition.restoration == nil)
        precondition(transition.finishRestoration(previousDisplay) == nil)
        precondition(transition.request == .init(displayID: 2, destination: .native(0.25)))
    }

    private static func profilesRoundTripWithIndependentOverrides() throws {
        let internalDisplay = UUID()
        let externalDisplay = UUID()
        let profiles = [
            internalDisplay: DisplayProfile(boost: 0.75, region: .split, ringWarmth: 0.25),
            externalDisplay: DisplayProfile(participates: false, dim: 0.4, ringStrength: 0.5, ringWidth: 0.2)
        ]
        let encoded = try JSONEncoder().encode(profiles)
        let restored = try JSONDecoder().decode([UUID: DisplayProfile].self, from: encoded)
        precondition(restored == profiles)

        let inherited = try JSONDecoder().decode(DisplayProfile.self, from: Data("{}".utf8))
        precondition(inherited == DisplayProfile())
    }

    private static func addingBoostOnAnotherDisplayPreservesExistingTargets() {
        var session = DisplayBoostSession(singleDisplay: 1)
        precondition(session.strength(for: 1, saved: 0.75) == 0.75)
        precondition(session.strength(for: 2, saved: 0.65) == 0)

        // The selected display can join a single-display session via a shortcut or slider.
        let newStrength = session.strength(for: 2, saved: 0.65) + 1.0 / 16
        session.include(2, among: [1, 2, 3])
        session.levels[2] = nil
        precondition(session.strength(for: 2, saved: newStrength) == 1.0 / 16)
        precondition(session.strength(for: 1, saved: 0.75) == 0.75)
        precondition(session.strength(for: 3, saved: 0.65) == 0)
    }

    private static func profileValidationPreservesInheritance() {
        let profile = DisplayProfile(
            participates: false, boost: 1.5, dim: 1, region: .frontWindow,
            ringStrength: -0.5, ringWidth: .infinity, ringWarmth: .nan
        )
        precondition(profile.validated == DisplayProfile(
            participates: false, boost: 1, dim: 0.95, region: .frontWindow, ringStrength: 0
        ))
        precondition(DisplayProfile().validated == DisplayProfile())
    }

    private static func displayGroupsMatchTheirCoverage() {
        precondition(DisplayScope.all.includes(builtIn: true))
        precondition(DisplayScope.all.includes(builtIn: false))
        precondition(DisplayScope.builtIn.includes(builtIn: true))
        precondition(!DisplayScope.builtIn.includes(builtIn: false))
        precondition(!DisplayScope.external.includes(builtIn: true))
        precondition(DisplayScope.external.includes(builtIn: false))
    }
}

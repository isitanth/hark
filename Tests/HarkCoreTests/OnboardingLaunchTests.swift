import HarkCore
import Testing

@Suite struct OnboardingLaunchTests {
    private func shows(
        dismissed: Bool = false, microphone: MicPermissionStatus = .granted, accessibilityTrusted: Bool = true,
        accessibilityNeeded: Bool = true
    ) -> Bool {
        HealthStatus.showsOnboarding(
            dismissed: dismissed, microphone: microphone, accessibilityTrusted: accessibilityTrusted,
            accessibilityNeeded: accessibilityNeeded)
    }

    @Test func dismissedNeverShows() {
        #expect(!shows(dismissed: true, microphone: .denied, accessibilityTrusted: false))
    }

    @Test func nothingMissingDoesNotShow() {
        #expect(!shows())
    }

    @Test(arguments: [MicPermissionStatus.denied, .undetermined])
    func microphoneMissingShows(_ microphone: MicPermissionStatus) {
        #expect(shows(microphone: microphone))
    }

    @Test func accessibilityMissingAndNeededShows() {
        #expect(shows(accessibilityTrusted: false, accessibilityNeeded: true))
    }

    @Test func accessibilityMissingButNotNeededDoesNotShow() {
        #expect(!shows(accessibilityTrusted: false, accessibilityNeeded: false))
    }
}

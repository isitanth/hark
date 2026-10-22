import Foundation
import HarkCore
import Testing

private typealias H = LLMClientHarness

struct VisionResetCase: Sendable, CustomTestStringConvertible {
    let name: String
    let change: @Sendable (inout ProviderProfile) -> Void
    let forgets: Bool
    var testDescription: String { name }
}

@Suite struct VisionCapabilityTests {
    static let model = "m"

    private func config(_ profile: ProviderProfile) -> LLMConfig {
        LLMConfig(provider: profile.name, profiles: [profile.name: profile])
    }

    @Test func unknownUntilLearned() {
        let vision = VisionCapability()
        #expect(vision.verdict(profile: H.profile, model: Self.model) == nil)
        vision.record(false, profile: H.profile, model: Self.model)
        #expect(vision.verdict(profile: H.profile, model: Self.model) == false)
        #expect(vision.verdict(profile: H.profile, model: "other") == nil)
    }

    @Test func aProbeWithoutTheFieldKeepsWhatARefusalTaught() {
        let vision = VisionCapability()
        vision.record(false, profile: H.profile, model: Self.model)
        vision.record(LLMProbeReport(result: .connected(model: Self.model), vision: nil), profile: H.profile)
        #expect(vision.verdict(profile: H.profile, model: Self.model) == false)
        vision.record(LLMProbeReport(result: .connected(model: Self.model), vision: true), profile: H.profile)
        #expect(vision.verdict(profile: H.profile, model: Self.model) == true)
    }

    static let resets: [VisionResetCase] = [
        .init(name: "base_url", change: { $0.baseURL = URL(string: "http://127.0.0.1:8003/v1")! }, forgets: true),
        .init(name: "model", change: { $0.model = .named("other") }, forgets: true),
        .init(name: "api", change: { $0.api = .anthropic }, forgets: true),
        .init(name: "max_tokens", change: { $0.maxTokens = 7 }, forgets: false),
    ]

    @Test(arguments: resets)
    func aChangedProfileForgets(_ row: VisionResetCase) {
        let vision = VisionCapability()
        vision.update(config(H.profile))
        vision.record(false, profile: H.profile, model: Self.model)
        var changed = H.profile
        row.change(&changed)
        vision.update(config(changed))
        #expect(vision.verdict(profile: H.profile, model: Self.model) == (row.forgets ? nil : false))
    }

    @Test func aChangeBeforeTheFirstUpdateStillForgets() {
        let vision = VisionCapability()
        vision.record(false, profile: H.profile, model: Self.model)
        var changed = H.profile
        changed.api = .anthropic
        vision.update(config(changed))
        #expect(vision.verdict(profile: H.profile, model: Self.model) == nil)
    }

    @Test func aRemovedProfileForgets() {
        let vision = VisionCapability()
        vision.record(true, profile: H.profile, model: Self.model)
        vision.update(config(.claude))
        #expect(vision.verdict(profile: H.profile, model: Self.model) == nil)
    }
}

import Foundation
import HarkCore
import Observation
import os

/// The Ask engine's side of the app: the LLM client and its probe, the Keychain, and what the last call to the
/// server came to. Settings › Ask renders it; from M8.4 the Ask panel does too.
@Observable
final class AskModel {
    /// Set by a failed Test or ask, cleared by the next success: `HealthIssue.llmUnreachable` while set. Hark never
    /// checks in the background.
    private(set) var lastFailure: LLMFailure?
    /// The model id the server reported at the last successful check.
    private(set) var model: String?
    /// Whether the active profile has a key in the Keychain. Nil until asked.
    private(set) var hasKey: Bool?
    /// A check on open is on its way; a second open while it runs asks nothing more.
    @ObservationIgnored private var checking = false
    /// Counts active-profile changes, so an answer about the profile before one lands nowhere.
    @ObservationIgnored private var generation = 0

    @ObservationIgnored let secrets: any SecretStore
    @ObservationIgnored let client: LLMClient
    @ObservationIgnored let probe: LLMProbe

    private static let logger = Logger(subsystem: "com.anthonychambet.hark", category: "llm")

    init(secrets: any SecretStore = KeychainSecretStore()) {
        self.secrets = secrets
        client = LLMClient(secrets: secrets)
        probe = LLMProbe(client: client)
    }

    /// `GET /models` on `profile`, and what it says for the health row.
    func test(_ profile: ProviderProfile) async -> LLMProbeResult {
        let asked = generation
        let result = await probe.check(profile)
        if asked == generation { record(result) }
        return result
    }

    /// Opening the panel or Settings › Ask: the server's status, fresh whenever it is looked at, once Ask is set up and
    /// for a server on this Mac only (`LLMProbe.checksOnOpen`). Nil when nothing was checked.
    @discardableResult
    func checkOnOpen(_ profile: ProviderProfile) async -> LLMProbeResult? {
        guard !checking else { return nil }
        checking = true
        defer { checking = false }
        if profile.key == .keychain { await refreshKey(for: profile) }
        guard LLMProbe.checksOnOpen(profile, hasKey: hasKey) else { return nil }
        return await test(profile)
    }

    /// A check or an ask came back: a failure stands until something succeeds.
    func record(_ result: LLMProbeResult) {
        switch result {
        case .connected(let id):
            model = id
            lastFailure = nil
        case .failed(let failure):
            lastFailure = failure
        }
    }

    /// The active profile changed, in Settings or in commands.yaml: what the last one said no longer stands.
    func profileChanged(_ profile: ProviderProfile) async {
        generation += 1
        model = nil
        lastFailure = nil
        hasKey = nil
        if profile.key == .keychain { await refreshKey(for: profile) }
    }

    func refreshKey(for profile: ProviderProfile) async {
        let asked = generation
        let found: Bool?
        do throws(SecretStoreError) {
            found = try await secrets.hasSecret(for: profile.name)
        } catch {
            Self.logger.error("keychain check for \(profile.name, privacy: .public) failed: \(error.status)")
            found = nil
        }
        if asked == generation { hasKey = found }
    }

    /// Saved by re-creating the item, so Hark owns it. Nil on success, the `OSStatus` otherwise.
    func saveKey(_ key: String, for profile: ProviderProfile) async -> Int32? {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return nil }
        do throws(SecretStoreError) {
            try await secrets.setSecret(key, for: profile.name)
            hasKey = true
            return nil
        } catch {
            Self.logger.error("keychain save for \(profile.name, privacy: .public) failed: \(error.status)")
            return error.status
        }
    }

    func removeKey(for profile: ProviderProfile) async -> Int32? {
        do throws(SecretStoreError) {
            try await secrets.removeSecret(for: profile.name)
            hasKey = false
            return nil
        } catch {
            Self.logger.error("keychain remove for \(profile.name, privacy: .public) failed: \(error.status)")
            return error.status
        }
    }
}

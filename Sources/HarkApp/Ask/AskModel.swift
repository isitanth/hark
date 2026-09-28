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
        let result = await probe.check(profile)
        record(result)
        return result
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

    func refreshKey(for profile: ProviderProfile) async {
        do throws(SecretStoreError) {
            hasKey = try await secrets.hasSecret(for: profile.name)
        } catch {
            Self.logger.error("keychain check for \(profile.name, privacy: .public) failed: \(error.status)")
            hasKey = nil
        }
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

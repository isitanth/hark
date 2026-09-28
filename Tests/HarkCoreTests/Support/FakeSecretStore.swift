import Foundation
import HarkCore
import os

/// An in-memory `SecretStore` that records every call and can be told to fail.
final class FakeSecretStore: SecretStore {
    enum Call: Equatable, Sendable {
        case read(String)
        case set(String)
        case remove(String)
    }

    private struct State {
        var secrets: [String: String]
        var calls: [Call] = []
        var failure: SecretStoreError?
    }

    private let state: OSAllocatedUnfairLock<State>

    init(_ secrets: [String: String] = [:], failure: SecretStoreError? = nil) {
        state = OSAllocatedUnfairLock(initialState: State(secrets: secrets, failure: failure))
    }

    var calls: [Call] { state.withLock { $0.calls } }

    func fail(with failure: SecretStoreError?) {
        state.withLock { $0.failure = failure }
    }

    func secret(for account: String) async throws(SecretStoreError) -> String? {
        let (value, failure) = state.withLock { state in
            state.calls.append(.read(account))
            return (state.secrets[account], state.failure)
        }
        if let failure { throw failure }
        return value
    }

    func setSecret(_ secret: String, for account: String) async throws(SecretStoreError) {
        let failure = state.withLock { state -> SecretStoreError? in
            state.calls.append(.set(account))
            if state.failure == nil { state.secrets[account] = secret }
            return state.failure
        }
        if let failure { throw failure }
    }

    func removeSecret(for account: String) async throws(SecretStoreError) {
        let failure = state.withLock { state -> SecretStoreError? in
            state.calls.append(.remove(account))
            if state.failure == nil { state.secrets[account] = nil }
            return state.failure
        }
        if let failure { throw failure }
    }
}

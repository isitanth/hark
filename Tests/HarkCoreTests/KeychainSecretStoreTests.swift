import Foundation
import HarkCore
import Testing

/// Against the real Keychain, on a test service and a random account removed afterwards. Runs only when
/// HARK_TEST_KEYCHAIN is set: it writes to the login keychain.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["HARK_TEST_KEYCHAIN"] != nil), .serialized)
struct KeychainSecretStoreTests {
    let store = KeychainSecretStore(service: "com.anthonychambet.hark.llm.test")
    let account = "test-\(UUID().uuidString)"

    @Test func readMissingIsNil() async throws {
        #expect(try await store.secret(for: account) == nil)
    }

    @Test func removeMissingIsFine() async throws {
        try await store.removeSecret(for: account)
    }

    /// The item is removed whatever happens in between, so a failure leaves nothing in the login keychain.
    @Test func setReadReplaceRemove() async throws {
        do {
            #expect(try await !store.hasSecret(for: account))
            try await store.setSecret("first-value", for: account)
            #expect(try await store.hasSecret(for: account))
            #expect(try await store.secret(for: account) == "first-value")
            try await store.setSecret("second-value", for: account)
            #expect(try await store.secret(for: account) == "second-value")
        } catch {
            try? await store.removeSecret(for: account)
            throw error
        }
        try await store.removeSecret(for: account)
        #expect(try await store.secret(for: account) == nil)
    }
}

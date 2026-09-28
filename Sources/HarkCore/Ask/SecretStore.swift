import Foundation

/// The Keychain service of every provider profile's key. The account is the profile's name.
public enum SecretStoreService {
    public static let llm = "com.anthonychambet.hark.llm"
}

/// Where API keys live. The Keychain in the app (`KeychainSecretStore`), a fake in tests: nothing else ever holds a
/// key, and no implementation logs one.
public protocol SecretStore: Sendable {
    /// The key stored for `account`, or nil when there is no item.
    func secret(for account: String) async throws(SecretStoreError) -> String?
    /// Whether there is an item for `account`, without reading the key: Settings shows it without macOS asking
    /// whether Hark may use an item another tool made.
    func hasSecret(for account: String) async throws(SecretStoreError) -> Bool
    /// Replaces the item: it is deleted and added again, so its access list names this app rather than the tool
    /// that made it, and macOS stops asking.
    func setSecret(_ secret: String, for account: String) async throws(SecretStoreError)
    /// Removes the item. No item is not an error.
    func removeSecret(for account: String) async throws(SecretStoreError)
}

/// A Keychain call that failed, with its `OSStatus`. Never carries the key.
public struct SecretStoreError: Error, Sendable, Equatable {
    public let status: Int32

    public init(status: Int32) {
        self.status = status
    }
}

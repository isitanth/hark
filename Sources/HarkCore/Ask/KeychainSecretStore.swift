import Foundation
import Security

/// The app's `SecretStore`: one generic password per provider profile, service `SecretStoreService.llm`, account the
/// profile's name, the key as UTF-8. Nothing here logs a value, and an error carries only its `OSStatus`.
public struct KeychainSecretStore: SecretStore {
    public let service: String

    public init(service: String = SecretStoreService.llm) {
        self.service = service
    }

    public func secret(for account: String) async throws(SecretStoreError) -> String? {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw SecretStoreError(status: status) }
        guard let data = result as? Data else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// Deleted, then added: an item updated in place keeps the access list of the tool that made it (`security`, a
    /// scratch script), and macOS would keep asking whether Hark may read it.
    public func setSecret(_ secret: String, for account: String) async throws(SecretStoreError) {
        let deleted = SecItemDelete(baseQuery(account) as CFDictionary)
        guard deleted == errSecSuccess || deleted == errSecItemNotFound else {
            throw SecretStoreError(status: deleted)
        }
        var attributes = baseQuery(account)
        attributes[kSecValueData as String] = Data(secret.utf8)
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw SecretStoreError(status: status) }
    }

    public func removeSecret(for account: String) async throws(SecretStoreError) {
        let status = SecItemDelete(baseQuery(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw SecretStoreError(status: status) }
    }

    private func baseQuery(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

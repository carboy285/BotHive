import Foundation
import Security

/// Device-only secret storage for secure notes and Composio project configuration.
struct KeychainSecretStore {
    let service: String
    /// Readable while the device is locked but has been unlocked once since it started, so a background check can use the saved sign-in.
    var availableInBackground = false

    enum StoreError: Error { case status(OSStatus); case invalidData }

    private func query(account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account,
         kSecAttrSynchronizable as String: false]
    }

    func save(_ secret: Data, account: String) throws {
        let attributes: [String: Any] = [
            kSecValueData as String: secret,
            kSecAttrAccessible as String: availableInBackground ? kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly : kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        let status = SecItemUpdate(query(account: account) as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            let insertion = query(account: account).merging(attributes) { _, new in new }
            let added = SecItemAdd(insertion as CFDictionary, nil)
            guard added == errSecSuccess else { throw StoreError.status(added) }
        } else if status != errSecSuccess { throw StoreError.status(status) }
    }

    func read(account: String) throws -> Data? {
        var request = query(account: account)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &value)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw StoreError.status(status) }
        guard let data = value as? Data else { throw StoreError.invalidData }
        return data
    }

    /// Changes every item of this service to the background-readable setting (items saved earlier were saved as unlocked-only).
    func makeAvailableInBackground() {
        let match: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrSynchronizable as String: false]
        _ = SecItemUpdate(match as CFDictionary, [kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly] as CFDictionary)
    }

    func delete(account: String) throws {
        let status = SecItemDelete(query(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw StoreError.status(status) }
    }
}

import Foundation
import Security

enum KeychainHelper {
    static let service = "com.whisperpilot.app"

    /// Stores (or deletes, when nil/empty) the value. Returns false when the
    /// Keychain rejected the write — callers must surface that, because a
    /// silently dropped API key looks like "AI just doesn't work" to the user.
    @discardableResult
    static func set(_ value: String?, forKey key: String) -> Bool {
        if let value, !value.isEmpty {
            return store(value, forKey: key)
        } else {
            return delete(forKey: key)
        }
    }

    static func get(_ key: String) -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: key,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status != errSecSuccess && status != errSecItemNotFound {
            wpError("Keychain read for \(key) failed: OSStatus \(status)")
        }
        guard status == errSecSuccess,
              let data = result as? Data,
              let string = String(data: data, encoding: .utf8) else { return nil }
        return string
    }

    /// Update-first, add-on-missing. The old delete-then-add pattern was
    /// non-atomic (a crash in between lost the key) and ignored both statuses,
    /// so a failed save was indistinguishable from a successful one.
    private static func store(_ value: String, forKey key: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }
        let baseQuery: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: key
        ]
        let update: [CFString: Any] = [
            kSecValueData: data,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlock
        ]
        var status = SecItemUpdate(baseQuery as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var attributes = baseQuery
            attributes[kSecValueData] = data
            attributes[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlock
            status = SecItemAdd(attributes as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            wpError("Keychain save for \(key) failed: OSStatus \(status)")
            return false
        }
        return true
    }

    private static func delete(forKey key: String) -> Bool {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: key
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            wpError("Keychain delete for \(key) failed: OSStatus \(status)")
            return false
        }
        return true
    }
}

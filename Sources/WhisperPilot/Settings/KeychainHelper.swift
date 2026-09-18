import Foundation
import Security

enum KeychainHelper {
    static let service = "com.whisperpilot.app"

    /// Outcome of a Keychain read. `denied` is kept apart from `failed` because
    /// the user can fix it (they clicked "Deny", or macOS needs their approval)
    /// while a generic failure usually points at a locked or damaged keychain.
    enum ReadResult: Equatable {
        case value(String)
        case notFound
        case denied
        case failed(OSStatus)
    }

    /// Stores (or deletes, when nil/empty) the value. Returns `errSecSuccess`
    /// on success; anything else is the Keychain's reason for rejecting the
    /// write — callers must surface that, because a silently dropped API key
    /// looks like "AI just doesn't work" to the user.
    static func set(_ value: String?, forKey key: String) -> OSStatus {
        if let value, !value.isEmpty {
            return store(value, forKey: key)
        } else {
            return delete(forKey: key)
        }
    }

    /// Identity of the running binary (its code-signature hash). An ad-hoc
    /// signed build gets a new hash on every update, and macOS ties Keychain
    /// approval to that hash — so "did the user already approve *this* build"
    /// is exactly "does the stored hash equal this one". "unknown" never
    /// matches anything, so an unsigned or unreadable binary always re-asks.
    static let buildIdentity: String = {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return unknownBuildIdentity }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return unknownBuildIdentity }
        var info: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(staticCode, flags, &info) == errSecSuccess,
              let dict = info as? [String: Any],
              let hash = dict[kSecCodeInfoUnique as String] as? Data else { return unknownBuildIdentity }
        return hash.map { String(format: "%02x", $0) }.joined()
    }()

    static let unknownBuildIdentity = "unknown"

    /// Plain-English reason for a Keychain failure, for messages shown to the user.
    static func describe(_ status: OSStatus) -> String {
        switch status {
        case errSecUserCanceled, errSecAuthFailed, errSecInteractionNotAllowed:
            return "macOS did not allow access to the Keychain item"
        case errSecNoSuchKeychain, errSecNotAvailable:
            return "the login Keychain is not available (is it locked?)"
        case errSecReadOnly, errSecReadOnlyAttr:
            return "the Keychain is read-only"
        default:
            let text = SecCopyErrorMessageString(status, nil) as String? ?? "unknown error"
            return "\(text) (code \(status))"
        }
    }

    /// Whether a value is stored, WITHOUT reading it.
    ///
    /// This distinction matters a lot on an ad-hoc-signed build. macOS asks the
    /// user to authorize keychain access when an app that isn't on an item's
    /// ACL tries to read the item's *data*; an attributes-only query discloses
    /// no secret and so doesn't raise that prompt. Callers that only need to
    /// know "is a key configured" — the model pickers, the launch-time default-
    /// model choice — must use this instead of `get`, or simply opening the app
    /// costs the user one authorization dialog per configured vendor.
    static func exists(_ key: String) -> Bool {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: key,
            // The point of the whole function: attributes, never data.
            kSecReturnData: false,
            kSecReturnAttributes: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status != errSecSuccess && status != errSecItemNotFound {
            wpError("Keychain existence check for \(key) failed: OSStatus \(status)")
        }
        return status == errSecSuccess
    }

    /// Reads the secret itself. This is the call that can make macOS show its
    /// "wants to use your confidential information" dialog, so it must only run
    /// at a moment the user can see and understand (onboarding or an explicit
    /// "Allow Keychain access" button) — never from a screen that merely opens.
    static func read(_ key: String) -> ReadResult {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: key,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data, let string = String(data: data, encoding: .utf8) else {
                wpError("Keychain read for \(key) returned data that is not UTF-8")
                return .failed(errSecDecode)
            }
            return .value(string)
        case errSecItemNotFound:
            return .notFound
        case errSecUserCanceled, errSecAuthFailed, errSecInteractionNotAllowed:
            wpWarn("Keychain read for \(key) was denied: OSStatus \(status)")
            return .denied
        default:
            wpError("Keychain read for \(key) failed: OSStatus \(status)")
            return .failed(status)
        }
    }

    /// Update-first, add-on-missing. The old delete-then-add pattern was
    /// non-atomic (a crash in between lost the key) and ignored both statuses,
    /// so a failed save was indistinguishable from a successful one.
    private static func store(_ value: String, forKey key: String) -> OSStatus {
        guard let data = value.data(using: .utf8) else { return errSecParam }
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
        if status != errSecSuccess {
            wpError("Keychain save for \(key) failed: OSStatus \(status)")
        }
        return status
    }

    private static func delete(forKey key: String) -> OSStatus {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: key
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status == errSecItemNotFound { return errSecSuccess }
        if status != errSecSuccess {
            wpError("Keychain delete for \(key) failed: OSStatus \(status)")
        }
        return status
    }
}

import Foundation
import Security

struct KeychainError: Error {
    let status: OSStatus
}

/// Keeps the NEIS API key in the login keychain. The key exists only here and in request URLs.
@MainActor
final class NEISKeyStore {
    private static let baseQuery: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "com.ch0ijimin323.backgroundmemo.neis",
        kSecAttrAccount as String: "api-key",
    ]

    private var cachedKey: String?
    private var hasRead = false

    /// Read once per session so fetches do not touch the keychain each time.
    var key: String? {
        if !hasRead {
            hasRead = true
            cachedKey = Self.read()
        }
        return cachedKey
    }

    func save(_ newKey: String) throws {
        let data = Data(newKey.utf8)
        var status = SecItemUpdate(
            Self.baseQuery as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if status == errSecItemNotFound {
            var item = Self.baseQuery
            item[kSecValueData as String] = data
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
        cachedKey = newKey
        hasRead = true
    }

    func delete() throws {
        let status = SecItemDelete(Self.baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
        cachedKey = nil
        hasRead = true
    }

    private static func read() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            if status != errSecItemNotFound { log.error("Keychain read failed with status \(status, privacy: .public)") }
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}

import Foundation
import Security

/// Persists the user's Groq API key in the macOS keychain.
///
/// The key never touches UserDefaults, source, argv, or transcript/error text.
enum KeychainStore {
    private static let service = "app.twhisper.mac"
    private static let account = "groq-api-key"

    enum KeychainError: LocalizedError {
        case unhandled(OSStatus)

        var errorDescription: String? {
            switch self {
            case .unhandled(let status):
                let message = SecCopyErrorMessageString(status, nil) as String? ?? "unknown error"
                return "Keychain error \(status): \(message)"
            }
        }
    }

    private static func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    /// Reads the stored key. Returns `nil` when no key has been saved yet.
    /// Throws when the keychain is present but access fails for another reason.
    static func loadAPIKey() throws -> String? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        switch status {
        case errSecSuccess:
            guard let data = item as? Data, let key = String(data: data, encoding: .utf8) else {
                throw KeychainError.unhandled(status)
            }
            return key
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.unhandled(status)
        }
    }

    /// Saves (or replaces) the stored key.
    static func saveAPIKey(_ key: String) throws {
        let data = Data(key.utf8)
        var query = baseQuery()
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly

        let searchQuery = baseQuery()
        let existsStatus = SecItemCopyMatching(searchQuery as CFDictionary, nil)

        switch existsStatus {
        case errSecSuccess:
            var attributesToUpdate: [String: Any] = [kSecValueData as String: data]
            attributesToUpdate[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let status = SecItemUpdate(searchQuery as CFDictionary, attributesToUpdate as CFDictionary)
            guard status == errSecSuccess else { throw KeychainError.unhandled(status) }
        case errSecItemNotFound:
            var addQuery = query
            addQuery[kSecValueData as String] = data
            let status = SecItemAdd(addQuery as CFDictionary, nil)
            guard status == errSecSuccess else { throw KeychainError.unhandled(status) }
        default:
            throw KeychainError.unhandled(existsStatus)
        }
    }

    /// Removes the stored key. A no-op (not an error) if none exists.
    static func removeAPIKey() throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unhandled(status)
        }
    }
}

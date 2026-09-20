import Foundation
import Security

/// Reads CmdSlash's own Keychain items. Never reads items belonging to other apps or
/// services (Docs/PLANNING.md §34) — this type only knows how to look up entries by the
/// service identifiers CmdSlash itself created.
enum KeychainStore {
    enum KeychainError: Error, LocalizedError {
        case notFound(service: String)
        case unexpectedData
        case osStatus(OSStatus)

        var errorDescription: String? {
            switch self {
            case .notFound(let service):
                "No Keychain item found for service \"\(service)\". Run the setup command from Docs/PLANNING.md §34 first."
            case .unexpectedData:
                "Keychain item exists but its data couldn't be read as a string."
            case .osStatus(let status):
                "Keychain error (status \(status))."
            }
        }
    }

    static func readString(service: String, account: String = NSUserName()) throws -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status != errSecItemNotFound else {
            throw KeychainError.notFound(service: service)
        }
        guard status == errSecSuccess else {
            throw KeychainError.osStatus(status)
        }
        guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
            throw KeychainError.unexpectedData
        }
        return value
    }
}

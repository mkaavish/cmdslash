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
        // A trailing newline from how a credential was originally pasted/typed into `security
        // add-generic-password` is easy to pick up invisibly and corrupts anything that embeds
        // this directly into an HTTP header (e.g. "Bearer <key>\n" is not a valid header value) —
        // trim defensively for every caller rather than relying on each one to remember to.
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Upsert, not insert-only — needed for the Supabase session (§59): its refresh token rotates
    /// on every use (using one invalidates it and issues a replacement), so the stored value has
    /// to be overwritable in place, unlike the static provider API keys this type originally only
    /// ever read.
    static func writeString(_ value: String, service: String, account: String = NSUserName()) throws {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainError.osStatus(addStatus)
            }
        } else if updateStatus != errSecSuccess {
            throw KeychainError.osStatus(updateStatus)
        }
    }
}

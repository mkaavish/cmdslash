import Foundation

/// Blocks CmdSlash's filesystem tools from touching known credential/secret locations
/// (Docs/PLANNING.md §34) — a deny-list check on the resolved path, enforced here at the tool
/// layer regardless of whether the model "knows" not to ask. Not something a tool or a plan can
/// opt out of: this is called before the tool does anything with the path, not left to the
/// model's judgment.
enum SensitivePathGuard {
    struct BlockedPathError: Error, LocalizedError {
        let path: String
        var errorDescription: String? {
            "CmdSlash doesn't read files in this location, for your own security: \(path)"
        }
    }

    private static var blockedDirectories: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            "\(home)/.ssh",
            "\(home)/.aws",
            "\(home)/.gnupg",
            "\(home)/.docker",
            "\(home)/.kube",
            "\(home)/Library/Keychains"
        ].map { $0.lowercased() }
    }

    private static let blockedFilenameSubstrings: [String] = [
        ".env", "id_rsa", "id_ed25519", "id_ecdsa", "id_dsa",
        ".netrc", ".npmrc", ".keychain", ".keychain-db", ".pem", ".p12", ".pfx"
    ]

    /// Resolves `~` and standardizes the path first, so an unexpanded tilde or `..`-style
    /// traversal can't slip past the check.
    static func assertAllowed(_ rawPath: String) throws {
        let expanded = (rawPath as NSString).expandingTildeInPath
        let standardized = (expanded as NSString).standardizingPath.lowercased()

        for directory in blockedDirectories where standardized == directory || standardized.hasPrefix(directory + "/") {
            throw BlockedPathError(path: rawPath)
        }

        let filename = (standardized as NSString).lastPathComponent
        for pattern in blockedFilenameSubstrings where filename.contains(pattern) {
            throw BlockedPathError(path: rawPath)
        }
    }

    static func isBlocked(_ rawPath: String) -> Bool {
        do {
            try assertAllowed(rawPath)
            return false
        } catch {
            return true
        }
    }
}

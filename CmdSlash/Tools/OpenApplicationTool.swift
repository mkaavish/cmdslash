import AppKit

/// The `open_application` tool (Docs/PLANNING.md §21). Uses `NSWorkspace` rather than
/// AX/CGEvent — a structured, top-tier mechanism per the computer-control priority order (§22).
/// Verification is mandatory, not optional: launching without confirming the app actually came
/// up is exactly the kind of silent failure the plan rules out (§36).
struct OpenApplicationTool {
    struct Result {
        let launchedName: String
    }

    enum ToolError: Error, LocalizedError {
        case appNotFound(String)
        case launchFailed(String, underlying: Error)
        case verificationTimedOut(String)

        var errorDescription: String? {
            switch self {
            case .appNotFound(let name):
                "Couldn't find an app named \"\(name)\"."
            case .launchFailed(let name, let underlying):
                "Failed to launch \(name): \(underlying.localizedDescription)"
            case .verificationTimedOut(let name):
                "\(name) didn't appear to launch in time."
            }
        }
    }

    func execute(appName: String) async throws -> Result {
        // NSWorkspace.fullPath(forApplication:) is deprecated but remains the only Cocoa API
        // that resolves a fuzzy display name (not a bundle identifier) to an app path — there is
        // no direct modern replacement for that specific lookup.
        guard let path = NSWorkspace.shared.fullPath(forApplication: appName) else {
            throw ToolError.appNotFound(appName)
        }
        let url = URL(fileURLWithPath: path)

        do {
            _ = try await NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        } catch {
            throw ToolError.launchFailed(appName, underlying: error)
        }

        try await verify(appURL: url, appName: appName)
        return Result(launchedName: appName)
    }

    private func verify(appURL: URL, appName: String) async throws {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if NSWorkspace.shared.runningApplications.contains(where: { $0.bundleURL == appURL }) {
                return
            }
            try await Task.sleep(for: .milliseconds(150))
        }
        throw ToolError.verificationTimedOut(appName)
    }
}

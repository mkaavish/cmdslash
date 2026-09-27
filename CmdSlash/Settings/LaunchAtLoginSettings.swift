import ServiceManagement

/// "Launch CmdSlash at login" — `SMAppService` (macOS 13+) rather than the older, deprecated
/// Login Items plist / `SMLoginItemSetEnabled` approach.
enum LaunchAtLoginSettings {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func setEnabled(_ enabled: Bool) {
        // Best-effort: a failure here (rare — e.g. the system login-items list being
        // unreachable) just leaves isEnabled unchanged rather than surfacing a separate error UI
        // for a preference this low-stakes.
        try? enabled ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
    }
}

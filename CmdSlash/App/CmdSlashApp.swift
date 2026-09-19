import SwiftUI

@main
struct CmdSlashApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // No visible window group — this app has no main window. `Settings` is an otherwise-empty
        // scene that satisfies SwiftUI's `App` protocol without creating one.
        Settings {
            EmptyView()
        }
    }
}

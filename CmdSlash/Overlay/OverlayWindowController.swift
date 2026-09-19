import AppKit
import SwiftUI

/// Owns the overlay panel's lifecycle: pre-warms it at launch, and shows/hides it in response to
/// the global hotkey. Tracks whichever app was frontmost before the overlay appeared so focus can
/// be handed back on dismiss (Docs/PLANNING.md §15).
@MainActor
final class OverlayWindowController {
    private let panel: OverlayPanel
    private var previouslyFrontmostApp: NSRunningApplication?

    init() {
        let width: CGFloat = 560
        let height: CGFloat = 64
        let screenFrame = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let originX = screenFrame.midX - width / 2
        let originY = screenFrame.minY + screenFrame.height * 0.68
        let contentRect = NSRect(x: originX, y: originY, width: width, height: height)

        panel = OverlayPanel(contentRect: contentRect)
        let hosting = NSHostingView(rootView: OverlayView())
        hosting.frame = NSRect(origin: .zero, size: contentRect.size)
        panel.contentView = hosting
        panel.orderOut(nil)
    }

    func toggle() {
        if panel.isVisible {
            hide()
        } else {
            show()
        }
    }

    func show() {
        previouslyFrontmostApp = NSWorkspace.shared.frontmostApplication
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func hide() {
        panel.orderOut(nil)
        previouslyFrontmostApp?.activate()
        previouslyFrontmostApp = nil
    }
}

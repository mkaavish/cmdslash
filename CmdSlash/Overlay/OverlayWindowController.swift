import AppKit
import SwiftUI

/// Owns the overlay panel's lifecycle: pre-warms it at launch, and shows/hides it in response to
/// the global hotkey. Tracks whichever app was frontmost before the overlay appeared so focus can
/// be handed back on dismiss (Docs/PLANNING.md §15). Also owns resizing between the compact and
/// expanded panel heights (§42) — `OverlayView` decides *whether* to expand based on content, this
/// class does the actual AppKit-level resize, anchored to the panel's top edge so it grows
/// downward rather than jumping around the screen.
@MainActor
final class OverlayWindowController {
    private let panel: OverlayPanel
    private let viewModel = OverlayViewModel()
    private var previouslyFrontmostApp: NSRunningApplication?

    private let panelWidth: CGFloat = 560
    private let compactHeight: CGFloat = 88
    private let expandedHeight: CGFloat = 280

    init() {
        let screenFrame = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let originX = screenFrame.midX - panelWidth / 2
        let originY = screenFrame.minY + screenFrame.height * 0.68
        let contentRect = NSRect(x: originX, y: originY, width: panelWidth, height: compactHeight)

        panel = OverlayPanel(contentRect: contentRect)
        let hosting = NSHostingView(rootView: OverlayView(viewModel: viewModel, onExpansionChange: { [weak self] isExpanded in
            self?.setExpanded(isExpanded)
        }))
        hosting.autoresizingMask = [.width, .height]
        hosting.frame = NSRect(origin: .zero, size: contentRect.size)
        panel.contentView = hosting
        panel.orderOut(nil)

        viewModel.onDismissRequested = { [weak self] in
            self?.hide()
        }
        panel.onEscape = { [weak self] in
            self?.viewModel.cancel()
        }
    }

    private func setExpanded(_ expanded: Bool) {
        let newHeight = expanded ? expandedHeight : compactHeight
        guard abs(panel.frame.height - newHeight) > 1 else { return }
        let topY = panel.frame.maxY // anchor the top edge, grow/shrink downward
        let newFrame = NSRect(x: panel.frame.minX, y: topY - newHeight, width: panelWidth, height: newHeight)
        panel.setFrame(newFrame, display: true, animate: true)
    }

    /// Cmd+/'s behavior. NOT a show/hide toggle — while the overlay is already visible, pressing
    /// it again starts a fresh listening turn for a new command rather than closing anything;
    /// Escape (-> cancel() -> hide()) is the only thing that actually dismisses the overlay.
    func toggle() {
        if panel.isVisible {
            viewModel.startNewCommand()
        } else {
            show()
        }
    }

    func show() {
        previouslyFrontmostApp = NSWorkspace.shared.frontmostApplication
        setExpanded(false) // always start compact, regardless of how the previous session ended
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        // Deferred to the next runloop turn so the panel is already key by the time
        // SwiftUI applies the focus change — setting it synchronously here is unreliable.
        DispatchQueue.main.async { [weak self] in
            self?.viewModel.requestFocus()
        }
        viewModel.startVoiceCapture()
    }

    func hide() {
        // Read this before reset() clears it: if the completed action itself changed the
        // frontmost app (launched something, opened a URL/folder, revealed a file), restoring
        // the pre-overlay app here would shove that newly-opened window straight back behind it.
        let shouldRestoreFocus = !viewModel.lastActionActivatedAnotherApp
        panel.orderOut(nil)
        if shouldRestoreFocus {
            previouslyFrontmostApp?.activate()
        }
        previouslyFrontmostApp = nil
        viewModel.reset()
    }
}

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

    private let barWidth: CGFloat = 560
    private let compactHeight: CGFloat = 88
    private let expandedHeight: CGFloat = 280
    /// Meaningfully bigger than the compact/expanded bar — a real time-axis calendar grid needs
    /// real space (§CalendarGridView).
    private let calendarSize = CGSize(width: 680, height: 560)
    /// The compact/expanded bar's fixed position, computed once at launch — returning to
    /// compact/expanded from calendar mode (which repositions the panel entirely, see below) then
    /// snaps back to the bar's usual spot instead of wherever the calendar panel happened to land.
    private let barOriginX: CGFloat
    private let barTopY: CGFloat

    init() {
        let screenFrame = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        barOriginX = screenFrame.midX - barWidth / 2
        let originY = screenFrame.minY + screenFrame.height * 0.68
        barTopY = originY + compactHeight
        let contentRect = NSRect(x: barOriginX, y: originY, width: barWidth, height: compactHeight)

        panel = OverlayPanel(contentRect: contentRect)
        let hosting = NSHostingView(rootView: OverlayView(viewModel: viewModel, onSizeChange: { [weak self] size in
            self?.applySize(size)
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

    private func applySize(_ size: OverlayPanelSize) {
        let newFrame: NSRect
        switch size {
        case .compact, .expanded:
            let newHeight = size == .compact ? compactHeight : expandedHeight
            newFrame = NSRect(x: barOriginX, y: barTopY - newHeight, width: barWidth, height: newHeight)
        case .calendar:
            // Wide/tall enough that anchoring to the bar's usual position (fairly low on screen,
            // §15) would often run it off the bottom edge — center it on the whole screen instead,
            // like a normal window, rather than anchoring to the bar.
            let screenFrame = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            let originX = screenFrame.midX - calendarSize.width / 2
            let originY = screenFrame.midY - calendarSize.height / 2
            newFrame = NSRect(origin: NSPoint(x: originX, y: originY), size: calendarSize)
        }
        guard newFrame != panel.frame else { return }
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
        // Must happen before NSApp.activate() below — after that call, CmdSlash itself is
        // frontmost, and ContextEngine would report "CmdSlash" as the frontmost app instead of
        // whatever the user was actually looking at (Docs/PLANNING.md §18's whole point).
        viewModel.captureScreenContext()
        applySize(.compact) // always start compact, regardless of how the previous session ended
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
        // Read these before reset() clears them. Only skip restoring focus when the session
        // actually completed successfully AND that action changed the frontmost app — not merely
        // because some earlier step in a session that ultimately failed/gave up happened to call
        // browser_navigate. A failed session left with lastActionActivatedAnotherApp still set
        // from an earlier step, if trusted here, would skip restoring focus to the pre-overlay
        // app for no good reason: nothing later confirmed a new app was correctly left frontmost,
        // so CmdSlash itself could end up staying frontmost — which then poisons the Context
        // Engine's next capture (§18) with "CmdSlash" instead of whatever the user was using.
        let sessionSucceeded: Bool
        if case .completed = viewModel.phase { sessionSucceeded = true } else { sessionSucceeded = false }
        let shouldRestoreFocus = !(sessionSucceeded && viewModel.lastActionActivatedAnotherApp)
        panel.orderOut(nil)
        if shouldRestoreFocus {
            previouslyFrontmostApp?.activate()
        }
        previouslyFrontmostApp = nil
        viewModel.reset()
    }
}

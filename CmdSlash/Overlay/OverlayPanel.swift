import AppKit

/// The `cmd/` overlay's window. A borderless, non-activating floating panel — the standard
/// Spotlight/Raycast-style construction — created once at launch and hidden, never torn down,
/// so toggling visibility is not gated on window/view construction (Docs/PLANNING.md §15).
final class OverlayPanel: NSPanel {
    /// Caught at the AppKit level rather than relying on SwiftUI's `.onExitCommand` — that
    /// modifier turned out unreliable in this borderless/non-activating panel depending on which
    /// SwiftUI subview currently has focus. `cancelOperation` is the standard responder-chain
    /// message for Escape and fires regardless of exactly which inner view is first responder.
    var onEscape: (() -> Void)?

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }
}

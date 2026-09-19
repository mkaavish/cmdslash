import Foundation
import Observation

/// Drives the overlay's visible state. `Phase` is a deliberately small stand-in for the real
/// state machine in Docs/PLANNING.md §38 (IDLE/UNDERSTANDING/EXECUTING/VERIFYING/...) — this
/// stub only proves the input → submit → visible-progress → complete plumbing works before any
/// real model call or tool exists behind it.
@Observable
@MainActor
final class OverlayViewModel {
    enum Phase: Equatable {
        case idle
        case executing(step: String)
        case completed(summary: String)
    }

    var inputText: String = ""
    var phase: Phase = .idle
    /// Bumped each time the overlay is shown so the view can re-focus the text field
    /// (see Docs/PLANNING.md §15 — voice/text should be ready the instant the panel appears).
    var focusToken: Int = 0

    var onDismissRequested: (() -> Void)?

    var isBusy: Bool {
        phase != .idle
    }

    func requestFocus() {
        focusToken += 1
    }

    func submit() {
        let trimmed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isBusy else { return }

        phase = .executing(step: "Understanding: \"\(trimmed)\"")

        // TODO(Week 2): replace with real intent classification + tool execution
        // (Docs/PLANNING.md §19-21). This stub only proves the UI plumbing end to end.
        Task {
            try? await Task.sleep(for: .milliseconds(700))
            phase = .completed(summary: "Echo: \(trimmed)")
            try? await Task.sleep(for: .seconds(1.1))
            reset()
            onDismissRequested?()
        }
    }

    func cancel() {
        reset()
        onDismissRequested?()
    }

    func reset() {
        inputText = ""
        phase = .idle
    }
}

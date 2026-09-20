import Foundation
import Observation

/// Drives the overlay's visible state. `Phase` is a deliberately small stand-in for the real
/// state machine in Docs/PLANNING.md §38 (IDLE/UNDERSTANDING/EXECUTING/VERIFYING/...) — enough
/// to run the fast path end to end without building out replanning/permission-gating yet.
@Observable
@MainActor
final class OverlayViewModel {
    enum Phase: Equatable {
        case idle
        case executing(step: String)
        case completed(summary: String)
        case failed(message: String)
    }

    var inputText: String = ""
    var phase: Phase = .idle
    /// Bumped each time the overlay is shown so the view can re-focus the text field
    /// (see Docs/PLANNING.md §15 — voice/text should be ready the instant the panel appears).
    var focusToken: Int = 0

    var onDismissRequested: (() -> Void)?

    var isBusy: Bool {
        switch phase {
        case .idle: false
        case .executing: true
        case .completed, .failed: false // dismissing, not accepting new input
        }
    }

    func requestFocus() {
        focusToken += 1
    }

    func submit() {
        let trimmed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, phase == .idle else { return }

        phase = .executing(step: "Understanding: \"\(trimmed)\"")

        Task {
            await runFastPath(for: trimmed)
            try? await Task.sleep(for: .seconds(1.4))
            reset()
            onDismissRequested?()
        }
    }

    private func runFastPath(for text: String) async {
        do {
            let client = try AnthropicClient()
            guard let call = try await client.classifyFastPathIntent(text) else {
                phase = .failed(message: "Not sure how to do that yet")
                return
            }

            switch call.name {
            case "open_application":
                guard let name = call.input["name"] as? String else {
                    phase = .failed(message: "Model returned a malformed open_application call")
                    return
                }
                phase = .executing(step: "Opening \(name)...")
                let result = try await OpenApplicationTool().execute(appName: name)
                phase = .completed(summary: "Opened \(result.launchedName)")

            case "open_url":
                guard let urlString = call.input["url"] as? String else {
                    phase = .failed(message: "Model returned a malformed open_url call")
                    return
                }
                phase = .executing(step: "Opening \(urlString)...")
                let url = try OpenURLTool().execute(urlString: urlString)
                phase = .completed(summary: "Opened \(url.absoluteString)")

            default:
                phase = .failed(message: "Unknown tool: \(call.name)")
            }
        } catch {
            phase = .failed(message: error.localizedDescription)
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

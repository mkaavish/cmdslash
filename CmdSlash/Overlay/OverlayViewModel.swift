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
    var isListening: Bool = false
    /// Bumped each time the overlay is shown so the view can re-focus the text field
    /// (see Docs/PLANNING.md §15 — voice/text should be ready the instant the panel appears).
    var focusToken: Int = 0

    var onDismissRequested: (() -> Void)?

    private let speechRecognizer = SpeechRecognizer()
    /// True only while `inputText` is being set from a speech transcript, so the view can tell a
    /// speech-driven update apart from the user actually typing (Docs/PLANNING.md §6: typing
    /// silently discards voice capture).
    private(set) var isApplyingSpeechUpdate = false
    private var silenceTask: Task<Void, Never>?

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

    /// Called when the overlay becomes visible — voice starts immediately per Docs/PLANNING.md §6
    /// ("press Cmd+/ and immediately begin listening"), no separate mode switch.
    func startVoiceCapture() {
        speechRecognizer.onPartialTranscript = { [weak self] transcript in
            self?.applySpeechTranscript(transcript)
        }
        speechRecognizer.onError = { [weak self] _ in
            self?.isListening = false
        }

        Task {
            guard await SpeechRecognizer.requestAuthorization() else { return }
            guard phase == .idle, inputText.isEmpty else { return } // overlay may have closed already
            do {
                isListening = true
                try speechRecognizer.startListening()
            } catch {
                isListening = false
            }
        }
    }

    func stopVoiceCapture() {
        speechRecognizer.stopListening()
        isListening = false
        silenceTask?.cancel()
        silenceTask = nil
    }

    /// Called by the view when `inputText` changes for a reason other than
    /// `applySpeechTranscript` below — i.e. the user actually typed. Voice yields immediately.
    func userDidType() {
        guard isListening else { return }
        stopVoiceCapture()
    }

    private func applySpeechTranscript(_ transcript: String) {
        isApplyingSpeechUpdate = true
        inputText = transcript
        DispatchQueue.main.async { [weak self] in
            self?.isApplyingSpeechUpdate = false
        }

        // Trailing-silence auto-submit (Docs/PLANNING.md §17): each new partial result resets
        // the timer, so submission only fires ~700ms after speech actually stops.
        silenceTask?.cancel()
        silenceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            guard let self, !Task.isCancelled else { return }
            guard self.phase == .idle, !self.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            self.submit()
        }
    }

    func submit() {
        let trimmed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, phase == .idle else { return }

        stopVoiceCapture()
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
        stopVoiceCapture()
        inputText = ""
        phase = .idle
    }
}

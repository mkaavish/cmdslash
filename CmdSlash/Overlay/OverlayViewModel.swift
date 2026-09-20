import Foundation
import Observation

/// Drives the overlay's visible state. `Phase` is a deliberately small stand-in for the real
/// state machine in Docs/PLANNING.md §38 (IDLE/UNDERSTANDING/EXECUTING/VERIFYING/...) — enough
/// to run the fast path end to end, including a real medium-risk confirmation gate (§30), without
/// building out full replanning yet.
@Observable
@MainActor
final class OverlayViewModel {
    enum Phase: Equatable {
        case idle
        case executing(step: String)
        case awaitingConfirmation(summary: String)
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
    /// The in-flight fast-path task, if any. Cancel must genuinely interrupt this, not just hide
    /// the panel (Docs/PLANNING.md §37, §38) — a tool call left running after the user cancels is
    /// exactly the silent-failure-adjacent behavior the plan rules out.
    private var runningTask: Task<Void, Never>?
    /// Set while `phase` is `.awaitingConfirmation`. Must always be resumed exactly once — an
    /// unresumed continuation would leave `runningTask` permanently suspended, not just cancelled.
    private var confirmationContinuation: CheckedContinuation<Bool, Never>?
    /// True when the just-completed action itself changed the frontmost app (launched an app,
    /// opened a URL/folder, revealed a file in Finder). `OverlayWindowController.hide()` reads
    /// this to decide whether restoring focus to the pre-overlay app is correct — for these
    /// actions it isn't: the whole point was to bring something else to the front, and
    /// unconditionally restoring the old frontmost app was shoving the newly-opened window
    /// straight back behind it.
    private(set) var lastActionActivatedAnotherApp = false

    /// Only `.executing` disables the text field. `.awaitingConfirmation` deliberately leaves it
    /// enabled so the TextField's own `onSubmit` keeps routing Enter through — disabling it risks
    /// Enter silently not firing at all while a confirmation is pending.
    var isBusy: Bool {
        switch phase {
        case .idle, .awaitingConfirmation: false
        case .executing: true
        case .completed, .failed: false // dismissing, not accepting new input
        }
    }

    func requestFocus() {
        focusToken += 1
    }

    /// Cmd+/ pressed while the overlay is already visible — restarts listening for a new command
    /// rather than closing (Escape is the dedicated close action). Ignored mid-action: re-pressing
    /// the hotkey shouldn't silently interrupt an in-flight tool call or a pending confirmation.
    func startNewCommand() {
        switch phase {
        case .idle, .completed, .failed:
            phase = .idle
            inputText = ""
            requestFocus()
            startVoiceCapture()
        case .executing, .awaitingConfirmation:
            break
        }
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
        if isListening {
            stopVoiceCapture()
        }
        // Typing over a finished result starts a fresh command rather than being silently
        // ignored (submit() only accepts phase == .idle) — the panel stays open after
        // completion now, so this is how a second command gets going without dismissing first.
        switch phase {
        case .completed, .failed:
            phase = .idle
        case .idle, .executing, .awaitingConfirmation:
            break
        }
    }

    private func applySpeechTranscript(_ transcript: String) {
        isApplyingSpeechUpdate = true
        inputText = transcript
        DispatchQueue.main.async { [weak self] in
            self?.isApplyingSpeechUpdate = false
        }

        // Trailing-silence auto-submit (Docs/PLANNING.md §17): each new partial result resets
        // the timer, so submission only fires after speech actually stops for this long. 700ms
        // (the plan's initial suggestion) cut people off mid-thought on a breath or an "umm" —
        // 2s is more forgiving for longer commands. Enter still submits immediately regardless,
        // for anyone who wants to skip the wait once they're done talking.
        silenceTask?.cancel()
        silenceTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
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
        lastActionActivatedAnotherApp = false

        // No auto-dismiss: the panel now stays open showing the result until the user explicitly
        // dismisses (Escape) or toggles it (Cmd+/ again) — it was closing on its own before,
        // which nobody asked it to do.
        runningTask = Task {
            await runFastPath(for: trimmed)
            guard !Task.isCancelled else { return }
            inputText = ""
            // The text field was disabled (and lost keyboard focus) during .executing — without
            // this, Enter/Escape land nowhere until the user clicks back into the field manually.
            requestFocus()
        }
    }

    /// Suspends until the user confirms or denies (via `confirmPendingAction()` or `cancel()`).
    private func requireConfirmation(summary: String) async -> Bool {
        phase = .awaitingConfirmation(summary: summary)
        // Same reasoning as above: re-focus now that the field is interactive again, so Enter
        // (confirm) and Escape (deny) work immediately without a click first.
        requestFocus()
        return await withCheckedContinuation { continuation in
            confirmationContinuation = continuation
        }
    }

    /// Enter, while `phase == .awaitingConfirmation`.
    func confirmPendingAction() {
        confirmationContinuation?.resume(returning: true)
        confirmationContinuation = nil
    }

    private func confirmationSummary(for call: AnthropicClient.ToolCall) -> String? {
        switch call.name {
        case "create_calendar_event":
            guard let title = call.input["title"] as? String else { return nil }
            let startDisplay = (call.input["start"] as? String).flatMap(Self.friendlyDate) ?? "unknown time"
            return "Create \"\(title)\" at \(startDisplay)?"
        case "delete_calendar_event":
            guard let title = call.input["title"] as? String else { return nil }
            return "Delete event matching \"\(title)\"? This can't be undone."
        default:
            return "Proceed with \(call.name)?"
        }
    }

    private static func friendlyDate(_ iso8601: String) -> String? {
        guard let date = ISO8601DateFormatter().date(from: iso8601) else { return nil }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private func runFastPath(for text: String) async {
        // No AccessibilityPermission.requestIfNeeded() here — nothing in the fast path actually
        // consumes window title/selected text yet (ContextEngine degrades gracefully without the
        // grant), so prompting for it on every command was asking for a permission before there
        // was a real task that needed it. Request it at the point something genuinely depends on
        // that data instead.
        let context = ContextEngine.captureSnapshot()
        ContextEngine.logForDebugging(context)

        do {
            let client = try AnthropicClient()
            guard let call = try await client.classifyFastPathIntent(text, context: context) else {
                phase = .failed(message: "Not sure how to do that yet")
                return
            }
            try Task.checkCancellation()

            // Docs/PLANNING.md §30: risk is classified centrally, not by the tool itself, and
            // medium/high-risk actions require explicit confirmation before executing.
            if RiskClassifier.riskLevel(forTool: call.name) != .low {
                guard let summary = confirmationSummary(for: call) else {
                    phase = .failed(message: "Model returned a malformed \(call.name) call")
                    return
                }
                let approved = await requireConfirmation(summary: summary)
                guard !Task.isCancelled else { return }
                guard approved else {
                    phase = .failed(message: "Cancelled")
                    return
                }
            }

            switch call.name {
            case "open_application":
                guard let name = call.input["name"] as? String else {
                    phase = .failed(message: "Model returned a malformed open_application call")
                    return
                }
                phase = .executing(step: "Opening \(name)...")
                let result = try await OpenApplicationTool().execute(appName: name)
                try Task.checkCancellation()
                lastActionActivatedAnotherApp = true
                phase = .completed(summary: "Opened \(result.launchedName)")

            case "open_url":
                guard let urlString = call.input["url"] as? String else {
                    phase = .failed(message: "Model returned a malformed open_url call")
                    return
                }
                phase = .executing(step: "Opening \(urlString)...")
                let url = try OpenURLTool().execute(urlString: urlString)
                try Task.checkCancellation()
                lastActionActivatedAnotherApp = true
                phase = .completed(summary: "Opened \(url.absoluteString)")

            case "open_folder":
                guard let name = call.input["name"] as? String else {
                    phase = .failed(message: "Model returned a malformed open_folder call")
                    return
                }
                phase = .executing(step: "Opening \(name) folder...")
                let url = try OpenFolderTool().execute(name: name)
                try Task.checkCancellation()
                lastActionActivatedAnotherApp = true
                phase = .completed(summary: "Opened \(url.lastPathComponent)")

            case "find_file":
                guard let query = call.input["query"] as? String else {
                    phase = .failed(message: "Model returned a malformed find_file call")
                    return
                }
                let kind = call.input["kind"] as? String
                phase = .executing(step: "Searching for \(query)...")
                let matches = try await FindFileTool().execute(query: query, kind: kind)
                try Task.checkCancellation()
                if let top = matches.first {
                    let suffix = matches.count > 1 ? " (+\(matches.count - 1) more)" : ""
                    lastActionActivatedAnotherApp = true // revealed in Finder
                    phase = .completed(summary: "Found \(top.name)\(suffix)")
                }

            case "read_file":
                guard let path = call.input["path"] as? String else {
                    phase = .failed(message: "Model returned a malformed read_file call")
                    return
                }
                phase = .executing(step: "Reading \(path)...")
                let result = try ReadFileTool().execute(path: path)
                try Task.checkCancellation()
                phase = .completed(summary: "Read \(result.content.count) characters from \(result.fileName)")

            case "create_calendar_event":
                guard
                    let title = call.input["title"] as? String,
                    let startString = call.input["start"] as? String,
                    let endString = call.input["end"] as? String,
                    let start = ISO8601DateFormatter().date(from: startString),
                    let end = ISO8601DateFormatter().date(from: endString)
                else {
                    phase = .failed(message: "Model returned a malformed create_calendar_event call")
                    return
                }
                let notes = call.input["notes"] as? String

                phase = .executing(step: "Requesting Calendar access...")
                guard await CalendarAccess.requestFullAccess() else {
                    phase = .failed(message: "Calendar access wasn't granted")
                    return
                }
                try Task.checkCancellation()

                phase = .executing(step: "Creating \"\(title)\"...")
                let result = try CreateCalendarEventTool().execute(title: title, start: start, end: end, notes: notes)
                try Task.checkCancellation()
                phase = .completed(summary: "Created \"\(result.title)\"")

            case "delete_calendar_event":
                guard let titleQuery = call.input["title"] as? String else {
                    phase = .failed(message: "Model returned a malformed delete_calendar_event call")
                    return
                }

                phase = .executing(step: "Requesting Calendar access...")
                guard await CalendarAccess.requestFullAccess() else {
                    phase = .failed(message: "Calendar access wasn't granted")
                    return
                }
                try Task.checkCancellation()

                phase = .executing(step: "Deleting \"\(titleQuery)\"...")
                let result = try DeleteCalendarEventTool().execute(titleQuery: titleQuery)
                try Task.checkCancellation()
                phase = .completed(summary: "Deleted \"\(result.deletedTitle)\"")

            default:
                phase = .failed(message: "Unknown tool: \(call.name)")
            }
        } catch {
            // A cancelled task can throw any error shape depending on where it was interrupted
            // (CancellationError, URLError(.cancelled), ...) — Task.isCancelled is the reliable
            // signal, not the error's concrete type. cancel() already reset the UI in that case.
            guard !Task.isCancelled else { return }
            phase = .failed(message: error.localizedDescription)
        }
    }

    func cancel() {
        confirmationContinuation?.resume(returning: false)
        confirmationContinuation = nil
        runningTask?.cancel()
        runningTask = nil
        // reset() is NOT called here — onDismissRequested() below routes to
        // OverlayWindowController.hide(), which must read lastActionActivatedAnotherApp before
        // reset() clears it, so hide() owns calling reset() itself.
        onDismissRequested?()
    }

    func reset() {
        stopVoiceCapture()
        inputText = ""
        phase = .idle
        lastActionActivatedAnotherApp = false
    }
}

import Foundation
import Observation
import os

/// Drives the overlay's visible state. `Phase` is a deliberately small stand-in for the real
/// state machine in Docs/PLANNING.md §38 (IDLE/UNDERSTANDING/EXECUTING/VERIFYING/...) — enough to
/// run both the single-shot fast path (§28) and a real multi-step agentic loop (§29) end to end,
/// including a real medium/high-risk confirmation gate (§30) shared by both.
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

    private static let logger = Logger(subsystem: "com.cmdslash.CmdSlash", category: "OverlayViewModel")

    var inputText: String = ""
    var phase: Phase = .idle {
        didSet {
            // .notice, not .debug — persisted by default (log show), so a failure that flashes
            // by on screen before the user can read it is still diagnosable afterward.
            if case .failed(let message) = phase {
                Self.logger.notice("phase failed: \(message, privacy: .public)")
            }
        }
    }
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

        // No auto-dismiss: the panel stays open showing the result until the user explicitly
        // dismisses (Escape) or restarts (Cmd+/ again).
        runningTask = Task {
            await route(text: trimmed)
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
            let title = call.input["title"] as? String
            let aroundDisplay = (call.input["around_time"] as? String).flatMap(Self.friendlyDate)
            switch (title, aroundDisplay) {
            case let (.some(title), .some(time)):
                return "Delete \"\(title)\" around \(time)? This can't be undone."
            case let (.some(title), nil):
                return "Delete event matching \"\(title)\"? This can't be undone."
            case let (nil, .some(time)):
                return "Delete the event around \(time)? This can't be undone."
            case (nil, nil):
                return nil
            }
        case "run_coding_agent":
            guard let task = call.input["task"] as? String, let repoPath = call.input["repo_path"] as? String else { return nil }
            return "Let Claude Code work on \"\(task)\" in \(repoPath)? It will read and modify files there."
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

    // MARK: - Routing (Docs/PLANNING.md §27-29)

    /// Classifies once via the fast path; a plain tool call runs immediately, `plan_multi_step`
    /// hands off to the agentic loop, and anything else shows the model's own explanation.
    private func route(text: String) async {
        let context = ContextEngine.captureSnapshot()
        ContextEngine.logForDebugging(context)

        let classification: AnthropicClient.ClassificationResult
        do {
            let client = try AnthropicClient()
            classification = try await client.classifyFastPathIntent(text, context: context)
        } catch {
            guard !Task.isCancelled else { return }
            phase = .failed(message: error.localizedDescription)
            return
        }
        guard !Task.isCancelled else { return }

        switch classification {
        case .explanation(let message):
            phase = .failed(message: message)
        case .toolCall(let call) where call.name == "plan_multi_step":
            let goal = (call.input["goal"] as? String) ?? text
            await runAgenticPath(goal: goal, context: context)
        case .toolCall(let call):
            await runSingleTool(call)
        }
    }

    /// The fast path (§28): one tool call, confirmed if risky, executed, done.
    private func runSingleTool(_ call: AnthropicClient.ToolCall) async {
        do {
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

            let outcome = try await executeTool(call)
            guard !Task.isCancelled else { return }
            phase = .completed(summary: outcome.uiSummary)
        } catch {
            guard !Task.isCancelled else { return }
            phase = .failed(message: error.localizedDescription)
        }
    }

    /// The agentic path (§20, §29): a real multi-turn loop — call a tool, observe the result,
    /// decide the next step or finish — rather than an upfront plan. Each risky step is still
    /// confirmed individually, same as the fast path. Capped at maxSteps so a confused loop fails
    /// loudly instead of running forever.
    private func runAgenticPath(goal: String, context: ContextSnapshot) async {
        var messages: [[String: Any]] = [["role": "user", "content": goal]]
        let maxSteps = 6

        for _ in 1...maxSteps {
            let turn: AnthropicClient.AgenticTurn
            do {
                let client = try AnthropicClient()
                turn = try await client.sendAgenticTurn(messages: messages, context: context)
            } catch {
                guard !Task.isCancelled else { return }
                phase = .failed(message: error.localizedDescription)
                return
            }
            guard !Task.isCancelled else { return }

            messages.append(["role": "assistant", "content": turn.assistantContent])

            guard let toolUse = turn.toolUse, let toolUseID = turn.toolUseID else {
                phase = .completed(summary: turn.finalText ?? "Done")
                return
            }

            if RiskClassifier.riskLevel(forTool: toolUse.name) != .low {
                guard let summary = confirmationSummary(for: toolUse) else {
                    phase = .failed(message: "Model returned a malformed \(toolUse.name) call")
                    return
                }
                let approved = await requireConfirmation(summary: summary)
                guard !Task.isCancelled else { return }
                guard approved else {
                    phase = .failed(message: "Cancelled")
                    return
                }
            }

            do {
                let outcome = try await executeTool(toolUse)
                guard !Task.isCancelled else { return }
                messages.append([
                    "role": "user",
                    "content": [["type": "tool_result", "tool_use_id": toolUseID, "content": outcome.modelFacingContent]]
                ])
            } catch {
                guard !Task.isCancelled else { return }
                // Fed back to the model as a tool_result rather than failing outright — real
                // replanning (§37): the model gets to decide whether to try something else or
                // explain to the user why it can't proceed, instead of the loop just giving up.
                messages.append([
                    "role": "user",
                    "content": [[
                        "type": "tool_result",
                        "tool_use_id": toolUseID,
                        "content": "Error: \(error.localizedDescription)",
                        "is_error": true
                    ]]
                ])
            }
        }

        phase = .failed(message: "Gave up after \(maxSteps) steps without finishing")
    }

    // MARK: - Tool dispatch (shared by both paths above)

    private func executeTool(_ call: AnthropicClient.ToolCall) async throws -> ToolExecutionOutcome {
        switch call.name {
        case "open_application":
            guard let name = call.input["name"] as? String else {
                throw MalformedToolCallError(tool: call.name)
            }
            phase = .executing(step: "Opening \(name)...")
            let result = try await OpenApplicationTool().execute(appName: name)
            lastActionActivatedAnotherApp = true
            let summary = "Opened \(result.launchedName)"
            return ToolExecutionOutcome(modelFacingContent: summary, uiSummary: summary)

        case "open_url":
            guard let urlString = call.input["url"] as? String else {
                throw MalformedToolCallError(tool: call.name)
            }
            phase = .executing(step: "Opening \(urlString)...")
            let url = try OpenURLTool().execute(urlString: urlString)
            lastActionActivatedAnotherApp = true
            let summary = "Opened \(url.absoluteString)"
            return ToolExecutionOutcome(modelFacingContent: summary, uiSummary: summary)

        case "open_folder":
            guard let name = call.input["name"] as? String else {
                throw MalformedToolCallError(tool: call.name)
            }
            phase = .executing(step: "Opening \(name) folder...")
            let url = try OpenFolderTool().execute(name: name)
            lastActionActivatedAnotherApp = true
            let summary = "Opened \(url.lastPathComponent)"
            return ToolExecutionOutcome(modelFacingContent: summary, uiSummary: summary)

        case "find_file":
            guard let query = call.input["query"] as? String else {
                throw MalformedToolCallError(tool: call.name)
            }
            let kind = call.input["kind"] as? String
            phase = .executing(step: "Searching for \(query)...")
            let matches = try await FindFileTool().execute(query: query, kind: kind)
            lastActionActivatedAnotherApp = true // revealed in Finder
            guard let top = matches.first else {
                throw FindFileTool.ToolError.noMatches(query)
            }
            let suffix = matches.count > 1 ? " (+\(matches.count - 1) more)" : ""
            let modifiedDisplay = top.modifiedAt.map { " (modified \(Self.friendlyDateValue($0)))" } ?? ""
            return ToolExecutionOutcome(
                modelFacingContent: "Found \(matches.count) matching file(s). Best match: \(top.name) at \(top.path)\(modifiedDisplay).",
                uiSummary: "Found \(top.name)\(suffix)"
            )

        case "read_file":
            guard let path = call.input["path"] as? String else {
                throw MalformedToolCallError(tool: call.name)
            }
            phase = .executing(step: "Reading \(path)...")
            let result = try ReadFileTool().execute(path: path)
            return ToolExecutionOutcome(
                modelFacingContent: "Contents of \(result.fileName)\(result.truncated ? " (truncated)" : ""):\n\n\(result.content)",
                uiSummary: "Read \(result.content.count) characters from \(result.fileName)"
            )

        case "create_calendar_event":
            guard
                let title = call.input["title"] as? String,
                let startString = call.input["start"] as? String,
                let endString = call.input["end"] as? String,
                let start = ISO8601DateFormatter().date(from: startString),
                let end = ISO8601DateFormatter().date(from: endString)
            else {
                throw MalformedToolCallError(tool: call.name)
            }
            let notes = call.input["notes"] as? String

            phase = .executing(step: "Requesting Calendar access...")
            guard await CalendarAccess.requestFullAccess() else {
                throw CalendarAccessDeniedError()
            }

            phase = .executing(step: "Creating \"\(title)\"...")
            let result = try CreateCalendarEventTool().execute(title: title, start: start, end: end, notes: notes)
            let summary = "Created \"\(result.title)\""
            return ToolExecutionOutcome(modelFacingContent: summary, uiSummary: summary)

        case "delete_calendar_event":
            let titleQuery = call.input["title"] as? String
            let aroundTime = (call.input["around_time"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
            guard titleQuery?.isEmpty == false || aroundTime != nil else {
                throw MalformedToolCallError(tool: call.name)
            }

            phase = .executing(step: "Requesting Calendar access...")
            guard await CalendarAccess.requestFullAccess() else {
                throw CalendarAccessDeniedError()
            }

            phase = .executing(step: "Deleting event...")
            let result = try DeleteCalendarEventTool().execute(titleQuery: titleQuery, aroundTime: aroundTime)
            let summary = "Deleted \"\(result.deletedTitle)\""
            return ToolExecutionOutcome(modelFacingContent: summary, uiSummary: summary)

        case "run_coding_agent":
            guard
                let task = call.input["task"] as? String,
                let repoPath = call.input["repo_path"] as? String
            else {
                throw MalformedToolCallError(tool: call.name)
            }
            phase = .executing(step: "Running Claude Code in \(repoPath)...")
            let result = try await CodingAgentTool().execute(task: task, repoPath: repoPath)
            let repoName = URL(fileURLWithPath: result.repoPath).lastPathComponent
            let changeNote = result.gitChangeSummary.map { "\n\nChanges:\n\($0)" } ?? "\n\n(No git changes detected.)"
            return ToolExecutionOutcome(
                modelFacingContent: "Claude Code finished in \(repoName).\n\nOutput:\n\(result.output)\(changeNote)",
                uiSummary: result.gitChangeSummary != nil ? "Claude Code made changes in \(repoName)" : "Claude Code ran but made no changes in \(repoName)"
            )

        default:
            throw UnknownToolError(tool: call.name)
        }
    }

    private static func friendlyDateValue(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
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

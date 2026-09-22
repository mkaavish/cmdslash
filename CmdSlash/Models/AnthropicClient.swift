import Foundation
import os

/// Minimal Anthropic Messages API client. Two request shapes share the same 7 action tools
/// (Docs/PLANNING.md §21): a single-shot fast-path classification (§26-28, Haiku) and a real
/// multi-turn agentic loop (§20, §29, Sonnet) for requests that need more than one tool chained
/// together. Non-streaming for now — streaming (§40) is a later upgrade to the same request
/// shape, not an architecture change.
struct AnthropicClient {
    struct ToolCall {
        let name: String
        let input: [String: Any]
    }

    /// Either the model picked a tool, or it's telling the caller why it couldn't — that
    /// explanation is worth showing the user directly instead of a generic fallback message.
    enum ClassificationResult {
        case toolCall(ToolCall)
        case explanation(String)
    }

    /// One turn of the agentic loop: either a tool call to execute and feed back, or — when
    /// `toolUse` is nil — the model judged the goal accomplished and `finalText` is its answer.
    struct AgenticTurn {
        let assistantContent: [[String: Any]]
        let toolUse: ToolCall?
        let toolUseID: String?
        let finalText: String?
    }

    enum ClientError: Error, LocalizedError {
        case httpError(Int, String)
        case invalidResponse

        var errorDescription: String? {
            switch self {
            case .httpError(let code, let body):
                "Anthropic API returned \(code): \(body.prefix(300))"
            case .invalidResponse:
                "Couldn't parse the Anthropic API response."
            }
        }
    }

    private static let logger = Logger(subsystem: "com.cmdslash.CmdSlash", category: "AnthropicClient")

    private let apiKey: String
    private let fastModel: String
    private let reasoningModel: String
    /// Only needed for API keys that aren't scoped to a single workspace (org-level/admin keys) —
    /// Anthropic then requires the workspace to use explicitly. Not a secret, so it lives in
    /// UserDefaults rather than the Keychain (see Docs/PLANNING.md §34 for what does need Keychain).
    private let workspaceID: String?

    init(fastModel: String = "claude-haiku-4-5-20251001", reasoningModel: String = "claude-sonnet-5") throws {
        self.apiKey = try KeychainStore.readString(service: "com.cmdslash.apikeys.anthropic")
        self.fastModel = fastModel
        self.reasoningModel = reasoningModel
        self.workspaceID = UserDefaults.standard.string(forKey: "AnthropicWorkspaceID")
    }

    private static func currentDateTimeDescription() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = .current
        formatter.formatOptions = [.withInternetDateTime]
        return "\(formatter.string(from: Date())) (\(TimeZone.current.identifier))"
    }

    /// Not private: OverlayViewModel also uses this to decide whether an open_url call should
    /// update the frontmost browser's current tab (via the extension bridge) instead of opening a
    /// new one, when the user is already looking at a browser.
    static let knownBrowserAppNames: Set<String> = [
        "Google Chrome", "Safari", "Microsoft Edge", "Brave Browser", "Arc", "Firefox"
    ]

    /// The Context Engine (§18) captures the frontmost app but on its own that's just a fact —
    /// nothing told the model what to *do* with it, so requests about content ("summarize this",
    /// "how much does it cost", "what's the latest blog post") with a browser frontmost still
    /// triggered a clarifying question instead of defaulting to the current website. This appends
    /// that missing instruction whenever a known browser is frontmost — and phrases the remaining
    /// fallback narrowly (current site vs. something else) rather than an open-ended question,
    /// since a scoped yes/no is faster to answer by voice or text than free-form clarification.
    private static func implicitScreenContextInstruction(for context: ContextSnapshot) -> String? {
        guard let appName = context.frontmostAppName, knownBrowserAppNames.contains(appName) else {
            return nil
        }
        return """
        The user is currently looking at a webpage in \(appName). Default to assuming any request \
        about content, information, or "the latest X" relates to the website currently open — not \
        just when it says "this"/"it", but whenever no other subject is explicitly named. This \
        includes things that might be on a DIFFERENT page of the SAME site (e.g. "how much does \
        it cost" when pricing isn't on the current page, "what's the latest blog post" when the \
        current page isn't a blog) — call plan_multi_step and let the agentic loop explore the \
        site via its extracted links rather than asking for clarification. Only ask for \
        clarification if the request is genuinely unrelated to reading content at all, or \
        explicitly names a different app, file, or website — and when you do, phrase it narrowly \
        as: are they asking about the current page/site (name it), or something else (in which \
        case ask them to say what)? Not an open-ended "what do you mean".
        """
    }

    /// Companion to `implicitScreenContextInstruction` for when the frontmost app is NOT a
    /// browser — points the agentic loop at read_screen_content (the AX-tree tier, §18) as the
    /// way to actually see what's on screen in a native app, instead of guessing from the window
    /// title alone or asking the user to describe it themselves.
    private static func nonBrowserScreenContextInstruction(for context: ContextSnapshot) -> String? {
        guard let appName = context.frontmostAppName, !knownBrowserAppNames.contains(appName) else {
            return nil
        }
        return """
        The user is currently in \(appName), not a browser. If the request is about content or \
        state currently visible there (e.g. "what does this say", "reply to this", "what's in \
        this list"), call read_screen_content first to see the window's actual UI content before \
        answering or asking for clarification — don't guess from the window title alone, and \
        don't ask the user to describe what's on screen when you can just read it yourself.
        """
    }

    /// The 7 real action tools, shared between the fast-path classifier and the agentic loop so
    /// their definitions never drift apart.
    private static func actionToolDefinitions() -> [[String: Any]] {
        [
            [
                "name": "open_application",
                "description": "Launch a native macOS application by its display name.",
                "input_schema": [
                    "type": "object",
                    "properties": [
                        "name": [
                            "type": "string",
                            "description": "The application's display name, e.g. \"Spotify\"."
                        ]
                    ],
                    "required": ["name"]
                ]
            ],
            [
                "name": "open_url",
                "description": "Open a URL in the default web browser. If the request is to find/see/watch/listen-to something ON a well-known site or streaming platform (e.g. \"FIFA highlights on YouTube\", \"resume templates on Google\", \"some Kanye on Apple Music\", \"Kanye on Spotify\"), don't just launch that platform's bare app/homepage with open_application — construct its real search-results URL with the query embedded and open THAT with open_url instead, e.g. https://www.youtube.com/results?search_query=FIFA+highlights, https://www.google.com/search?q=resume+templates, https://music.apple.com/search?term=Kanye, or https://open.spotify.com/search/Kanye. For an installed native app (Music.app, Spotify), macOS opening that URL deep-links straight into the app's own search results, same as it would in a browser tab — so this works even when the request implies \"the app\", not literally \"the website\". Also use this (not open_application) for a request to open a SPECIFIC macOS System Settings pane (e.g. \"open accessibility settings\", \"open Wi-Fi settings\") — open_application's \"System Settings\" just launches the app to whatever pane it last had open, not the one asked for. Use the x-apple.systempreferences: URL scheme, e.g. x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility for Accessibility. If you're confident of the identifier for the pane asked about, construct it the same way; if not, it's fine to fall back to open_application with \"System Settings\" rather than guessing.",
                "input_schema": [
                    "type": "object",
                    "properties": [
                        "url": [
                            "type": "string",
                            "description": "A fully-qualified URL, e.g. \"https://youtube.com\"."
                        ],
                        "new_window": [
                            "type": "boolean",
                            "description": "True only if the user explicitly asked for a new/separate window (not just a new tab). Leave false for an ordinary \"open X\" request — the default behavior already reuses the current browser tab when there is one, which is what most requests want."
                        ]
                    ],
                    "required": ["url"]
                ]
            ],
            [
                "name": "open_folder",
                "description": "Open a folder in Finder — either a well-known one (Downloads, Desktop, Documents, Movies, Music, Pictures, Applications, home) or a named folder directly inside the user's home directory.",
                "input_schema": [
                    "type": "object",
                    "properties": [
                        "name": [
                            "type": "string",
                            "description": "The folder's name, e.g. \"Downloads\" or \"home\"."
                        ]
                    ],
                    "required": ["name"]
                ]
            ],
            [
                "name": "find_file",
                "description": "Search for a file by name using Spotlight and reveal the best match in Finder. Matches are ranked most-recently-modified first, so this is the right tool for things like \"find the PDF I downloaded yesterday\". Returns the matched file's path, which read_file can then use.",
                "input_schema": [
                    "type": "object",
                    "properties": [
                        "query": [
                            "type": "string",
                            "description": "A keyword or partial filename to search for, e.g. \"invoice\" or \"resume\"."
                        ],
                        "kind": [
                            "type": "string",
                            "description": "Optional file kind filter, e.g. \"pdf\" or \"image\"."
                        ]
                    ],
                    "required": ["query"]
                ]
            ],
            [
                "name": "read_file",
                "description": "Read the text content of a file (plain text, code, or PDF) at a known path — use this to get a file's actual content, e.g. before summarizing or explaining it.",
                "input_schema": [
                    "type": "object",
                    "properties": [
                        "path": [
                            "type": "string",
                            "description": "A file path, e.g. \"~/Downloads/invoice.pdf\"."
                        ]
                    ],
                    "required": ["path"]
                ]
            ],
            [
                "name": "create_calendar_event",
                "description": "Create a calendar event. Resolve any relative dates/times (\"tomorrow\", \"next Friday at 3\") to absolute ISO 8601 timestamps using the current date/time given in context.",
                "input_schema": [
                    "type": "object",
                    "properties": [
                        "title": ["type": "string", "description": "The event's title."],
                        "start": ["type": "string", "description": "ISO 8601 start timestamp, e.g. 2026-09-21T15:00:00-07:00."],
                        "end": ["type": "string", "description": "ISO 8601 end timestamp."],
                        "notes": ["type": "string", "description": "Optional event description."]
                    ],
                    "required": ["title", "start", "end"]
                ]
            ],
            [
                "name": "delete_calendar_event",
                "description": "Delete a calendar event, identified by title and/or by roughly when it's scheduled. Resolve relative time references (\"5pm today\", \"tomorrow morning\") to an absolute ISO 8601 timestamp using the current date/time given in context. Provide at least one of title or around_time — both if the user gave both. Only deletes if exactly one matching event is found within roughly the last/next two months — if multiple or none match, it reports that instead of guessing.",
                "input_schema": [
                    "type": "object",
                    "properties": [
                        "title": ["type": "string", "description": "The event's title, or a distinctive substring of it. Optional if around_time is enough to identify it."],
                        "around_time": ["type": "string", "description": "ISO 8601 timestamp near when the event is scheduled, e.g. 2026-09-21T17:00:00-05:00. Optional if title is enough to identify it."]
                    ],
                    "required": []
                ]
            ],
            [
                "name": "list_calendar_events",
                "description": "List calendar events in a date range — e.g. \"what's on my calendar today\", \"do I have anything tomorrow\", \"show me this week's events\". Resolve a relative range (\"today\", \"tomorrow\", \"this week\", \"next Monday\") to absolute ISO 8601 start/end timestamps using the current date/time given in context. If the request doesn't name a range at all, omit both and it defaults to today.",
                "input_schema": [
                    "type": "object",
                    "properties": [
                        "start": ["type": "string", "description": "ISO 8601 start of the range, e.g. 2026-09-21T00:00:00-07:00. Defaults to the start of today if omitted."],
                        "end": ["type": "string", "description": "ISO 8601 end of the range, e.g. 2026-09-22T00:00:00-07:00. Defaults to the end of today if omitted."]
                    ],
                    "required": []
                ]
            ],
            [
                "name": "run_coding_agent",
                "description": "Delegate a coding task to Claude Code, which reads and modifies files in a real repository (implementing features, fixing bugs, making other code changes). Only for a task within a specific existing project directory — not for simple file reads (use read_file for that).",
                "input_schema": [
                    "type": "object",
                    "properties": [
                        "task": ["type": "string", "description": "A clear description of the coding task, e.g. \"implement a dark mode toggle in Settings\"."],
                        "repo_path": ["type": "string", "description": "Absolute or ~-relative path to the project's root directory, e.g. \"~/Documents/MyProject\"."]
                    ],
                    "required": ["task", "repo_path"]
                ]
            ],
            [
                "name": "browser_navigate",
                "description": "Navigate the active browser tab to a URL. Requires the CmdSlash browser extension to be installed and Chrome to be open.",
                "input_schema": [
                    "type": "object",
                    "properties": [
                        "url": ["type": "string", "description": "A fully-qualified URL, e.g. \"https://example.com\"."]
                    ],
                    "required": ["url"]
                ]
            ],
            [
                "name": "browser_get_page_text",
                "description": "Retrieve the active browser tab's raw visible text — this only returns the text, it does not summarize or interpret it. Requires the CmdSlash browser extension to be installed and Chrome to be open.",
                "input_schema": [
                    "type": "object",
                    "properties": [:],
                    "required": []
                ]
            ],
            [
                "name": "set_fullscreen",
                "description": "Enter or exit fullscreen for the current frontmost window — e.g. a window just opened via open_url/open_application, or whatever window the user is currently looking at. Requires macOS Accessibility permission.",
                "input_schema": [
                    "type": "object",
                    "properties": [
                        "enabled": [
                            "type": "boolean",
                            "description": "true for \"fullscreen\"/\"enter fullscreen\" (the default), false for \"exit fullscreen\"/\"leave fullscreen\"."
                        ]
                    ],
                    "required": []
                ]
            ],
            [
                "name": "read_screen_content",
                "description": "Read the structured UI content (buttons, fields, text, lists, labels) of the frontmost app's focused window via Accessibility — the native-app equivalent of browser_get_page_text, for when the request is about what's currently visible in an app that isn't a browser (Mail, Calendar, Finder, Slack desktop, Xcode, etc., or any app with no webpage DOM to extract). Not needed when the frontmost app is a browser — use browser_get_page_text for that instead. Requires macOS Accessibility permission.",
                "input_schema": [
                    "type": "object",
                    "properties": [:],
                    "required": []
                ]
            ]
        ]
    }

    private static let planMultiStepToolDefinition: [String: Any] = [
        "name": "plan_multi_step",
        "description": "Use this whenever the request is a QUESTION needing an actual answer (what/how much/when/where/why/is/does/tell me about), needs the content a tool returns to be interpreted or summarized, or needs multiple actions chained together (e.g. finding a file AND then acting on it). Do not use this for a COMMAND a single action tool fully and literally satisfies with no further interpretation needed (e.g. \"open Spotify\", \"go to a URL\", \"create an event\", \"find my resume\").",
        "input_schema": [
            "type": "object",
            "properties": [
                "goal": [
                    "type": "string",
                    "description": "A restatement of what the user ultimately wants accomplished."
                ]
            ],
            "required": ["goal"]
        ]
    ]

    /// Tools whose result on its own is never actually useful to the user — their fast-path
    /// completion message would just be "Read N characters from X" or "Opened X", not an answer
    /// to whatever they asked. browser_navigate is included here too, not just the obvious
    /// content-retrieval tools: open_url already covers plain "go to X" via the system default
    /// browser, so browser_navigate's real value is as a step within multi-step exploration
    /// (following an extracted link to find something), not as a fast-path standalone action —
    /// and despite repeated prompt tightening, the classifier kept reaching for it directly for
    /// "what's the latest X" style requests, navigating without anything then reading the result.
    /// Excluding these from the fast path's tool list entirely closes that off structurally:
    /// routing through plan_multi_step becomes the only way to use them at all, so there's no
    /// direct-call path left to misclassify into.
    private static let agenticOnlyToolNames: Set<String> = ["read_file", "browser_get_page_text", "browser_navigate", "read_screen_content"]

    /// Classifies a fast-path intent (Docs/PLANNING.md §20, §28): either exactly one action tool,
    /// or a signal (`plan_multi_step`) that this needs the agentic loop instead, or — if neither
    /// fits — a plain-text explanation. `context` (§18) is optional situational awareness.
    /// `conversationHistory` (recent exchanges in this overlay session, if any) lets a clarifying
    /// question CmdSlash just asked actually be answered — without it, "yes" or "the webpage" as
    /// the next submission would be classified with zero memory of what was just asked, since
    /// each submit() otherwise starts a fully independent request.
    func classifyFastPathIntent(_ text: String, context: ContextSnapshot = .empty, conversationHistory: String? = nil) async throws -> ClassificationResult {
        let tools = Self.actionToolDefinitions().filter {
            guard let name = $0["name"] as? String else { return true }
            return !Self.agenticOnlyToolNames.contains(name)
        } + [Self.planMultiStepToolDefinition]

        var systemPrompt = """
        You are the fast-path intent classifier for CmdSlash, a macOS agent. You have exactly \
        one turn: you either call one tool, or you don't — you never see that tool's result and \
        never get to say anything else afterward. Keep that constraint in mind literally.

        Call one action tool directly ONLY if that single call, with no further interpretation of \
        its result, fully satisfies the request (e.g. "open Spotify", "go to example.com").

        A reliable test: is the request phrased as a COMMAND (open, go to, create, delete, find) \
        or a QUESTION (what, how much, when, where, why, is/does/can, or any "tell me about X")? \
        Commands are usually satisfied by one mechanical action. Questions need an actual ANSWER — \
        and no action tool's completion message ("Opened X", "Found Y") is ever an answer to a \
        question, only confirmation that a mechanical step happened. If the request is a question, \
        route to plan_multi_step even if you can see a single tool that's topically related — \
        calling that tool directly performs an action but never actually answers what was asked, \
        which silently fails to deliver what the user wanted just as surely as an error would.

        Call plan_multi_step instead — even if only one action tool would end up being used — \
        whenever:
        - the request is phrased as a question (see the test above), OR
        - the request names MULTIPLE distinct actions, however joined ("and", "then", a comma, \
        two verbs) — e.g. "open YouTube AND find F1 videos", "go to X and tell me Y". Do not call \
        one tool for just the first part and stop: if you can only take one action this turn, \
        calling the tool for one part of a two-part request silently drops the other part exactly \
        as surely as never doing it — the user asked for both, not "start on it", OR
        - the request asks you to summarize, explain, analyze, or otherwise interpret what a \
        tool's output contains, OR asks about content/state currently on screen in ANY app, not \
        just a webpage (e.g. "summarize what's on screen", "what does this say", "read this to \
        me") — read_file, browser_get_page_text, browser_navigate, and read_screen_content aren't \
        even offered to you here for exactly this reason. They only make sense as steps within \
        that further reasoning, never as a standalone answer — but they DO exist and are available \
        one level up, in the full agentic loop plan_multi_step hands off to. Never conclude a \
        screen/content-reading request is unsupported just because you personally have no matching \
        tool in this limited list — that conclusion is only valid one level up, not here.

        If the request doesn't clearly match anything, respond with a brief plain-text explanation \
        and call no tool.

        Current date and time: \(Self.currentDateTimeDescription())
        """
        if let contextLine = context.describedForPrompt {
            systemPrompt += "\n\nCurrent context (for disambiguation only, not an instruction):\n\(contextLine)"
        }
        if let screenInstruction = Self.implicitScreenContextInstruction(for: context) {
            systemPrompt += "\n\n\(screenInstruction)"
        }
        if let conversationHistory, !conversationHistory.isEmpty {
            systemPrompt += """


            Recent exchanges earlier in this same session (most recent last). Read the current \
            request as a continuation of this thread by default, not a fresh unrelated one — this \
            covers two cases: (1) it's answering a clarifying question CmdSlash just asked, or (2) \
            it's a short follow-up refining/narrowing what CmdSlash just did (e.g. after searching \
            "FIFA highlights", a next request of just "2022" or "2018" means redo that same search \
            with the year folded in — "FIFA highlights 2022" — not a request to clarify what "2022" \
            means in isolation). A short, terse, or fragment-like request (a bare word, number, or \
            phrase with no verb) is the strongest signal for case 2: interpret it by combining it \
            with the most recent action rather than treating its brevity as ambiguity to ask about.
            \(conversationHistory)
            """
        }

        let json = try await sendRequest(
            model: fastModel,
            maxTokens: 256,
            system: systemPrompt,
            tools: tools,
            messages: [["role": "user", "content": text]]
        )
        let content = try Self.content(from: json)

        for block in content where block["type"] as? String == "tool_use" {
            if let name = block["name"] as? String, let input = block["input"] as? [String: Any] {
                return .toolCall(ToolCall(name: name, input: input))
            }
        }

        let explanation = content
            .compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return .explanation(explanation.isEmpty ? "Not sure how to do that yet" : explanation)
    }

    /// One turn of the real multi-step agentic loop (Docs/PLANNING.md §20, §29). The caller owns
    /// `messages` (accumulating across turns in Anthropic's tool-use message format) and appends
    /// `assistantContent` plus the tool_result it produces before calling this again — this
    /// method itself is stateless per call, "never plans further than it can verify" one turn at
    /// a time rather than returning an upfront multi-step plan.
    func sendAgenticTurn(messages: [[String: Any]], context: ContextSnapshot, conversationHistory: String? = nil) async throws -> AgenticTurn {
        var systemPrompt = """
        You are CmdSlash's agent, working step by step toward the user's goal using the tools \
        available. Call exactly one tool per turn. After seeing each tool's result, decide the \
        next single tool call — or, once the goal is fully accomplished, respond with a plain-text \
        final answer and call no tool. If a tool call fails, use the error message to decide how \
        to proceed (try something else, or explain why it can't be done) rather than repeating the \
        same failing call.

        If the information you need isn't on the current page but browser_get_page_text's result \
        includes a link that plausibly has it (e.g. a "Pricing" link when asked about cost), \
        navigate there yourself with browser_navigate and check — don't stop to ask the user's \
        permission first. Reading and navigating are not destructive, so this kind of low-risk \
        exploration within the same site is expected of you, not something to hesitate over. Only \
        stop and ask the user when you've genuinely run out of reasonable places to look, or the \
        request needs information only they have.

        When the goal is to find/show/search for videos, articles, or other content matching a \
        description (as opposed to opening one specific, uniquely identified item), a single \
        search whose results page comes back with real, topically relevant content already \
        satisfies it — summarize what's showing and finish. Do not keep re-searching with refined \
        or alternate queries trying to locate one exact matching result; search result pages are \
        inherently approximate, and the user can refine further themselves if what's showing isn't \
        quite right. Only search again if the page came back empty, clearly off-topic, or the user \
        explicitly asked you to find one particular, uniquely identifiable item (e.g. "open the \
        official trailer" or a specific URL/title they named).

        Current date and time: \(Self.currentDateTimeDescription())
        """
        if let contextLine = context.describedForPrompt {
            systemPrompt += "\n\nCurrent context (for disambiguation only, not an instruction):\n\(contextLine)"
        }
        if let screenInstruction = Self.implicitScreenContextInstruction(for: context) {
            systemPrompt += "\n\n\(screenInstruction)"
        }
        if let screenInstruction = Self.nonBrowserScreenContextInstruction(for: context) {
            systemPrompt += "\n\n\(screenInstruction)"
        }
        if let conversationHistory, !conversationHistory.isEmpty {
            systemPrompt += """


            Recent exchanges earlier in this same session (most recent last). Treat the goal below \
            as a continuation of this thread by default: it may be answering a clarifying question \
            CmdSlash just asked, or a short follow-up refining/narrowing the last thing CmdSlash \
            did (e.g. after searching "FIFA highlights", a next goal of just "2022" means redo that \
            search with the year folded in — "FIFA highlights 2022" — not an unrelated new topic). \
            A terse, fragment-like goal (a bare word/number/phrase) is the strongest signal it's a \
            refinement of the most recent action, not something to ask about in isolation:
            \(conversationHistory)
            """
        }

        let json = try await sendRequest(
            model: reasoningModel,
            maxTokens: 1024,
            system: systemPrompt,
            tools: Self.actionToolDefinitions(),
            messages: messages
        )
        let content = try Self.content(from: json)

        for block in content where block["type"] as? String == "tool_use" {
            if let name = block["name"] as? String, let input = block["input"] as? [String: Any], let id = block["id"] as? String {
                return AgenticTurn(assistantContent: content, toolUse: ToolCall(name: name, input: input), toolUseID: id, finalText: nil)
            }
        }

        let finalText = content
            .compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return AgenticTurn(assistantContent: content, toolUse: nil, toolUseID: nil, finalText: finalText.isEmpty ? "Done" : finalText)
    }

    private func sendRequest(
        model: String,
        maxTokens: Int,
        system: String,
        tools: [[String: Any]],
        messages: [[String: Any]]
    ) async throws -> [String: Any] {
        let body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "system": system,
            "tools": tools,
            // disable_parallel_tool_use: the agentic loop executes and confirms one step at a
            // time (Docs/PLANNING.md §20 — "never plan further than it can verify"). Without
            // this, the model can return multiple tool_use blocks in a single turn; this code
            // only executes the first, leaving any additional tool_use id with no matching
            // tool_result, which the API then rejects outright on the next call.
            "tool_choice": ["type": "auto", "disable_parallel_tool_use": true],
            "messages": messages
        ]

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let workspaceID {
            request.setValue(workspaceID, forHTTPHeaderField: "anthropic-workspace-id")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw ClientError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let responseBody = String(data: data, encoding: .utf8) ?? "<no body>"
            // .error, not .debug — persisted by default in unified logging (log show), unlike
            // debug/info, and the API's own error text is the fastest way to diagnose a 400 here.
            let requestBody = (try? JSONSerialization.data(withJSONObject: messages, options: [.prettyPrinted]))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "<couldn't serialize>"
            Self.logger.error("Anthropic API error \(http.statusCode, privacy: .public): \(responseBody, privacy: .public)\nRequest messages:\n\(requestBody, privacy: .public)")
            throw ClientError.httpError(http.statusCode, responseBody)
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClientError.invalidResponse
        }
        return json
    }

    private static func content(from json: [String: Any]) throws -> [[String: Any]] {
        guard let content = json["content"] as? [[String: Any]] else {
            throw ClientError.invalidResponse
        }
        return content
    }
}

import Foundation
import os

/// Minimal Chat Completions API client, talking to CmdSlash's own Supabase Edge Function relay
/// (Docs/PLANNING.md §59) rather than OpenAI directly — the managed-key pivot away from BYOK.
/// Two request shapes share the same action tools (§21): a single-shot fast-path classification
/// (§26-28) and a real multi-turn agentic loop (§20, §29) for requests that need more than one
/// tool chained together. Non-streaming for now — streaming (§40) is a later upgrade to the same
/// request shape, not an architecture change. Single model tier by design (unlike the old
/// Haiku/Sonnet split): one model handles both the fast path and the agentic loop.
///
/// Auth is a Supabase session, not a static provider key: the Keychain holds a refresh token
/// (§59.3 item 5), and every request first exchanges it for a fresh access token via
/// `refreshAccessToken()` — simpler than tracking each access token's own ~1hr expiry client-side,
/// at the cost of one extra HTTP round-trip per request (acceptable; dominated by the LLM call's
/// own latency regardless). Supabase rotates the refresh token on every use, so the response's
/// replacement is written back to Keychain each time — failing to persist it would strand the
/// session after exactly one more successful call.
///
/// NOTE: "gpt-5.4-mini" below has been confirmed against a live call through the relay (§59
/// Phase 1 verification) — a real, valid model identifier, not a guess.
struct OpenAIClient {
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
    /// `assistantMessage` is the exact {role, content, tool_calls} dict OpenAI returned, appended
    /// to the running `messages` array verbatim by the caller — OpenAI's multi-turn format needs
    /// this preserved exactly as returned so a later tool-result message's `tool_call_id` lines
    /// up with what the model itself emitted.
    struct AgenticTurn {
        let assistantMessage: [String: Any]
        let toolUse: ToolCall?
        let toolCallID: String?
        let finalText: String?
    }

    enum ClientError: Error, LocalizedError {
        case httpError(Int, String)
        case invalidResponse
        case sessionExpired

        var errorDescription: String? {
            switch self {
            case .httpError(let code, let body):
                "CmdSlash relay returned \(code): \(body.prefix(300))"
            case .invalidResponse:
                "Couldn't parse the relay's response."
            case .sessionExpired:
                // No login UI exists yet (§59.3 item 5 is still open) — until it does, this is
                // the honest thing to say rather than a generic "please sign in" that has nowhere
                // to send the user.
                "Your CmdSlash session couldn't be refreshed — it may have expired or been revoked. A fresh refresh token needs to be added to Keychain again until sign-in is built."
            }
        }
    }

    private static let logger = Logger(subsystem: "com.cmdslash.CmdSlash", category: "OpenAIClient")

    /// Public by Supabase's own design — meant to be embedded in client apps, protected by RLS
    /// rather than secrecy (Docs/PLANNING.md §59.2's vendor-decision note covers this
    /// distinction). Never the service role key, which stays server-side only, in the relay
    /// function's own secrets.
    private static let supabaseURL = "https://zwyakbxgdjplsqoxhnpy.supabase.co"
    private static let supabaseAnonKey = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Inp3eWFrYnhnZGpwbHNxb3hobnB5Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTA0MzgwMjIsImV4cCI6MjEwNjAxNDAyMn0.VtjDXwLyZIvfMKoA5tYpufW0AnGRrJSkL0fTaJjzJHE"
    private static let relayURL = "\(supabaseURL)/functions/v1/chat-relay"
    /// Not private: `SupabaseAuthClient` (writes the refresh token here on sign-in/sign-up) and
    /// `AppDelegate` (checks for its presence to decide whether to show the sign-in window, and
    /// deletes it on sign-out) both need the same service identifier — one source of truth
    /// rather than three copies of the string that could drift.
    static let sessionKeychainService = "com.cmdslash.session.refreshToken"

    private let model: String

    init(model: String = "gpt-5.4-mini") {
        self.model = model
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
        case ask them to say what)? Not an open-ended "what do you mean". To read what's actually \
        on this page, use browser_get_page_text — NOT read_screen_content, which is only for \
        native apps with no webpage DOM and will fail here even when it's otherwise available.
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

    /// The real action tools, shared between the fast-path classifier and the agentic loop so
    /// their definitions never drift apart. Kept in Anthropic's name/description/input_schema
    /// shape — `openAITools(from:)` wraps these into OpenAI's {type, function} shape right before
    /// sending, so this list itself doesn't need touching if the wire format changes again later.
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
                "description": "Delegate a coding task to Claude Code, which reads and modifies files in a real repository (implementing features, fixing bugs, making other code changes). Only for a task the user has clearly framed as working on SOFTWARE — an existing project, repository, or codebase they've named or that's evident from context (e.g. an IDE/editor frontmost). Never use this for calendar, browser, file-search, or other non-coding tasks, even if the request contains a programming-sounding word — \"Canvas\" almost always means the Canvas LMS/education website, not the HTML5 <canvas> element, unless there's an actual code-editing context. If you can't identify a specific real project directory the user means, this tool doesn't apply — do not guess or default to the home directory (~) or any other path; the home directory is rejected outright and never a valid target, no exceptions. Do NOT reach for this as a general fallback when you're unsure how to accomplish something with your other tools — it has no browser access and cannot see webpages, tabs, or on-screen content at all, so delegating an \"inspect this webpage / figure out what's needed\" task to it will never work regardless of what directory you give it. If a task needs a webpage read, use browser_get_page_text/browser_navigate directly instead — that's what those tools are for.",
                "input_schema": [
                    "type": "object",
                    "properties": [
                        "task": ["type": "string", "description": "A clear description of the coding task, e.g. \"implement a dark mode toggle in Settings\"."],
                        "repo_path": ["type": "string", "description": "Absolute or ~-relative path to the project's root directory, e.g. \"~/Documents/MyProject\". Must be a real, specific project directory the user actually meant — never a guess or a generic fallback like the home directory."]
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
                "name": "browser_click",
                "description": "Click a visible button, link, or other clickable element on the active browser tab, matched by its visible text (e.g. \"Add to Cart\", \"Sign in\", the exact or close text of a link browser_get_page_text just showed you) — not a CSS selector. An exact case-insensitive match is preferred; if none exists, the first element whose text contains what you gave is clicked instead. Use this for interacting with a page (submitting a search, following something that isn't a plain link, paginating) rather than just reading it. Requires the CmdSlash browser extension to be installed and Chrome to be open.",
                "input_schema": [
                    "type": "object",
                    "properties": [
                        "text": ["type": "string", "description": "The visible text of the element to click, as seen on the page."]
                    ],
                    "required": ["text"]
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
            ],
            [
                "name": "confirm_batch_actions",
                "description": "Call this ONCE, before executing a set of multiple risky/destructive actions whose full details you've ALREADY determined (e.g., after reading the calendar to find exactly which events match \"all my Gym events this week\"), so the user approves the whole batch in a single confirmation instead of being interrupted for each one individually. List one entry per planned action with a short, specific, human-readable description of exactly what it will do. After approval, proceed to call each real action tool (create_calendar_event, delete_calendar_event, etc.) for every step you listed, in the same order — those calls will NOT be confirmed again, so only list steps you're actually about to perform, not speculative ones. Do not use this for a single risky action (its own confirmation is already enough) or before you've gathered the information needed to know the concrete list of actions — read first (list_calendar_events, browser_get_page_text, read_screen_content, etc., none of which need confirmation), THEN batch-confirm, THEN execute.",
                "input_schema": [
                    "type": "object",
                    "properties": [
                        "steps": [
                            "type": "array",
                            "description": "One entry per risky action you're about to take, in the order you'll take them.",
                            "items": [
                                "type": "object",
                                "properties": [
                                    "description": [
                                        "type": "string",
                                        "description": "A short, specific, human-readable description of exactly what this one action will do, e.g. \"Delete 'Gym' on 9/22 at 1:00 PM\"."
                                    ]
                                ],
                                "required": ["description"]
                            ]
                        ]
                    ],
                    "required": ["steps"]
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
    /// to whatever they asked. Excluding these from the fast path's tool list entirely closes
    /// that off structurally: routing through plan_multi_step becomes the only way to use them at
    /// all, so there's no direct-call path left to misclassify into.
    private static let agenticOnlyToolNames: Set<String> = ["read_file", "browser_get_page_text", "browser_navigate", "read_screen_content", "browser_click", "confirm_batch_actions"]

    /// Wraps a tool definition (name/description/input_schema) into OpenAI's function-calling
    /// shape. JSON Schema itself is identical between input_schema and OpenAI's `parameters` — no
    /// structural conversion needed beyond the rename/wrapper.
    private static func openAITools(from definitions: [[String: Any]]) -> [[String: Any]] {
        definitions.map { definition in
            [
                "type": "function",
                "function": [
                    "name": definition["name"] as Any,
                    "description": definition["description"] as Any,
                    "parameters": definition["input_schema"] as Any
                ]
            ]
        }
    }

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
        two verbs) — e.g. "open YouTube AND find F1 videos", "go to X and tell me Y", "search X \
        AND click/open the first result". Do not call one tool for just the first part and stop: \
        if you can only take one action this turn, calling the tool for one part of a two-part \
        request silently drops the other part exactly as surely as never doing it — the user asked \
        for both, not "start on it". This applies even when open_url's own search-URL-construction \
        (above) could satisfy the FIRST half alone — opening a site's search-results page is not \
        the same as clicking/opening what's found there, so "search X and click the first result" \
        is still two actions, and the second one (an actual click) isn't even a tool you have \
        access to here — that alone means the whole request needs plan_multi_step, not just the \
        search half, OR
        - the request asks you to summarize, explain, analyze, or otherwise interpret what a \
        tool's output contains, OR asks about content/state currently on screen in ANY app, not \
        just a webpage (e.g. "summarize what's on screen", "what does this say", "read this to \
        me"), OR needs to interact with a page beyond just reading/opening it (clicking something, \
        submitting a search, paginating) — read_file, browser_get_page_text, browser_navigate, \
        read_screen_content, and browser_click aren't even offered to you here for exactly this \
        reason. They only make sense as steps within \
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
            maxTokens: 256,
            systemPrompt: systemPrompt,
            tools: Self.openAITools(from: tools),
            messages: [["role": "user", "content": text]]
        )
        let message = try Self.message(from: json)

        if let toolCalls = message["tool_calls"] as? [[String: Any]],
           let first = toolCalls.first,
           let call = Self.toolCall(from: first) {
            return .toolCall(call)
        }

        let explanation = ((message["content"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return .explanation(explanation.isEmpty ? "Not sure how to do that yet" : explanation)
    }

    /// One turn of the real multi-step agentic loop (Docs/PLANNING.md §20, §29). The caller owns
    /// `messages` (accumulating across turns in OpenAI's chat message format — no system message
    /// in here, this method injects its own each call) and appends `assistantMessage` plus a
    /// `{role: "tool", ...}` result before calling this again — this method itself is stateless
    /// per call, "never plans further than it can verify" one turn at a time rather than
    /// returning an upfront multi-step plan.
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

        Never navigate to or open a calendar-feed/subscription URL (an .ics file, or a link whose \
        path contains "feeds/calendar", "webcal", etc.) — that isn't a renderable webpage, so \
        browser_navigate will just time out waiting for a page load that never fires, and opening \
        it via open_url hands it off to a different app entirely (e.g. macOS Calendar) rather than \
        showing you anything readable. If a page you're already on (e.g. a calendar view) doesn't \
        show everything you need, use ITS OWN on-page navigation instead — next/previous-month \
        links or buttons, pagination, date-range controls — via browser_click or by constructing \
        the equivalent URL, and read each page's content directly with browser_get_page_text. Once \
        you find a specific view that clearly shows what you need (e.g. an agenda/list view with \
        titles and dates, vs. a compact month grid), stick with that same view type for every \
        subsequent page in the sequence rather than switching between view types — switching adds \
        extra steps without adding information, and this loop has a limited number of turns.

        When the goal is to find/show/search for videos, articles, or other content matching a \
        description (as opposed to opening one specific, uniquely identified item), a single \
        search whose results page comes back with real, topically relevant content already \
        satisfies it — summarize what's showing and finish. Do not keep re-searching with refined \
        or alternate queries trying to locate one exact matching result; search result pages are \
        inherently approximate, and the user can refine further themselves if what's showing isn't \
        quite right. Only search again if the page came back empty, clearly off-topic, or the user \
        explicitly asked you to find one particular, uniquely identifiable item (e.g. "open the \
        official trailer" or a specific URL/title they named).

        If the goal needs MULTIPLE risky/destructive actions once you know exactly what they are \
        (e.g. "delete all my Gym events this week" — after reading the calendar, you know exactly \
        which events those are), don't execute them one at a time with a separate confirmation \
        for each. Instead, once you've gathered enough information to know the full concrete list, \
        call confirm_batch_actions ONCE with one entry per action, get a single approval for the \
        whole batch, then proceed to call each real action tool in order — those won't be \
        confirmed again. This only applies once you already know the specific list; don't call it \
        speculatively before you've actually determined what the actions are, and don't use it for \
        just one risky action (that tool's own confirmation is already enough on its own).

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
            maxTokens: 1024,
            systemPrompt: systemPrompt,
            tools: Self.openAITools(from: Self.actionToolDefinitions()),
            messages: messages
        )
        let message = try Self.message(from: json)
        var assistantMessage = message
        assistantMessage["role"] = "assistant"

        if let toolCalls = message["tool_calls"] as? [[String: Any]],
           let first = toolCalls.first,
           let call = Self.toolCall(from: first),
           let id = first["id"] as? String {
            return AgenticTurn(assistantMessage: assistantMessage, toolUse: call, toolCallID: id, finalText: nil)
        }

        let finalText = ((message["content"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return AgenticTurn(assistantMessage: assistantMessage, toolUse: nil, toolCallID: nil, finalText: finalText.isEmpty ? "Done" : finalText)
    }

    /// OpenAI returns function-call arguments as a JSON-encoded STRING, not a native object —
    /// unlike the old Anthropic client's `input`, this needs an explicit parse. A malformed or
    /// unparseable arguments string still returns a ToolCall (with empty input) rather than
    /// throwing, so the existing per-tool `guard let X = call.input[...]` dispatch in
    /// OverlayViewModel naturally produces a MalformedToolCallError instead of losing the call
    /// entirely.
    private static func toolCall(from rawToolCall: [String: Any]) -> ToolCall? {
        guard let function = rawToolCall["function"] as? [String: Any], let name = function["name"] as? String else {
            return nil
        }
        guard
            let argumentsString = function["arguments"] as? String,
            let argumentsData = argumentsString.data(using: .utf8),
            let input = (try? JSONSerialization.jsonObject(with: argumentsData)) as? [String: Any]
        else {
            return ToolCall(name: name, input: [:])
        }
        return ToolCall(name: name, input: input)
    }

    private func sendRequest(
        maxTokens: Int,
        systemPrompt: String,
        tools: [[String: Any]],
        messages: [[String: Any]]
    ) async throws -> [String: Any] {
        let fullMessages: [[String: Any]] = [["role": "system", "content": systemPrompt]] + messages

        let body: [String: Any] = [
            "model": model,
            "max_completion_tokens": maxTokens,
            "messages": fullMessages,
            "tools": tools,
            "tool_choice": "auto",
            // Mirrors the old client's disable_parallel_tool_use: the agentic loop executes and
            // confirms one step at a time (Docs/PLANNING.md §20 — "never plan further than it can
            // verify"). Without this, the model can return multiple tool calls in a single turn;
            // this code only executes the first, leaving any additional tool_call id with no
            // matching tool result, which the API would then reject on the next call.
            "parallel_tool_calls": false
        ]

        let accessToken = try await Self.refreshAccessToken()

        var request = URLRequest(url: URL(string: Self.relayURL)!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw ClientError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let responseBody = String(data: data, encoding: .utf8) ?? "<no body>"
            // .error, not .debug — persisted by default in unified logging (log show), unlike
            // debug/info, and the relay's own error text (which includes OpenAI's, when it's the
            // one that rejected the request) is the fastest way to diagnose a 400/402 here.
            let requestBody = (try? JSONSerialization.data(withJSONObject: messages, options: [.prettyPrinted]))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "<couldn't serialize>"
            Self.logger.error("Relay error \(http.statusCode, privacy: .public): \(responseBody, privacy: .public)\nRequest messages:\n\(requestBody, privacy: .public)")
            throw ClientError.httpError(http.statusCode, responseBody)
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClientError.invalidResponse
        }
        return json
    }

    /// Exchanges the Keychain-stored refresh token for a fresh access token. Supabase rotates the
    /// refresh token on every use — the response's replacement is written back to Keychain before
    /// returning, since losing it would strand the session after this one call.
    private static func refreshAccessToken() async throws -> String {
        let refreshToken = try KeychainStore.readString(service: sessionKeychainService)

        var request = URLRequest(url: URL(string: "\(supabaseURL)/auth/v1/token?grant_type=refresh_token")!)
        request.httpMethod = "POST"
        request.setValue(supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["refresh_token": refreshToken])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard
            let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let accessToken = json["access_token"] as? String,
            let newRefreshToken = json["refresh_token"] as? String
        else {
            let responseBody = String(data: data, encoding: .utf8) ?? "<no body>"
            logger.error("Session refresh failed: \(responseBody, privacy: .public)")
            throw ClientError.sessionExpired
        }

        try KeychainStore.writeString(newRefreshToken, service: sessionKeychainService)
        return accessToken
    }

    private static func message(from json: [String: Any]) throws -> [String: Any] {
        guard
            let choices = json["choices"] as? [[String: Any]],
            let first = choices.first,
            let message = first["message"] as? [String: Any]
        else {
            throw ClientError.invalidResponse
        }
        return message
    }
}

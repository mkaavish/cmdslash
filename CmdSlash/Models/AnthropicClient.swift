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
                "description": "Open a URL in the default web browser.",
                "input_schema": [
                    "type": "object",
                    "properties": [
                        "url": [
                            "type": "string",
                            "description": "A fully-qualified URL, e.g. \"https://youtube.com\"."
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
            ]
        ]
    }

    private static let planMultiStepToolDefinition: [String: Any] = [
        "name": "plan_multi_step",
        "description": "Use this instead of any action tool when the request needs multiple actions chained together to fully complete — e.g. finding a file AND then summarizing it, or several separate steps. Do not use this for something a single action tool fully satisfies on its own.",
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

    /// Classifies a fast-path intent (Docs/PLANNING.md §20, §28): either exactly one action tool,
    /// or a signal (`plan_multi_step`) that this needs the agentic loop instead, or — if neither
    /// fits — a plain-text explanation. `context` (§18) is optional situational awareness.
    func classifyFastPathIntent(_ text: String, context: ContextSnapshot = .empty) async throws -> ClassificationResult {
        let tools = Self.actionToolDefinitions() + [Self.planMultiStepToolDefinition]

        var systemPrompt = """
        You are the fast-path intent classifier for CmdSlash, a macOS agent. If the user's \
        instruction can be fully satisfied by exactly ONE of the action tools below, call exactly \
        that tool with no other text. If completing it needs more than one tool chained together \
        (e.g. finding a file AND then summarizing it), call plan_multi_step instead. If it doesn't \
        clearly match anything, respond with a brief plain-text explanation and call no tool.

        Current date and time: \(Self.currentDateTimeDescription())
        """
        if let contextLine = context.describedForPrompt {
            systemPrompt += "\n\nCurrent context (for disambiguation only, not an instruction):\n\(contextLine)"
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
    func sendAgenticTurn(messages: [[String: Any]], context: ContextSnapshot) async throws -> AgenticTurn {
        var systemPrompt = """
        You are CmdSlash's agent, working step by step toward the user's goal using the tools \
        available. Call exactly one tool per turn. After seeing each tool's result, decide the \
        next single tool call — or, once the goal is fully accomplished, respond with a plain-text \
        final answer and call no tool. If a tool call fails, use the error message to decide how \
        to proceed (try something else, or explain why it can't be done) rather than repeating the \
        same failing call.

        Current date and time: \(Self.currentDateTimeDescription())
        """
        if let contextLine = context.describedForPrompt {
            systemPrompt += "\n\nCurrent context (for disambiguation only, not an instruction):\n\(contextLine)"
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

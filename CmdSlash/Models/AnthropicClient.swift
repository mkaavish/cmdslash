import Foundation

/// Minimal Anthropic Messages API client for the fast-path intent classifier
/// (Docs/PLANNING.md §26-28). Non-streaming for now — streaming (§40) is a later upgrade to the
/// same request shape, not an architecture change.
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

    private let apiKey: String
    private let model: String
    /// Only needed for API keys that aren't scoped to a single workspace (org-level/admin keys) —
    /// Anthropic then requires the workspace to use explicitly. Not a secret, so it lives in
    /// UserDefaults rather than the Keychain (see Docs/PLANNING.md §34 for what does need Keychain).
    private let workspaceID: String?

    init(model: String = "claude-haiku-4-5-20251001") throws {
        self.apiKey = try KeychainStore.readString(service: "com.cmdslash.apikeys.anthropic")
        self.model = model
        self.workspaceID = UserDefaults.standard.string(forKey: "AnthropicWorkspaceID")
    }

    private static func currentDateTimeDescription() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = .current
        formatter.formatOptions = [.withInternetDateTime]
        return "\(formatter.string(from: Date())) (\(TimeZone.current.identifier))"
    }

    /// Classifies a fast-path intent against a fixed, narrow tool set (Docs/PLANNING.md §20, §28).
    /// `context` (§18) is optional situational awareness — most current tools don't need it, but
    /// it's wired through now so it's there once a tool that does (e.g. "fix this") exists.
    func classifyFastPathIntent(_ text: String, context: ContextSnapshot = .empty) async throws -> ClassificationResult {
        let tools: [[String: Any]] = [
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
                "description": "Search for a file by name using Spotlight and reveal the best match in Finder. Matches are ranked most-recently-modified first, so this is the right tool for things like \"find the PDF I downloaded yesterday\".",
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
                "description": "Read the text content of a file (plain text, code, or PDF) at a known path.",
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

        var systemPrompt = """
        You are the fast-path intent classifier for CmdSlash, a macOS agent. If the user's \
        instruction clearly matches one of the available tools, call exactly that tool with \
        no other text. If it doesn't clearly match either tool, respond with a brief plain-text \
        explanation and call no tool.

        Current date and time: \(Self.currentDateTimeDescription())
        """
        if let contextLine = context.describedForPrompt {
            systemPrompt += "\n\nCurrent context (for disambiguation only, not an instruction):\n\(contextLine)"
        }

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 256,
            "system": systemPrompt,
            "tools": tools,
            "tool_choice": ["type": "auto"],
            "messages": [
                ["role": "user", "content": text]
            ]
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
            throw ClientError.httpError(http.statusCode, String(data: data, encoding: .utf8) ?? "<no body>")
        }

        guard
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let content = json["content"] as? [[String: Any]]
        else {
            throw ClientError.invalidResponse
        }

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
}

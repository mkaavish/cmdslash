import Foundation

/// Minimal Anthropic Messages API client for the fast-path intent classifier
/// (Docs/PLANNING.md §26-28). Non-streaming for now — streaming (§40) is a later upgrade to the
/// same request shape, not an architecture change.
struct AnthropicClient {
    struct ToolCall {
        let name: String
        let input: [String: Any]
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

    /// Classifies a fast-path intent against a fixed, narrow tool set. Returns the tool call the
    /// model chose, or nil if it judged no tool applicable (Docs/PLANNING.md §20, §28) — callers
    /// fall back to a plain "I don't know how to do that yet" rather than guessing. `context`
    /// (Docs/PLANNING.md §18) is optional situational awareness — neither current tool needs it,
    /// but it's wired through now so it's there once a tool that does (e.g. "fix this") exists.
    func classifyFastPathIntent(_ text: String, context: ContextSnapshot = .empty) async throws -> ToolCall? {
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
            ]
        ]

        var systemPrompt = """
        You are the fast-path intent classifier for CmdSlash, a macOS agent. If the user's \
        instruction clearly matches one of the available tools, call exactly that tool with \
        no other text. If it doesn't clearly match either tool, respond with a brief plain-text \
        explanation and call no tool.
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
                return ToolCall(name: name, input: input)
            }
        }
        return nil
    }
}

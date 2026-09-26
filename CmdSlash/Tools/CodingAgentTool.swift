import Foundation

/// The `run_coding_agent` tool (Docs/PLANNING.md §24) — CmdSlash does not reimplement a coding
/// agent, it orchestrates the one that already exists: this shells out to the Claude Code CLI as
/// a subprocess against a real repository, rather than trying to type code into an editor via
/// Accessibility. VS Code (or any editor) stays a viewport the user can open separately to watch,
/// not something this tool drives directly.
struct CodingAgentTool {
    struct Result {
        let output: String
        let repoPath: String
        /// Non-nil only when the repo shows uncommitted changes afterward (Docs/PLANNING.md §36
        /// — verification, not just trusting a zero exit code, which `claude -p` can return even
        /// having made no changes at all).
        let gitChangeSummary: String?
    }

    enum ToolError: Error, LocalizedError {
        case repoNotFound(String)
        case notAGitRepository(String)
        case claudeNotFound
        case processFailed(Int32, String)

        var errorDescription: String? {
            switch self {
            case .repoNotFound(let path):
                "No directory found at \(path)."
            case .notAGitRepository(let path):
                // Phrased for the model to read and act on (fed back as a tool result in the
                // agentic loop), not just the user — this is the recovery instruction for
                // exactly the failure mode it names.
                "\"\(path)\" isn't a git repository. run_coding_agent only runs against a real, specific existing project — never a home directory or other non-project folder, even as a fallback. If this task doesn't actually involve editing code in an existing project, it needs a different tool entirely (browser, calendar, file tools), not this one."
            case .claudeNotFound:
                "Claude Code CLI (`claude`) isn't installed or isn't on PATH."
            case .processFailed(let code, let output):
                "Claude Code exited with status \(code).\n\(output.suffix(500))"
            }
        }
    }

    private static let claudeCandidatePaths = ["/usr/local/bin/claude", "/opt/homebrew/bin/claude"]

    func execute(task: String, repoPath: String) async throws -> Result {
        try SensitivePathGuard.assertAllowed(repoPath)

        let expandedPath = (repoPath as NSString).expandingTildeInPath
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: expandedPath, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ToolError.repoNotFound(repoPath)
        }
        // Structural guard, not just a prompt instruction: a real software project is virtually
        // always git-tracked, and this directly targets the exact failure pattern seen live —
        // the model repeatedly defaulting repo_path to "~" for tasks that were never coding tasks
        // at all, each time requiring the user to approve a real high-risk confirmation before
        // Claude Code actually ran against their home directory. Prompt wording alone didn't
        // reliably prevent it; this makes the bad case impossible to execute regardless.
        guard Self.isGitRepository(at: expandedPath) else {
            throw ToolError.notAGitRepository(repoPath)
        }
        guard let claudeExecutable = Self.claudeCandidatePaths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw ToolError.claudeNotFound
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: claudeExecutable)
        process.currentDirectoryURL = URL(fileURLWithPath: expandedPath)
        // acceptEdits, not --dangerously-skip-permissions: this call is already gated behind
        // CmdSlash's own high-risk confirmation (the user approved this specific task and repo),
        // but that isn't a reason to also bypass Claude Code's own remaining safety checks for
        // things beyond ordinary file edits.
        process.arguments = ["-p", task, "--permission-mode", "acceptEdits"]

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        try process.run()

        // Cancel must genuinely kill the subprocess, not just abandon it running in the
        // background — the same principle already enforced for the rest of the app (Docs/
        // PLANNING.md §37, §38), which matters more here than anywhere else given this tool
        // actually edits files.
        let outputData: Data = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    continuation.resume(returning: data)
                }
            }
        } onCancel: {
            process.terminate()
        }

        guard !Task.isCancelled else {
            throw CancellationError()
        }

        let output = String(data: outputData, encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw ToolError.processFailed(process.terminationStatus, output)
        }

        return Result(output: output, repoPath: expandedPath, gitChangeSummary: Self.gitChangeSummary(inRepo: expandedPath))
    }

    private static func isGitRepository(at path: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["rev-parse", "--is-inside-work-tree"]
        process.currentDirectoryURL = URL(fileURLWithPath: path)

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    private static func gitChangeSummary(inRepo path: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["status", "--porcelain"]
        process.currentDirectoryURL = URL(fileURLWithPath: path)

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let status = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (status?.isEmpty == false) ? status : nil
    }
}

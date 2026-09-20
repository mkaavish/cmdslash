import Foundation

/// A model tool call was missing a required field. Shared across the fast path and the agentic
/// loop (Docs/PLANNING.md §20-21) since both dispatch the same tool set.
struct MalformedToolCallError: Error, LocalizedError {
    let tool: String
    var errorDescription: String? { "Model returned a malformed \(tool) call" }
}

struct CalendarAccessDeniedError: Error, LocalizedError {
    var errorDescription: String? { "Calendar access wasn't granted" }
}

struct UnknownToolError: Error, LocalizedError {
    let tool: String
    var errorDescription: String? { "Unknown tool: \(tool)" }
}

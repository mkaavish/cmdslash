/// A tool's result, in two forms with different audiences (Docs/PLANNING.md §21). `uiSummary` is
/// a short human-readable line for the overlay's status display. `modelFacingContent` is the full
/// data (e.g. a file's actual extracted text) fed back to the model as a tool_result in the
/// agentic loop — the two genuinely differ: showing a PDF's full text in the one-line status bar
/// would be useless, but summarizing it for the model would make it unable to actually summarize.
struct ToolExecutionOutcome {
    let modelFacingContent: String
    let uiSummary: String
}

import SwiftUI

/// The `cmd/` overlay's content. Voice and text share one field (Docs/PLANNING.md §6) — speech
/// streams in live, and typing at any point silently takes over. Short results (most tool
/// completions) stay on the compact one-line bar; long ones (agentic-path summaries, §29, or a
/// long high-risk confirmation, §30) expand into a scrollable text area — `onExpansionChange`
/// tells `OverlayWindowController` which size the panel itself needs to be, since a SwiftUI view
/// stretched to fill a fixed-size hosting view can't reliably report its own "natural" size back
/// out (that's circular).
struct OverlayView: View {
    @Bindable var viewModel: OverlayViewModel
    @FocusState private var isFocused: Bool
    var onExpansionChange: ((Bool) -> Void)?

    private var isExpanded: Bool {
        switch viewModel.phase {
        case .completed(let summary): Self.isLong(summary)
        case .failed(let message): Self.isLong(message)
        case .awaitingConfirmation(let summary): Self.isLong(summary)
        case .idle, .executing: false
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Text("cmd/")
                    .font(.system(size: 15, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)

                TextField("Ask CmdSlash...", text: $viewModel.inputText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .focused($isFocused)
                    .disabled(viewModel.isBusy)
                    .onSubmit {
                        if case .awaitingConfirmation = viewModel.phase {
                            viewModel.confirmPendingAction()
                        } else {
                            viewModel.submit()
                        }
                    }
                    .onChange(of: viewModel.inputText) { _, _ in
                        if !viewModel.isApplyingProgrammaticTextUpdate {
                            viewModel.userDidType()
                        }
                    }

                Spacer()

                Image(systemName: viewModel.isListening ? "mic.fill" : "mic")
                    .font(.system(size: 14))
                    .foregroundStyle(viewModel.isListening ? Color.red : Color.secondary)
                    .symbolEffect(.pulse, isActive: viewModel.isListening)
            }

            statusArea
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .frame(width: 560, alignment: .leading)
        .frame(maxHeight: .infinity)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08))
        )
        .onChange(of: viewModel.focusToken) { _, _ in isFocused = true }
        .onChange(of: isExpanded) { _, newValue in onExpansionChange?(newValue) }
        .onAppear { onExpansionChange?(isExpanded) }
    }

    @ViewBuilder
    private var statusArea: some View {
        switch viewModel.phase {
        case .idle:
            Color.clear.frame(height: 14)
        case .executing(let step):
            compactLine(step, icon: "arrow.forward.circle", color: .secondary)
        case .awaitingConfirmation(let summary):
            // isLong is decided on the raw summary alone, same value isExpanded above uses — the
            // fixed "Enter to confirm..." hint appended below must not affect that decision, or
            // this view and the panel-sizing decision could disagree about whether to expand.
            resultArea(
                "\(summary)  ·  Enter to confirm, Esc to cancel",
                icon: "questionmark.circle.fill",
                color: .orange,
                isLong: Self.isLong(summary)
            )
        case .completed(let summary):
            resultArea(summary, icon: "checkmark.circle.fill", color: .green, isLong: Self.isLong(summary))
        case .failed(let message):
            resultArea(message, icon: "xmark.circle.fill", color: .red, isLong: Self.isLong(message))
        }
    }

    private func compactLine(_ text: String, icon: String, color: Color) -> some View {
        Label(text, systemImage: icon)
            .font(.system(size: 12))
            .foregroundStyle(color)
            .lineLimit(1)
            .frame(height: 14, alignment: .leading)
    }

    @ViewBuilder
    private func resultArea(_ text: String, icon: String, color: Color, isLong: Bool) -> some View {
        if isLong {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .foregroundStyle(color)
                    .padding(.top, 3)

                ScrollView {
                    markdownContent(text)
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxHeight: .infinity)
        } else {
            compactLine(text, icon: icon, color: color)
        }
    }

    private static func isLong(_ text: String) -> Bool {
        text.count > 70 || text.contains("\n")
    }

    // MARK: - Markdown rendering

    /// Model-generated summaries (agentic-path final answers, §29) come back with real Markdown —
    /// headers, bullet/numbered lists, **bold**/*italic*. SwiftUI's `Text(AttributedString(markdown:))`
    /// renders inline emphasis correctly but completely drops block-level structure (paragraph
    /// breaks, list items) when the whole thing is shown through a single Text — it all runs
    /// together as one wall of text. So this parses into blocks first and renders each on its own
    /// line, with inline emphasis still handled per-block via AttributedString.
    private enum MarkdownBlockKind {
        case paragraph, header, listItem
    }

    private struct MarkdownBlock: Identifiable {
        let id = UUID()
        let kind: MarkdownBlockKind
        let text: String
    }

    private static func markdownBlocks(_ text: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var currentParagraph: [String] = []

        func flushParagraph() {
            guard !currentParagraph.isEmpty else { return }
            blocks.append(MarkdownBlock(kind: .paragraph, text: currentParagraph.joined(separator: " ")))
            currentParagraph = []
        }

        for rawLine in text.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                flushParagraph()
            } else if line.hasPrefix("#") {
                flushParagraph()
                blocks.append(MarkdownBlock(kind: .header, text: line.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)))
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                flushParagraph()
                blocks.append(MarkdownBlock(kind: .listItem, text: String(line.dropFirst(2))))
            } else if let range = line.range(of: #"^\d+\.\s+"#, options: .regularExpression) {
                flushParagraph()
                blocks.append(MarkdownBlock(kind: .listItem, text: String(line[range.upperBound...])))
            } else {
                currentParagraph.append(line)
            }
        }
        flushParagraph()
        return blocks
    }

    private static func attributedText(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .full)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }

    @ViewBuilder
    private func markdownContent(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Self.markdownBlocks(text)) { block in
                switch block.kind {
                case .header:
                    Text(Self.attributedText(block.text))
                        .font(.system(size: 13, weight: .semibold))
                case .listItem:
                    HStack(alignment: .top, spacing: 6) {
                        Text("•")
                        Text(Self.attributedText(block.text))
                    }
                    .font(.system(size: 13))
                case .paragraph:
                    Text(Self.attributedText(block.text))
                        .font(.system(size: 13))
                }
            }
        }
    }
}

#Preview {
    OverlayView(viewModel: OverlayViewModel())
        .padding(40)
}

import SwiftUI

/// The `cmd/` overlay's content. Voice and text share one field (Docs/PLANNING.md §6) — speech
/// streams in live, and typing at any point silently takes over. Short results (most tool
/// completions) stay on the compact one-line bar; long ones (agentic-path summaries, §29) expand
/// into a scrollable text area — `onExpansionChange` tells `OverlayWindowController` which size
/// the panel itself needs to be, since a SwiftUI view stretched to fill a fixed-size hosting view
/// can't reliably report its own "natural" size back out (that's circular).
struct OverlayView: View {
    @Bindable var viewModel: OverlayViewModel
    @FocusState private var isFocused: Bool
    var onExpansionChange: ((Bool) -> Void)?

    private var isExpanded: Bool {
        switch viewModel.phase {
        case .completed(let summary): Self.isLong(summary)
        case .failed(let message): Self.isLong(message)
        case .idle, .executing, .awaitingConfirmation: false
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
                        if !viewModel.isApplyingSpeechUpdate {
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
            compactLine("\(summary)  ·  Enter to confirm, Esc to cancel", icon: "questionmark.circle.fill", color: .orange)
        case .completed(let summary):
            resultArea(summary, icon: "checkmark.circle.fill", color: .green)
        case .failed(let message):
            resultArea(message, icon: "xmark.circle.fill", color: .red)
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
    private func resultArea(_ text: String, icon: String, color: Color) -> some View {
        if Self.isLong(text) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .foregroundStyle(color)
                    .padding(.top, 3)

                ScrollView {
                    Text(text)
                        .font(.system(size: 13))
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
}

#Preview {
    OverlayView(viewModel: OverlayViewModel())
        .padding(40)
}

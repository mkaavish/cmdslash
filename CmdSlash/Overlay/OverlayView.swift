import SwiftUI

/// The `cmd/` overlay's content. Voice and text share one field (Docs/PLANNING.md §6) — speech
/// streams in live, and typing at any point silently takes over. The real multi-step executing
/// checklist (§15, §42) is still a later upgrade to `statusLine` below.
struct OverlayView: View {
    @Bindable var viewModel: OverlayViewModel
    @FocusState private var isFocused: Bool

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

            statusLine
                .font(.system(size: 12))
                .frame(height: 14, alignment: .leading)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .frame(width: 560, height: 88, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08))
        )
        .onChange(of: viewModel.focusToken) { _, _ in isFocused = true }
        .onExitCommand { viewModel.cancel() }
    }

    @ViewBuilder
    private var statusLine: some View {
        switch viewModel.phase {
        case .idle:
            Color.clear
        case .executing(let step):
            Label(step, systemImage: "arrow.forward.circle")
                .foregroundStyle(.secondary)
        case .awaitingConfirmation(let summary):
            Label("\(summary)  ·  Enter to confirm, Esc to cancel", systemImage: "questionmark.circle.fill")
                .foregroundStyle(.orange)
        case .completed(let summary):
            Label(summary, systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed(let message):
            Label(message, systemImage: "xmark.circle.fill")
                .foregroundStyle(.red)
        }
    }
}

#Preview {
    OverlayView(viewModel: OverlayViewModel())
        .padding(40)
}

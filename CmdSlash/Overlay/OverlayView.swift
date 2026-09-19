import SwiftUI

/// The `cmd/` overlay's content. Voice input (Docs/PLANNING.md §17) and the real multi-step
/// executing checklist (§15, §42) come later — this wires text input and Enter-to-submit against
/// `OverlayViewModel`'s stubbed agent so the interaction shell is proven before anything real
/// runs behind it.
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
                    .onSubmit { viewModel.submit() }

                Spacer()

                Image(systemName: "mic")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
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
        case .completed(let summary):
            Label(summary, systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        }
    }
}

#Preview {
    OverlayView(viewModel: OverlayViewModel())
        .padding(40)
}

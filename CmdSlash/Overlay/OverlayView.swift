import SwiftUI

/// Idle-state view for the `cmd/` overlay. Voice/text input and the executing-state checklist
/// (Docs/PLANNING.md §15, §42) are wired up separately, once there is a real agent runtime behind them.
struct OverlayView: View {
    var body: some View {
        HStack(spacing: 12) {
            Text("cmd/")
                .font(.system(size: 15, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)

            Text("Ask CmdSlash...")
                .font(.system(size: 15))
                .foregroundStyle(.tertiary)

            Spacer()

            Image(systemName: "mic")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08))
        )
    }
}

#Preview {
    OverlayView()
        .frame(width: 560, height: 64)
        .padding(40)
}

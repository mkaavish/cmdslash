import SwiftUI

/// The companion window's API Key section — CmdSlash is BYOK (Docs/PLANNING.md §34): it talks to
/// OpenAI directly using a key you supply, stored only in the local macOS Keychain under
/// CmdSlash's own service identifier, never sent anywhere but api.openai.com.
struct APIKeyView: View {
    private static let service = "com.cmdslash.apikeys.openai"

    @State private var hasStoredKey = (try? KeychainStore.readString(service: service)) != nil
    @State private var input = ""
    @State private var statusMessage: String?
    @State private var isError = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("OpenAI API Key")
                .font(.title2)
                .fontWeight(.semibold)

            Text("CmdSlash calls OpenAI directly using your own API key. It's stored in the macOS Keychain and never leaves your machine except in requests to api.openai.com.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            if hasStoredKey {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("A key is saved.")
                    Spacer()
                    Button("Remove") { removeKey() }
                        .buttonStyle(.plain)
                        .foregroundStyle(.red)
                }
            }

            HStack {
                SecureField(hasStoredKey ? "Replace with a new key" : "sk-...", text: $input)
                    .textFieldStyle(.roundedBorder)
                Button("Save") { saveKey() }
                    .disabled(input.isEmpty)
            }

            if let statusMessage {
                Text(statusMessage)
                    .font(.footnote)
                    .foregroundStyle(isError ? .red : .green)
            }

            Spacer()
        }
        .padding(28)
        .frame(minWidth: 420, minHeight: 300)
    }

    private func saveKey() {
        do {
            try KeychainStore.writeString(input, service: Self.service)
            hasStoredKey = true
            input = ""
            isError = false
            statusMessage = "Saved."
        } catch {
            isError = true
            statusMessage = error.localizedDescription
        }
    }

    private func removeKey() {
        do {
            try KeychainStore.delete(service: Self.service)
            hasStoredKey = false
            isError = false
            statusMessage = "Removed."
        } catch {
            isError = true
            statusMessage = error.localizedDescription
        }
    }
}

#Preview {
    APIKeyView()
}

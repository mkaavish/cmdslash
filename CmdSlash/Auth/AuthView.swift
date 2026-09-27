import SwiftUI

/// Sign-up/sign-in form — shown in a real window (`AuthWindowController`), not the ⌘/ overlay,
/// since this is a deliberate task the user opts into or is gated behind on first launch, not a
/// glanceable quick-command surface. The onboarding/login flow the managed-key pivot makes
/// mandatory (Docs/PLANNING.md §59.3 item 5).
struct AuthView: View {
    enum Mode {
        case signIn, signUp
    }

    var onSignedIn: () -> Void

    @State private var mode: Mode = .signIn
    @State private var email = ""
    @State private var password = ""
    @State private var isSubmitting = false
    @State private var errorMessage: String?
    @State private var infoMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("cmd/")
                .font(.system(size: 20, weight: .bold, design: .monospaced))
                .foregroundStyle(.secondary)

            Text(mode == .signIn ? "Sign in to CmdSlash" : "Create your CmdSlash account")
                .font(.title2)
                .fontWeight(.semibold)

            VStack(alignment: .leading, spacing: 10) {
                TextField("Email", text: $email)
                    .textFieldStyle(.roundedBorder)
                    .disableAutocorrection(true)
                SecureField("Password", text: $password)
                    .textFieldStyle(.roundedBorder)
            }
            .onSubmit(submit)

            if let errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let infoMessage {
                Text(infoMessage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button(action: submit) {
                HStack {
                    Spacer()
                    if isSubmitting {
                        ProgressView().controlSize(.small)
                    } else {
                        Text(mode == .signIn ? "Sign In" : "Sign Up")
                    }
                    Spacer()
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(isSubmitting || email.isEmpty || password.isEmpty)

            Button(mode == .signIn ? "Need an account? Sign up" : "Already have an account? Sign in") {
                mode = mode == .signIn ? .signUp : .signIn
                errorMessage = nil
                infoMessage = nil
            }
            .buttonStyle(.plain)
            .font(.footnote)
            .foregroundStyle(.blue)
        }
        .padding(28)
        .frame(width: 360)
    }

    private func submit() {
        guard !isSubmitting, !email.isEmpty, !password.isEmpty else { return }
        errorMessage = nil
        infoMessage = nil
        isSubmitting = true
        let capturedMode = mode
        let capturedEmail = email
        let capturedPassword = password

        Task {
            let client = SupabaseAuthClient()
            do {
                switch capturedMode {
                case .signUp:
                    try await client.signUp(email: capturedEmail, password: capturedPassword)
                    // Reaching here (no .confirmationRequired thrown) means the project doesn't
                    // require email confirmation — signup itself returned a usable session.
                    onSignedIn()
                case .signIn:
                    try await client.signIn(email: capturedEmail, password: capturedPassword)
                    onSignedIn()
                }
            } catch SupabaseAuthClient.AuthError.confirmationRequired {
                mode = .signIn
                infoMessage = "Check your email to confirm your account, then sign in here."
            } catch {
                errorMessage = error.localizedDescription
            }
            isSubmitting = false
        }
    }
}

#Preview {
    AuthView(onSignedIn: {})
}

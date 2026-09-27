import SwiftUI

/// The companion window's Account section (Docs/PLANNING.md §59) — sign-in/sign-up (reusing
/// `AuthView` as a component) when there's no session, or account status (email, plan, usage
/// this month) with a sign-out action when there is. First section built of what's eventually
/// meant to also hold Settings/Connectors.
struct AccountView: View {
    @State private var isSignedIn = SupabaseSession.hasStoredSession()
    @State private var accountInfo: SupabaseSession.AccountInfo?
    @State private var isLoading = false
    @State private var loadError: String?

    var body: some View {
        Group {
            if isSignedIn {
                signedInBody
            } else {
                AuthView(onSignedIn: {
                    isSignedIn = true
                    Task { await loadAccountInfo() }
                })
            }
        }
        .frame(minWidth: 420, minHeight: 360)
        .task {
            if isSignedIn {
                await loadAccountInfo()
            }
        }
    }

    @ViewBuilder
    private var signedInBody: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text("cmd/")
                    .font(.system(size: 20, weight: .bold, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Sign Out") {
                    SupabaseSession.signOut()
                    isSignedIn = false
                    accountInfo = nil
                }
            }

            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, alignment: .center)
            } else if let loadError {
                VStack(alignment: .leading, spacing: 8) {
                    Text(loadError).foregroundStyle(.red)
                    Button("Retry") { Task { await loadAccountInfo() } }
                }
            } else if let accountInfo {
                VStack(alignment: .leading, spacing: 14) {
                    labeledRow("Email", accountInfo.email)
                    labeledRow("Plan", accountInfo.plan.capitalized)

                    let usedDollars = accountInfo.spentCents / 100
                    let capDollars = accountInfo.monthlyCapCents / 100
                    labeledRow("Usage this month", String(format: "$%.4f of $%.2f", usedDollars, capDollars))
                    ProgressView(value: min(accountInfo.spentCents / max(accountInfo.monthlyCapCents, 0.01), 1))
                }
            }

            Spacer()
        }
        .padding(28)
    }

    private func labeledRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).fontWeight(.medium)
        }
    }

    private func loadAccountInfo() async {
        isLoading = true
        loadError = nil
        do {
            accountInfo = try await SupabaseSession.fetchAccountInfo()
        } catch {
            loadError = error.localizedDescription
        }
        isLoading = false
    }
}

#Preview {
    AccountView()
}

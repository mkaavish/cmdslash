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

                    labeledRow(
                        "Usage this month",
                        "\(accountInfo.totalTokens.formatted()) of ~\(estimatedTokenCap(accountInfo).formatted()) tokens"
                    )
                    // Still proportional to the actual (cost-based) enforced cap, not the
                    // estimated token figure above — the real enforcement in chat-relay is
                    // cost-based, this display is just a friendlier unit for a human to read.
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

    /// The enforced cap is cost-based (chat-relay checks cents, not tokens — Docs/PLANNING.md
    /// §59.6), and input/output tokens cost very differently ($0.000075 vs. $0.00045/token per
    /// the relay's own rates), so there's no single fixed dollars-per-token conversion that's
    /// correct for everyone. Derived from this account's own actual spend-to-tokens ratio so far,
    /// so it reflects their real usage mix rather than an assumed blend — falls back to the
    /// gpt-5.4-mini input rate (the cheaper, higher-volume side of a typical request) before any
    /// usage exists to derive a real ratio from.
    private func estimatedTokenCap(_ info: SupabaseSession.AccountInfo) -> Int {
        let centsPerToken = info.totalTokens > 0 ? info.spentCents / Double(info.totalTokens) : 0.000075
        guard centsPerToken > 0 else { return 0 }
        return Int(info.monthlyCapCents / centsPerToken)
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

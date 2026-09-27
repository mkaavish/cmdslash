import Foundation
import os

/// Shared Supabase session management (Docs/PLANNING.md §59) — the Keychain-stored refresh
/// token, access-token minting via exchange, and basic account info. `OpenAIClient` (every
/// relay request) and the companion window's Account section (plan/usage display) both need a
/// fresh access token; this is the one place that exchange happens, not duplicated per caller.
enum SupabaseSession {
    /// Public by Supabase's own design — meant to be embedded in client apps, protected by RLS
    /// rather than secrecy (§59.2's vendor-decision note covers this distinction). Never the
    /// service role key, which stays server-side only, in the relay function's own secrets.
    static let supabaseURL = "https://zwyakbxgdjplsqoxhnpy.supabase.co"
    static let supabaseAnonKey = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Inp3eWFrYnhnZGpwbHNxb3hobnB5Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTA0MzgwMjIsImV4cCI6MjEwNjAxNDAyMn0.VtjDXwLyZIvfMKoA5tYpufW0AnGRrJSkL0fTaJjzJHE"
    /// Holds the Supabase refresh token, not an access token — access tokens are minted fresh
    /// per use instead of cached (see `refreshAccessToken` below for why).
    static let keychainService = "com.cmdslash.session.refreshToken"

    private static let logger = Logger(subsystem: "com.cmdslash.CmdSlash", category: "SupabaseSession")

    enum SessionError: Error, LocalizedError {
        case notSignedIn
        case refreshFailed
        case fetchFailed

        var errorDescription: String? {
            switch self {
            case .notSignedIn:
                "Not signed in."
            case .refreshFailed:
                "Your CmdSlash session couldn't be refreshed — it may have expired or been revoked. Sign in again from the CmdSlash menu bar icon."
            case .fetchFailed:
                "Couldn't load your account info. Check your connection and try again."
            }
        }
    }

    struct AccountInfo {
        let email: String
        let plan: String
        let monthlyCapCents: Double
        let spentCents: Double
    }

    static func hasStoredSession() -> Bool {
        (try? KeychainStore.readString(service: keychainService)) != nil
    }

    static func signOut() {
        try? KeychainStore.delete(service: keychainService)
    }

    /// Exchanges the stored refresh token for a fresh access token, rather than tracking each
    /// access token's own ~1hr expiry client-side — simpler, at the cost of one extra HTTP
    /// round-trip per caller (acceptable; every caller here is already paired with its own
    /// network call, e.g. the relay request or the account-info fetch below). Supabase rotates
    /// the refresh token on every use, so the response's replacement is written back to Keychain
    /// before returning — losing it would strand the session after exactly one more use.
    static func refreshAccessToken() async throws -> String {
        guard let refreshToken = try? KeychainStore.readString(service: keychainService) else {
            throw SessionError.notSignedIn
        }

        var request = URLRequest(url: URL(string: "\(supabaseURL)/auth/v1/token?grant_type=refresh_token")!)
        request.httpMethod = "POST"
        request.setValue(supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["refresh_token": refreshToken])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard
            let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let accessToken = json["access_token"] as? String,
            let newRefreshToken = json["refresh_token"] as? String
        else {
            let responseBody = String(data: data, encoding: .utf8) ?? "<no body>"
            logger.error("Session refresh failed: \(responseBody, privacy: .public)")
            throw SessionError.refreshFailed
        }

        try KeychainStore.writeString(newRefreshToken, service: keychainService)
        return accessToken
    }

    /// Email from Supabase's own `/auth/v1/user`, plan + cap from `profiles`, spend-so-far from
    /// the `current_period_usage` view (Docs/PLANNING.md §59.1's migration) — all three scoped to
    /// the caller by RLS, fetched in parallel since none depend on each other.
    static func fetchAccountInfo() async throws -> AccountInfo {
        let accessToken = try await refreshAccessToken()

        async let userJSON = getJSON(path: "/auth/v1/user", accessToken: accessToken)
        async let profileJSON = getJSON(path: "/rest/v1/profiles?select=plan,monthly_cap_cents", accessToken: accessToken)
        async let usageJSON = getJSON(path: "/rest/v1/current_period_usage?select=spent_cents", accessToken: accessToken)

        let (user, profiles, usageRows) = try await (userJSON, profileJSON, usageJSON)

        guard
            let email = (user as? [String: Any])?["email"] as? String,
            let profile = (profiles as? [[String: Any]])?.first,
            let plan = profile["plan"] as? String
        else {
            throw SessionError.fetchFailed
        }
        let cap = numeric(profile["monthly_cap_cents"])
        // No usage row yet (a brand-new account with zero requests this period) isn't an error —
        // current_period_usage only has a row once at least one usage_events entry exists.
        let spent = numeric((usageRows as? [[String: Any]])?.first?["spent_cents"])

        return AccountInfo(email: email, plan: plan, monthlyCapCents: cap, spentCents: spent)
    }

    private static func getJSON(path: String, accessToken: String) async throws -> Any {
        var request = URLRequest(url: URL(string: "\(supabaseURL)\(path)")!)
        request.setValue(supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw SessionError.fetchFailed
        }
        return try JSONSerialization.jsonObject(with: data)
    }

    /// PostgREST serializes a `numeric` column as a JSON number in most configurations, but as a
    /// string in others (to preserve precision) — accept either rather than assuming one.
    private static func numeric(_ value: Any?) -> Double {
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String, let number = Double(string) { return number }
        return 0
    }
}

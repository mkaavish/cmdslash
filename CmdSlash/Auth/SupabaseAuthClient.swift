import Foundation

/// Thin client for Supabase's Auth REST API — sign-up and password sign-in, storing the
/// resulting refresh token via `SupabaseSession` (Docs/PLANNING.md §59). Deliberately separate
/// from `SupabaseSession`/`OpenAIClient`: this type *establishes* a session, they only ever
/// refresh an existing one.
struct SupabaseAuthClient {
    enum AuthError: Error, LocalizedError {
        case requestFailed(String)
        case confirmationRequired
        case invalidResponse

        var errorDescription: String? {
            switch self {
            case .requestFailed(let message):
                message
            case .confirmationRequired:
                "Check your email to confirm your account, then sign in."
            case .invalidResponse:
                "Couldn't reach CmdSlash's servers. Check your connection and try again."
            }
        }
    }

    func signUp(email: String, password: String) async throws {
        let (data, response) = try await Self.post(
            path: "/auth/v1/signup",
            body: ["email": email, "password": password]
        )
        guard let http = response as? HTTPURLResponse else { throw AuthError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw AuthError.requestFailed(Self.errorMessage(from: data))
        }
        // A successful signup response never itself carries a usable session when email
        // confirmation is required (confirmed live during §59 Phase 1 testing): no
        // access_token/refresh_token pair comes back until the user clicks the confirmation
        // link and signs in separately.
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        if json?["access_token"] == nil {
            throw AuthError.confirmationRequired
        }
    }

    func signIn(email: String, password: String) async throws {
        let (data, response) = try await Self.post(
            path: "/auth/v1/token?grant_type=password",
            body: ["email": email, "password": password]
        )
        guard let http = response as? HTTPURLResponse else { throw AuthError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw AuthError.requestFailed(Self.errorMessage(from: data))
        }
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let refreshToken = json["refresh_token"] as? String
        else {
            throw AuthError.invalidResponse
        }
        try KeychainStore.writeString(refreshToken, service: SupabaseSession.keychainService)
    }

    private static func post(path: String, body: [String: String]) async throws -> (Data, URLResponse) {
        var request = URLRequest(url: URL(string: "\(SupabaseSession.supabaseURL)\(path)")!)
        request.httpMethod = "POST"
        request.setValue(SupabaseSession.supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await URLSession.shared.data(for: request)
    }

    /// Supabase Auth's error responses use "msg" (confirmed live against real 400s during §59
    /// testing: email_address_invalid, email_not_confirmed), with a couple of fallback field
    /// names in case a different endpoint on the same API ever uses a different shape.
    private static func errorMessage(from data: Data) -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return "Something went wrong. Check your email and password and try again."
        }
        return (json["msg"] as? String)
            ?? (json["error_description"] as? String)
            ?? (json["message"] as? String)
            ?? "Something went wrong. Check your email and password and try again."
    }
}

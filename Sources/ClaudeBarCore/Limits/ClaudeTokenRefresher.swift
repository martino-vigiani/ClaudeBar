import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Refresh del token OAuth — SOLO per credenziali owner `.claudeBar`.
// Endpoint e body verificati sull'upstream CodexBar:
//   POST https://platform.claude.com/v1/oauth/token
//   x-www-form-urlencoded: grant_type=refresh_token&refresh_token=<rt>&client_id=<clientID>
//
// REGOLA "non rubare il refresh alla CLI": se le credenziali sono di Claude Code (owner
// claudeCLI), NON refreshiamo qui — Claude ruota il refresh token, rinnovarlo noi lo
// invaliderebbe. Quel caso è gestito a monte nel service (errore refreshDelegatedToCLI).

public enum ClaudeTokenRefresher {
    public static let endpoint = URL(string: "https://platform.claude.com/v1/oauth/token")!
    /// Client ID pubblico, identico a Claude Code CLI (verificato).
    public static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"

    private struct TokenRefreshResponse: Decodable {
        let accessToken: String
        let refreshToken: String?
        let expiresIn: Int
        let tokenType: String?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case expiresIn = "expires_in"
            case tokenType = "token_type"
        }
    }

    /// Rinnova il token. Preserva scopes/rateLimitTier/subscriptionType.
    /// - Throws: `refreshFailedTerminal` (invalid_grant → ri-login) o `refreshFailedTransient`.
    public static func refresh(
        refreshToken: String,
        existing: ClaudeOAuthCredentials,
        session: URLSession,
        now: Date = Date()) async throws -> ClaudeOAuthCredentials
    {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "grant_type", value: "refresh_token"),
            URLQueryItem(name: "refresh_token", value: refreshToken),
            URLQueryItem(name: "client_id", value: clientID),
        ]
        request.httpBody = (components.percentEncodedQuery ?? "").data(using: .utf8)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ClaudeLimitsError.refreshFailedTransient(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw ClaudeLimitsError.invalidResponse
        }

        guard http.statusCode == 200 else {
            let oauthError = extractOAuthError(from: data)
            // invalid_grant → terminale: refresh token morto, niente ritento.
            if oauthError == "invalid_grant" || http.statusCode == 400 {
                throw ClaudeLimitsError.refreshFailedTerminal(
                    "HTTP \(http.statusCode) \(oauthError ?? "")".trimmingCharacters(in: .whitespaces))
            }
            throw ClaudeLimitsError.refreshFailedTransient(
                "HTTP \(http.statusCode) \(oauthError ?? "")".trimmingCharacters(in: .whitespaces))
        }

        guard let token = try? JSONDecoder().decode(TokenRefreshResponse.self, from: data) else {
            throw ClaudeLimitsError.invalidResponse
        }

        return ClaudeOAuthCredentials(
            accessToken: token.accessToken,
            refreshToken: token.refreshToken ?? refreshToken,
            expiresAt: now.addingTimeInterval(TimeInterval(token.expiresIn)),
            scopes: existing.scopes,
            rateLimitTier: existing.rateLimitTier,
            subscriptionType: existing.subscriptionType)
    }

    /// Estrae il campo `error` dal body OAuth (es. "invalid_grant").
    private static func extractOAuthError(from data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj["error"] as? String
    }
}

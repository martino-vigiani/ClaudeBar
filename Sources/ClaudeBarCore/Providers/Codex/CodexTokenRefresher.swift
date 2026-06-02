import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Rinnovo del token OAuth di Codex/ChatGPT.
//   POST https://auth.openai.com/oauth/token
//   body: { client_id, grant_type: "refresh_token", refresh_token, scope: "openid profile email" }
// client_id verificato sull'upstream CodexBar (client pubblico della CLI `codex`).
//
// ATTENZIONE — refresh token ROTANTE: l'endpoint restituisce un NUOVO refresh_token che invalida
// il precedente. Se rinnoviamo noi, la sessione della CLI `codex` (che legge lo stesso auth.json)
// si invalida. Per questo, come per Claude, il provider di DEFAULT delega il refresh alla CLI e
// usa questo refresher solo quando esplicitamente abilitato. Vedi `CodexProvider`.

public enum CodexTokenRefresher {
    public static let refreshURL = URL(string: "https://auth.openai.com/oauth/token")!
    /// client_id pubblico della CLI `codex` (verificato su CodexBar).
    public static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"

    /// Esegue il refresh e ritorna le credenziali aggiornate (access/refresh/id token rinnovati).
    /// - Throws: `ProviderError` (unauthorized se il refresh token è morto, network/server altrimenti).
    public static func refresh(
        _ credentials: CodexOAuthCredentials,
        session: URLSession,
        now: Date = Date()) async throws -> CodexOAuthCredentials
    {
        guard !credentials.refreshToken.isEmpty else {
            // Niente refresh token (es. API key mode): non c'è nulla da rinnovare.
            throw ProviderError.unauthorized("Codex: nessun refresh token disponibile.")
        }

        var request = URLRequest(url: self.refreshURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let body: [String: String] = [
            "client_id": self.clientID,
            "grant_type": "refresh_token",
            "refresh_token": credentials.refreshToken,
            "scope": "openid profile email",
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ProviderError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw ProviderError.invalidResponse }

        switch http.statusCode {
        case 200:
            return try Self.applyRefresh(data: data, to: credentials, now: now)
        case 400, 401, 403:
            // 400 con `invalid_grant`/`refresh_token_*` = refresh token morto → ri-login.
            throw ProviderError.unauthorized(Self.errorMessage(from: data))
        case 429:
            throw ProviderError.rateLimited(retryAfter: nil)
        default:
            throw ProviderError.serverError(code: http.statusCode, body: String(data: data, encoding: .utf8))
        }
    }

    private static func applyRefresh(
        data: Data,
        to credentials: CodexOAuthCredentials,
        now: Date) throws -> CodexOAuthCredentials
    {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw ProviderError.invalidResponse
        }
        // Campi mancanti → si conserva il valore precedente (CodexBar fa lo stesso).
        let newAccess = (json["access_token"] as? String) ?? credentials.accessToken
        let newRefresh = (json["refresh_token"] as? String) ?? credentials.refreshToken
        let newID = (json["id_token"] as? String) ?? credentials.idToken
        return CodexOAuthCredentials(
            accessToken: newAccess,
            refreshToken: newRefresh,
            idToken: newID,
            accountId: credentials.accountId,
            lastRefresh: now)
    }

    /// Estrae il codice errore OAuth dal body (per messaggi diagnostici).
    static func errorMessage(from data: Data) -> String? {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }
        if let error = json["error"] as? [String: Any], let code = error["code"] as? String {
            return "Codex refresh: \(code)"
        }
        if let error = json["error"] as? String {
            return "Codex refresh: \(error)"
        }
        return nil
    }
}

import Foundation

// Errori tipizzati del livello limiti, mappati 1:1 sullo stato UI dall'AppModel (core-engineer).

public enum ClaudeLimitsError: Error, Sendable, Equatable {
    /// Nessun token disponibile (Keychain vuoto / negato senza fallback). → "noAuth".
    case noCredentials
    /// HTTP 401: token non valido lato server. → "noAuth" / ri-autenticare.
    case unauthorized
    /// Token scaduto ma owner = claudeCLI: non refreshiamo noi (Claude ruota il refresh).
    /// → "apri Claude per ri-autenticare".
    case refreshDelegatedToCLI
    /// Token scaduto, owner non-CLI, ma nessun refresh token disponibile. → ri-login.
    case noRefreshToken
    /// Refresh fallito in modo terminale (es. `invalid_grant`): refresh token morto. → ri-login.
    case refreshFailedTerminal(String)
    /// Refresh fallito in modo transitorio (4xx/5xx): backoff e ritenta più tardi.
    case refreshFailedTransient(String)
    /// HTTP 429: rate-limited. `retryAfter` = quando ritentare. → mostra cache con badge stale.
    case rateLimited(retryAfter: Date?)
    /// L'utente ha negato il prompt Keychain. → backoff, suggerisci "consenti in Accesso Portachiavi".
    case keychainDenied
    /// 403 / 5xx generico.
    case serverError(code: Int, body: String?)
    /// Errore di rete.
    case network(String)
    /// Risposta non valida / decode fallito.
    case invalidResponse

    /// true se l'errore è terminale (richiede azione utente, niente ritento automatico).
    public var isTerminal: Bool {
        switch self {
        case .noCredentials, .unauthorized, .refreshDelegatedToCLI, .noRefreshToken,
             .refreshFailedTerminal, .keychainDenied:
            true
        case .rateLimited, .refreshFailedTransient, .serverError, .network, .invalidResponse:
            false
        }
    }
}

extension ClaudeLimitsError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .noCredentials:
            "Nessuna credenziale Claude trovata. Esegui `claude` per autenticarti."
        case .unauthorized:
            "Richiesta non autorizzata. Esegui `claude` per ri-autenticarti."
        case .refreshDelegatedToCLI:
            "Token scaduto: apri Claude Code per rinnovare l'accesso."
        case .noRefreshToken:
            "Token scaduto e nessun refresh token disponibile. Esegui `claude login`."
        case let .refreshFailedTerminal(message):
            "Rinnovo del token fallito (terminale): \(message). Esegui `claude login`."
        case let .refreshFailedTransient(message):
            "Rinnovo del token temporaneamente non riuscito: \(message). Riprovo più tardi."
        case .rateLimited:
            "Endpoint limiti temporaneamente rate-limited. Mostro l'ultimo dato disponibile."
        case .keychainDenied:
            "Accesso al Portachiavi negato. Consentilo in \"Accesso Portachiavi\" o riprova da un'azione."
        case let .serverError(code, body):
            Self.serverErrorMessage(code: code, body: body)
        case let .network(message):
            "Errore di rete: \(message)"
        case .invalidResponse:
            "Risposta non valida dall'endpoint limiti."
        }
    }

    private static func serverErrorMessage(code: Int, body: String?) -> String {
        guard let body, !body.isEmpty else { return "Errore server: HTTP \(code)" }
        let cleaned = body.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let short = cleaned.count > 300 ? String(cleaned.prefix(300)) + "…" : cleaned
        return "Errore server: HTTP \(code) – \(short)"
    }
}

import Foundation

// Errori unificati del livello provider. Generalizzano `ClaudeLimitsError` (che resta il tipo
// di dominio interno di Claude) in categorie che la UI mappa su stati indipendenti dal provider.
//
// Gli engineer di provider lanciano `ProviderError` dalle loro strategie; il `ClaudeProvider`
// traduce i `ClaudeLimitsError` esistenti in `ProviderError` senza perdere semantica
// (vedi `ClaudeLimitsError.asProviderError`).

public enum ProviderError: Error, Sendable, Equatable {
    /// Nessuna credenziale disponibile (Keychain vuoto, nessuna API key configurata).
    case noCredentials
    /// Credenziale presente ma rifiutata dal server (401/403) o scaduta senza refresh. → ri-auth.
    case unauthorized(String?)
    /// Il refresh del token spetta a un'altra app (es. Claude Code CLI). → apri quell'app.
    case refreshDelegatedToOwner
    /// L'utente ha negato l'accesso al Keychain.
    case keychainDenied
    /// HTTP 429: rate-limited. `retryAfter` = quando ritentare.
    case rateLimited(retryAfter: Date?)
    /// Errore server (codice + body opzionale).
    case serverError(code: Int, body: String?)
    /// Errore di rete / offline.
    case network(String)
    /// Risposta non valida / decode fallito.
    case invalidResponse
    /// Nessuna strategia di fetch disponibile per il provider nel contesto corrente.
    case noAvailableStrategy(ProviderID)

    /// true se l'errore è terminale (richiede azione utente, niente ritento automatico).
    public var isTerminal: Bool {
        switch self {
        case .noCredentials, .unauthorized, .refreshDelegatedToOwner, .keychainDenied, .noAvailableStrategy:
            true
        case .rateLimited, .serverError, .network, .invalidResponse:
            false
        }
    }
}

extension ProviderError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .noCredentials:
            "Nessuna credenziale trovata per questo provider."
        case let .unauthorized(message):
            message ?? "Accesso non autorizzato: ri-autenticati."
        case .refreshDelegatedToOwner:
            "Token scaduto: apri l'app proprietaria per rinnovare l'accesso."
        case .keychainDenied:
            "Accesso al Portachiavi negato. Consentilo in \"Accesso Portachiavi\" o riprova."
        case .rateLimited:
            "Endpoint temporaneamente rate-limited. Mostro l'ultimo dato disponibile."
        case let .serverError(code, _):
            "Errore server (HTTP \(code))."
        case let .network(message):
            "Errore di rete: \(message)"
        case .invalidResponse:
            "Risposta non valida dall'endpoint del provider."
        case let .noAvailableStrategy(id):
            "Nessuna sorgente disponibile per \(id.defaultDisplayName)."
        }
    }
}

// MARK: - Bridge da ClaudeLimitsError

extension ClaudeLimitsError {
    /// Traduce l'errore di dominio Claude nel suo equivalente provider-agnostico, senza
    /// perdere la semantica (1:1 con la mappatura su stati UI già concordata in AppModel).
    public var asProviderError: ProviderError {
        switch self {
        case .noCredentials:
            .noCredentials
        case .unauthorized:
            .unauthorized(nil)
        case .refreshDelegatedToCLI:
            .refreshDelegatedToOwner
        case .noRefreshToken, .refreshFailedTerminal:
            .unauthorized(errorDescription)
        case let .refreshFailedTransient(message):
            .network(message)
        case let .rateLimited(retryAfter):
            .rateLimited(retryAfter: retryAfter)
        case .keychainDenied:
            .keychainDenied
        case let .serverError(code, body):
            .serverError(code: code, body: body)
        case let .network(message):
            .network(message)
        case .invalidResponse:
            .invalidResponse
        }
    }
}

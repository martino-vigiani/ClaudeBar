import Foundation

/// Stato globale dell'app che guida glance + pannello (02-app-architecture.md §10).
///
/// Importante: le analytics locali (parsing `.jsonl`) sono INDIPENDENTI dai limiti ufficiali.
/// Se l'OAuth/endpoint fallisce, il pannello mostra comunque token/costo/breakdown dai
/// transcript; il glance ripiega su un colore neutro ma il pannello resta utile.
enum AppStatus: Sendable, Equatable {
    /// Primo avvio, nessun dato in cache.
    case loading
    /// Dati validi e freschi.
    case ready
    /// Mostra ultimo dato, refresh fallito di recente (gate 429 incluso).
    case stale(since: Date)
    /// Keychain senza item Claude o `subscriptionType` non Max.
    case noSubscription
    /// Token scaduto e refresh fallito → serve ri-login.
    case tokenExpired
    /// L'utente ha negato l'accesso al Keychain.
    case keychainDenied
    /// Nessuna connettività.
    case offline
    /// Errore generico, con messaggio.
    case error(message: String)
}

extension AppStatus {
    /// Stato "neutro" lato glance: non c'è un dato di limiti utile da rappresentare a colori.
    /// In questi casi l'icona NON deve mostrare un rosso falso.
    var prefersNeutralGlance: Bool {
        switch self {
        case .loading, .noSubscription, .keychainDenied, .offline:
            true
        case .ready, .stale, .tokenExpired, .error:
            false
        }
    }

    /// Lo stato impone un trattamento DIM (dato vecchio o non rappresentabile a colori).
    var prefersDimGlance: Bool {
        switch self {
        case .stale, .offline, .loading:
            true
        case .ready, .noSubscription, .tokenExpired, .keychainDenied, .error:
            false
        }
    }
}

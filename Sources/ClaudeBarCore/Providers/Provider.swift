import Foundation

// Protocollo `Provider` + contesto di fetch + pipeline di strategie.
//
// È l'INTERFACCIA CONGELATA che ogni provider implementa. Si ispira al pattern vincente di
// CodexBar (`ProviderFetchStrategy` con fallback isAvailable→fetch→shouldFallback) ma è molto
// più snello: niente runtime cli/app, niente cookie obbligatori, niente 15 sorgenti.
//
// Un `Provider` produce sempre un `ProviderSnapshot` unificato. L'auto-detect e l'auth sono
// gestiti dentro le strategie (ognuna sa se è disponibile e come autenticarsi).

// MARK: - Contesto di fetch

/// Contesto passato a un fetch. Value type `Sendable`: niente riferimenti ad attori/oggetti
/// mutabili attraversano il confine async.
public struct ProviderFetchContext: Sendable {
    /// `true` se l'azione è iniziata dall'utente (apertura pannello / Refresh manuale): il
    /// Keychain può mostrare il prompt. `false` = timer di background → query no-UI (fallisce
    /// pulito senza interrompere l'utente). Regola Keychain di Claude, generalizzata.
    public var userInitiated: Bool
    /// Quanti giorni di storico costo richiedere ai provider a consumo (default 30).
    public var costHistoryDays: Int
    /// Variabili d'ambiente (per token via env in debug/test e auto-detect CLI).
    public var environment: [String: String]
    /// Istante "ora" iniettabile (per i test deterministici sul pace).
    public var now: @Sendable () -> Date

    public init(
        userInitiated: Bool,
        costHistoryDays: Int = 30,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        now: @escaping @Sendable () -> Date = { Date() })
    {
        self.userInitiated = userInitiated
        self.costHistoryDays = max(1, min(365, costHistoryDays))
        self.environment = environment
        self.now = now
    }
}

// MARK: - Strategia di fetch (sorgente auth/dati)

/// Da dove arriva un dato (per diagnostica/badge "sorgente").
public enum ProviderFetchKind: String, Sendable, Equatable, Codable {
    case oauthManaged = "oauth_managed"
    case apiKey = "api_key"
    case browserCookie = "browser_cookie"
    /// Dati locali (es. transcript `.jsonl` per la stima costo).
    case local
}

/// Una singola sorgente di dati per un provider (es. OAuth, API key). Le strategie sono
/// provate in ordine; la prima `isAvailable` che riesce vince, con fallback su errore.
public protocol ProviderFetchStrategy: Sendable {
    /// Identificatore stabile (es. "claude.oauth"), per log/diagnostica.
    var id: String { get }
    /// Tipo di sorgente.
    var kind: ProviderFetchKind { get }
    /// true se questa strategia è plausibilmente utilizzabile nel contesto (no rete pesante).
    func isAvailable(_ context: ProviderFetchContext) async -> Bool
    /// Esegue il fetch e produce uno snapshot unificato.
    func fetch(_ context: ProviderFetchContext) async throws -> ProviderSnapshot
    /// true se, su questo errore, si può provare la strategia successiva.
    func shouldFallback(on error: Error, context: ProviderFetchContext) -> Bool
}

extension ProviderFetchStrategy {
    /// Default: fallback solo su errori NON terminali (rete/rate-limit/server).
    public func shouldFallback(on error: Error, context _: ProviderFetchContext) -> Bool {
        if let providerError = error as? ProviderError { return !providerError.isTerminal }
        if let claudeError = error as? ClaudeLimitsError { return !claudeError.isTerminal }
        return false
    }
}

// MARK: - Protocollo Provider

/// Un provider concreto (Claude, Codex, Gemini, …). Conoscenza statica via `descriptor`,
/// fetch dei dati via `snapshot(context:)`. Conforme a `Sendable`: le implementazioni sono
/// attori o value type immutabili.
public protocol Provider: Sendable {
    /// Descrizione statica (id, capability, auth, branding).
    var descriptor: ProviderDescriptor { get }

    /// Strategie di fetch in ordine di preferenza per l'auto-detect/fallback.
    /// (Il default `snapshot(context:)` le esegue come pipeline.)
    func strategies(for context: ProviderFetchContext) async -> [any ProviderFetchStrategy]

    /// Produce lo snapshot unificato corrente, eseguendo la pipeline di strategie.
    /// Implementazione di default fornita (vedi extension).
    func snapshot(context: ProviderFetchContext) async throws -> ProviderSnapshot

    /// Ultimo snapshot riuscito senza rete (per il primo paint a freddo). `nil` se mai recuperato.
    func cachedSnapshot() async -> ProviderSnapshot?

    /// true se il provider ha credenziali plausibilmente disponibili (per l'auto-detect del
    /// default e per abilitare/disabilitare in Impostazioni). NON deve fare rete.
    func detectAvailability(_ context: ProviderFetchContext) async -> ProviderAvailability
}

/// Esito dell'auto-detect di un provider (per scegliere il default sensato e popolare Settings).
public struct ProviderAvailability: Sendable, Equatable {
    /// true se almeno una strategia è disponibile (credenziali presenti).
    public var isAvailable: Bool
    /// Quale tipo di auth è stato trovato disponibile (per mostrarlo in Impostazioni).
    public var detectedAuth: ProviderAuthKind?
    /// Etichetta account rilevata senza rete, se nota (es. da Keychain account name).
    public var accountLabel: String?

    public init(isAvailable: Bool, detectedAuth: ProviderAuthKind? = nil, accountLabel: String? = nil) {
        self.isAvailable = isAvailable
        self.detectedAuth = detectedAuth
        self.accountLabel = accountLabel
    }

    public static let unavailable = ProviderAvailability(isAvailable: false)
}

// MARK: - Pipeline di default

extension Provider {
    /// Esegue le strategie in ordine: prima `isAvailable` che riesce vince; su errore con
    /// `shouldFallback` passa alla successiva. Se nessuna riesce, lancia l'ultimo errore
    /// (o `noAvailableStrategy`). Mantiene la semantica di degradazione di Claude.
    ///
    /// Esito quando nessuna strategia produce uno snapshot:
    ///   - se almeno una strategia ha eseguito ed è fallita → rilancia l'ULTIMO errore
    ///     (preserva il messaggio azionabile, es. `unauthorized`/`rateLimited`);
    ///   - altrimenti (nessuna strategia `isAvailable`, credenziali assenti) →
    ///     `noAvailableStrategy(id)`. La UI mappa `noAvailableStrategy` su "serve configurazione"
    ///     per quel provider. NB: i provider che vogliono distinguere "credenziale mancante" la
    ///     gestiscono dentro la strategia (la rendono `isAvailable` e lanciano `noCredentials`),
    ///     come fa la maggior parte dei provider a consumo/cookie.
    public func snapshot(context: ProviderFetchContext) async throws -> ProviderSnapshot {
        let strategies = await self.strategies(for: context)
        var lastError: Error?

        for strategy in strategies {
            guard await strategy.isAvailable(context) else { continue }
            do {
                return try await strategy.fetch(context)
            } catch {
                lastError = error
                if strategy.shouldFallback(on: error, context: context) {
                    continue
                }
                throw error
            }
        }

        if let lastError { throw lastError }
        throw ProviderError.noAvailableStrategy(self.descriptor.id)
    }

    /// Default: nessuna cache (i provider con cache la sovrascrivono, es. ClaudeProvider).
    public func cachedSnapshot() async -> ProviderSnapshot? { nil }
}

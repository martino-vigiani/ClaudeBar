import ClaudeBarCore
import Foundation

// Protocolli di confine verso il layer dati (ClaudeBarCore). L'AppModel dipende da QUESTI,
// non dai tipi concreti degli attori, così:
//  - resta disaccoppiato dalla loro implementazione (data-engineer);
//  - i test possono iniettare fake;
//  - gli attori reali (`TranscriptIndexer`, `ClaudeLimitsService`) conformano a questi
//    protocolli (o via thin adapter) quando il data-engineer li pubblica.
//
// Confini concordati: `02-app-architecture.md` §5/§11. Solo value type Sendable attraversano
// gli `await`.

/// Servizio limiti ufficiali (OAuth + Keychain + endpoint usage + gate 429). Attore in Core.
public protocol LimitsServicing: Sendable {
    /// Recupera lo snapshot dei limiti.
    /// - Parameter userInitiated: `true` → path Keychain CON prompt (azione utente: apertura
    ///   pannello / Refresh manuale). `false` → path no-UI (scheduler in background): se il
    ///   sistema chiederebbe il prompt, fallisce pulito senza interrompere l'utente (§7.2).
    func fetchUsage(userInitiated: Bool) async throws -> LimitsSnapshot
}

/// Indexer dei transcript `.jsonl` (walk + parse incrementale on-demand). Attore in Core.
public protocol TranscriptIndexing: Sendable {
    /// Ingest incrementale (solo delta) o full-index al primo giro. Ritorna il report aggregato.
    /// - Parameters:
    ///   - force: forza un re-scan completo.
    ///   - includeSubagents: se `false`, esclude le sessioni subagent dagli aggregati (preferenza
    ///     Impostazioni → Analytics). Default `true` = comportamento storico (nessuna regressione).
    func refresh(force: Bool, includeSubagents: Bool) async throws -> AnalyticsReport

    /// Azzera la cache dell'indice incrementale (stato in-memory + file su disco in `indexDir()`).
    /// Dopo il clear, il prossimo `refresh(force:)` ricostruisce da zero. Usata da
    /// "Azzera cache indice" (sezione Avanzato, SET-4).
    func clearCache() async
}

/// Persistenza della cache aggregati su disco (avvio istantaneo, anche offline). Servizio in Core.
public protocol PersistenceServicing: Sendable {
    /// Carica il report dalla cache su disco (se presente). `nil` al primo avvio.
    func loadCachedReport() async -> AnalyticsReport?
    /// Carica l'ultimo snapshot limiti dalla cache (per il glance immediato a freddo).
    func loadCachedLimits() async -> LimitsSnapshot?
    /// Salva (best-effort, debounced lato chiamante) il report aggregato.
    func saveReport(_ report: AnalyticsReport) async
    /// Salva l'ultimo snapshot limiti.
    func saveLimits(_ limits: LimitsSnapshot) async
    /// Elimina il file di cache del report aggregato (`analytics-cache.json`). Usata da
    /// "Azzera cache indice" (sezione Avanzato, SET-4).
    func clearCache() async
}

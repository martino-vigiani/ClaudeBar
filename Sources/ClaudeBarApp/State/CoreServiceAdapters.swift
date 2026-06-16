import ClaudeBarCore
import Foundation

// Thin adapter che fanno conformare gli ATTORI REALI di ClaudeBarCore ai protocolli di confine
// dell'app (`LimitsServicing` / `TranscriptIndexing` / `PersistenceServicing`).
//
// Perché adapter e non `extension ... : Protocol` direttamente in Core: i protocolli vivono
// nell'app layer (l'AppModel ne dipende per restare testabile coi fake), e non vogliamo che Core
// importi/conosca tipi dell'app. Gli adapter sono sottili (inoltro 1:1) e isolano le poche
// differenze di firma (es. PersistenceService non persiste i limiti).

/// Adatta `ClaudeBarCore.ClaudeLimitsService` → `LimitsServicing`.
/// La firma combacia 1:1 (`fetchUsage(userInitiated:)`).
struct LimitsServiceAdapter: LimitsServicing {
    let service: ClaudeLimitsService

    func fetchUsage(userInitiated: Bool) async throws -> LimitsSnapshot {
        try await self.service.fetchUsage(userInitiated: userInitiated)
    }
}

/// Adatta `ClaudeBarCore.TranscriptIndexer` → `TranscriptIndexing`.
/// La firma combacia 1:1 (`refresh(force:includeSubagents:)`).
struct TranscriptIndexerAdapter: TranscriptIndexing {
    let indexer: TranscriptIndexer

    func refresh(force: Bool, includeSubagents: Bool) async throws -> AnalyticsReport {
        try await self.indexer.refresh(force: force, includeSubagents: includeSubagents)
    }

    /// Azzera la cache dell'indice incrementale (stato in-memory + file su disco in `indexDir()`),
    /// delegando all'attore Core. Il prossimo `refresh(force: true)` ricostruisce da zero.
    func clearCache() async {
        await self.indexer.clearCache()
    }
}

/// Inoltra l'avanzamento del primo full-index (callback `@Sendable` dell'indexer, off-main)
/// al MainActor verso l'`AppModel`. `Sendable` via lock interno: evita di catturare una var
/// locale mutabile nella closure (vietato da Swift 6 strict).
final class IndexingProgressRelay: @unchecked Sendable {
    private let lock = NSLock()
    private weak var model: AppModel?

    @MainActor
    func attach(_ model: AppModel) {
        self.lock.lock(); defer { self.lock.unlock() }
        self.model = model
    }

    func report(_ value: Double) {
        self.lock.lock()
        let model = self.model
        self.lock.unlock()
        Task { @MainActor in model?.updateIndexingProgress(value) }
    }
}

/// Adatta `ClaudeBarCore.PersistenceService` → `PersistenceServicing`.
///
/// Inoltro 1:1: Core persiste sia il report aggregato (`loadReport`/`saveReport`) sia l'ultimo
/// snapshot limiti su disco (`loadLimits`/`saveLimits`, file separato `limits-cache.json`). La
/// cache su disco copre il paint a freddo (riavvio app): la cache in memoria di `ClaudeLimitsService`
/// vive solo per la sessione corrente.
struct PersistenceServiceAdapter: PersistenceServicing {
    let service: PersistenceService

    func loadCachedReport() async -> AnalyticsReport? {
        await self.service.loadReport()
    }

    func loadCachedLimits() async -> LimitsSnapshot? {
        await self.service.loadLimits()
    }

    func saveReport(_ report: AnalyticsReport) async {
        await self.service.saveReport(report)
    }

    func saveLimits(_ limits: LimitsSnapshot) async {
        await self.service.saveLimits(limits)
    }

    func clearCache() async {
        await self.service.clear() // rimuove analytics-cache.json (API pubblica di Core)
    }
}

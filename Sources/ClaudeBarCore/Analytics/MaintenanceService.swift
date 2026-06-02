import Foundation

// Operazioni di manutenzione della cache analytics su disco, esposte alla sezione "Avanzato"
// delle Impostazioni. La scene `Settings` non possiede l'`AppModel`: queste azioni vivono qui,
// nel Core, dietro un'API pulita e testabile (niente cancellazione di file "a mano" dalla UI).
//
// Riusa i tipi Core esistenti — `TranscriptIndexer` (rebuild + `clearCache`) e `PersistenceService`
// (`clear`) — senza duplicarne la logica. Tutte le operazioni agiscono sui percorsi deterministici
// di `AppPaths` (gli stessi usati dall'app a runtime): così "Ricostruisci/Azzera" toccano
// ESATTAMENTE la cache che l'app legge al boot.
//
// `includeSubagents` rispecchia la preferenza Impostazioni → Analytics: il chiamante la passa così
// il report ricostruito è coerente con ciò che il pannello mostra (niente divergenza tra il numero
// dopo un "Ricostruisci" e quello live).

public actor MaintenanceService {
    private let roots: [URL]
    private let index: IncrementalIndex
    private let persistence: PersistenceService

    public init(
        roots: [URL] = AppPaths.transcriptRoots(),
        index: IncrementalIndex = IncrementalIndex(),
        persistence: PersistenceService = PersistenceService())
    {
        self.roots = roots
        self.index = index
        self.persistence = persistence
    }

    /// Ricostruisce l'indice da zero (full re-scan) e ritorna il report aggregato aggiornato.
    /// Equivale a un `refresh(force: true)`: ignora la cache per-file e riparsa tutti i `.jsonl`.
    /// Il report viene anche persistito, così il prossimo avvio parte già dai dati freschi.
    /// - Parameter includeSubagents: rispecchia la preferenza Analytics (default `true` = tutto incluso).
    @discardableResult
    public func rebuildIndex(includeSubagents: Bool = true) async throws -> AnalyticsReport {
        let indexer = TranscriptIndexer(roots: self.roots, index: self.index)
        let report = try await indexer.refresh(force: true, includeSubagents: includeSubagents)
        await self.persistence.saveReport(report)
        return report
    }

    /// Azzera la cache su disco: svuota l'indice incrementale (file shard) e rimuove la cache
    /// aggregati. NON cancella i transcript originali dell'utente. Dopo l'azzeramento il prossimo
    /// refresh ricostruisce tutto da zero. Delega a `TranscriptIndexer.clearCache()` + `PersistenceService.clear()`.
    public func clearCache() async {
        let indexer = TranscriptIndexer(roots: self.roots, index: self.index)
        await indexer.clearCache()
        await self.persistence.clear()
    }

    /// Azzera la cache e poi la ricostruisce in un colpo solo (operazione tipica dal pulsante
    /// "Azzera cache indice"): garantisce che il report ritornato sia coerente con l'indice pulito.
    @discardableResult
    public func clearAndRebuild(includeSubagents: Bool = true) async throws -> AnalyticsReport {
        await self.clearCache()
        return try await self.rebuildIndex(includeSubagents: includeSubagents)
    }

    /// Carica il report attualmente in cache su disco (l'ultimo salvato dall'app). `nil` se assente
    /// o incompatibile coi prezzi correnti. Usato da "Esporta analytics" per partire dai dati reali
    /// senza dover ricalcolare.
    public func currentReport() async -> AnalyticsReport? {
        await self.persistence.loadReport()
    }
}

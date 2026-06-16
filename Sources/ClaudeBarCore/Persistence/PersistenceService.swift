import Foundation

// Persistenza della cache aggregati (report) su disco, con scrittura atomica.
// Distinta dall'IncrementalIndex (stato per-file): qui salviamo SOLO l'ultimo report
// aggregato per il paint immediato all'avvio.

public actor PersistenceService {
    private let url: URL

    public init(url: URL = AppPaths.appSupportDir().appendingPathComponent("analytics-cache.json")) {
        self.url = url
    }

    /// File separato per la cache limiti, accanto a quello del report (stessa dir).
    private var limitsURL: URL {
        url.deletingLastPathComponent().appendingPathComponent("limits-cache.json", isDirectory: false)
    }

    /// Carica l'ultimo report salvato, se compatibile con i prezzi correnti.
    public func loadReport(pricingFingerprint: String = PricingTable.fingerprint()) -> AnalyticsReport? {
        guard let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(AnalyticsCacheFile.self, from: data)
        else { return nil }
        guard file.schemaVersion == AnalyticsCacheFile.schemaVersion else { return nil }
        // Se i prezzi sono cambiati, i costi cached sono potenzialmente sbagliati: ignora.
        guard file.pricingFingerprint == pricingFingerprint else { return nil }
        return file.report
    }

    /// Elimina la cache aggregati su disco (best-effort). Usata da "Azzera cache indice"
    /// (sezione Avanzato): dopo il clear, il prossimo refresh forzato la ricostruisce da zero.
    /// Non è un errore se il file non esiste.
    public func clear() {
        try? FileManager.default.removeItem(at: url)
    }

    /// Carica l'ultimo snapshot limiti salvato, per il paint a freddo.
    /// Ritorna `nil` se schema incompatibile o cache troppo vecchia (>24h, inutile a freddo).
    /// Tra 5min e 24h lo snapshot è marcato `.stale` così la UI non lo spaccia per fresco.
    public func loadLimits() -> LimitsSnapshot? {
        guard let data = try? Data(contentsOf: limitsURL),
              let file = try? JSONDecoder().decode(LimitsCacheFile.self, from: data)
        else { return nil }
        guard file.schemaVersion == LimitsCacheFile.schemaVersion else { return nil }
        let age = Date().timeIntervalSince(file.savedAt)
        // Troppo vecchio per il paint a freddo: meglio nessun dato che un dato fuorviante.
        guard age <= 24 * 60 * 60 else { return nil }
        var snapshot = file.snapshot
        // Oltre i 5 minuti il dato non è più "fresco": badge stale per non ingannare la UI.
        if age > 5 * 60 {
            snapshot.source = .stale
        }
        return snapshot
    }

    /// Salva lo snapshot limiti (atomico), su file separato da quello del report.
    public func saveLimits(_ snapshot: LimitsSnapshot) {
        let file = LimitsCacheFile(savedAt: Date(), snapshot: snapshot)
        guard let data = try? JSONEncoder().encode(file) else { return }
        self.atomicWrite(data, to: limitsURL)
    }

    /// Salva il report (atomico).
    public func saveReport(_ report: AnalyticsReport, pricingFingerprint: String = PricingTable.fingerprint()) {
        let file = AnalyticsCacheFile(pricingFingerprint: pricingFingerprint, report: report)
        guard let data = try? JSONEncoder().encode(file) else { return }
        self.atomicWrite(data, to: url)
    }

    /// Scrittura atomica condivisa: assicura la dir di destinazione, scrive su un tmp con nome
    /// univoco (`.atomic`) e poi sostituisce/sposta sul path finale. In caso di errore rimuove il
    /// tmp e logga col nome del file di destinazione. Il `data` è già codificato dal chiamante.
    private func atomicWrite(_ data: Data, to destination: URL) {
        AppPaths.ensureDirectory(destination.deletingLastPathComponent())
        let tmp = destination.deletingLastPathComponent()
            .appendingPathComponent(".tmp-\(UUID().uuidString).json", isDirectory: false)
        do {
            try data.write(to: tmp, options: [.atomic])
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: tmp)
            } else {
                try FileManager.default.moveItem(at: tmp, to: destination)
            }
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            CoreLog.persistence.error("atomicWrite \(destination.lastPathComponent, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

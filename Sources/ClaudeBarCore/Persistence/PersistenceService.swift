import Foundation

// Persistenza della cache aggregati (report) su disco, con scrittura atomica.
// Distinta dall'IncrementalIndex (stato per-file): qui salviamo SOLO l'ultimo report
// aggregato per il paint immediato all'avvio.

public actor PersistenceService {
    private let url: URL

    public init(url: URL = AppPaths.appSupportDir().appendingPathComponent("analytics-cache.json")) {
        self.url = url
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

    /// Salva il report (atomico).
    public func saveReport(_ report: AnalyticsReport, pricingFingerprint: String = PricingTable.fingerprint()) {
        AppPaths.ensureDirectory(url.deletingLastPathComponent())
        let file = AnalyticsCacheFile(pricingFingerprint: pricingFingerprint, report: report)
        guard let data = try? JSONEncoder().encode(file) else { return }
        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent(".tmp-\(UUID().uuidString).json", isDirectory: false)
        do {
            try data.write(to: tmp, options: [.atomic])
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
            } else {
                try FileManager.default.moveItem(at: tmp, to: url)
            }
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            CoreLog.persistence.error("saveReport failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

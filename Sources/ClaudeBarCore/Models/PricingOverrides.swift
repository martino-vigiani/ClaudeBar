import Foundation

// Override pricing locale: legge `<AppSupport>/pricing-overrides.json` e fa merge sopra
// la tabella embedded. Permette di correggere/aggiornare i prezzi senza ricompilare
// (coerente con "uso personale", DECISIONS.md). Formato JSON: { "<modello-normalizzato>": ModelPricing }.

/// Carica e cachea gli override pricing dal disco. Thread-safe via lock interno.
public final class PricingOverrides: @unchecked Sendable {
    public static let shared = PricingOverrides()

    private let lock = NSLock()
    private var cached: [String: ModelPricing]
    private let url: URL

    public init(url: URL = AppPaths.pricingOverridesURL()) {
        self.url = url
        self.cached = Self.load(from: url)
    }

    /// Tabella override corrente (chiave = model id normalizzato).
    public var table: [String: ModelPricing] {
        lock.lock(); defer { lock.unlock() }
        return cached
    }

    /// Ricarica dal disco (es. dopo che l'utente modifica il file).
    public func reload() {
        let fresh = Self.load(from: url)
        lock.lock(); cached = fresh; lock.unlock()
    }

    private static func load(from url: URL) -> [String: ModelPricing] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        guard let decoded = try? JSONDecoder().decode([String: ModelPricing].self, from: data) else {
            return [:]
        }
        // Normalizza le chiavi così l'utente può scrivere anche un alias / id con data.
        var normalized: [String: ModelPricing] = [:]
        for (key, value) in decoded {
            normalized[ModelNormalizer.normalize(key)] = value
        }
        return normalized
    }
}

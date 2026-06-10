import Foundation

// Pricing table embedded (Claude 4.x + Fable 5) + normalizzazione model id + override JSON locale.
// Prezzi **per token** (USD), verificati dalla tabella reale di CodexBar
// (`.reference/CodexBar/.../CostUsagePricing.swift`).
//
// Differenza/vantaggio vs CodexBar: CodexBar usa un solo `cacheCreationInputCostPerToken`
// (prezzo cache-write 5m) per tutta la cache-write. Noi distinguiamo:
//   - cache-write 5m = input × 1.25
//   - cache-write 1h = input × 2          (moltiplicatore ufficiale Anthropic)
//   - cache-read     = input × 0.1
// I `.jsonl` reali dell'utente hanno la suddivisione `ephemeral_1h`/`ephemeral_5m`.

/// Prezzi per token (USD) di un modello, con eventuale tier long-context (soglia).
public struct ModelPricing: Sendable, Codable, Equatable {
    public var input: Double
    public var output: Double
    public var cacheWrite5m: Double
    public var cacheWrite1h: Double
    public var cacheRead: Double

    // Long-context (Sonnet): sopra `thresholdTokens` i prezzi raddoppiano. Tutti opzionali.
    public var thresholdTokens: Int?
    public var inputAbove: Double?
    public var outputAbove: Double?
    public var cacheWrite5mAbove: Double?
    public var cacheWrite1hAbove: Double?
    public var cacheReadAbove: Double?

    public init(
        input: Double,
        output: Double,
        cacheWrite5m: Double,
        cacheWrite1h: Double,
        cacheRead: Double,
        thresholdTokens: Int? = nil,
        inputAbove: Double? = nil,
        outputAbove: Double? = nil,
        cacheWrite5mAbove: Double? = nil,
        cacheWrite1hAbove: Double? = nil,
        cacheReadAbove: Double? = nil)
    {
        self.input = input
        self.output = output
        self.cacheWrite5m = cacheWrite5m
        self.cacheWrite1h = cacheWrite1h
        self.cacheRead = cacheRead
        self.thresholdTokens = thresholdTokens
        self.inputAbove = inputAbove
        self.outputAbove = outputAbove
        self.cacheWrite5mAbove = cacheWrite5mAbove
        self.cacheWrite1hAbove = cacheWrite1hAbove
        self.cacheReadAbove = cacheReadAbove
    }

    /// Costruttore per le famiglie Anthropic standard: deriva cache 5m/1h/read dai
    /// moltiplicatori ufficiali sul prezzo `input` (5m ×1.25, 1h ×2, read ×0.1).
    static func anthropic(
        input: Double,
        output: Double,
        thresholdTokens: Int? = nil,
        inputAbove: Double? = nil,
        outputAbove: Double? = nil) -> ModelPricing
    {
        ModelPricing(
            input: input,
            output: output,
            cacheWrite5m: input * 1.25,
            cacheWrite1h: input * 2.0,
            cacheRead: input * 0.1,
            thresholdTokens: thresholdTokens,
            inputAbove: inputAbove,
            outputAbove: outputAbove,
            cacheWrite5mAbove: inputAbove.map { $0 * 1.25 },
            cacheWrite1hAbove: inputAbove.map { $0 * 2.0 },
            cacheReadAbove: inputAbove.map { $0 * 0.1 })
    }
}

public enum PricingTable {
    /// Tabella embedded, chiave = model id **normalizzato** (vedi `ModelNormalizer`).
    /// Prezzi verificati dall'upstream CodexBar; cache 5m/1h/read derivate dai moltiplicatori.
    public static let embedded: [String: ModelPricing] = [
        // Fable 5 — flagship tier proprio (listino più alto di Opus). Prezzi verificati
        // da platform.claude.com/docs pricing (GA 2026-06-09): input $10/Mtok, output $50/Mtok.
        // 1M context window a prezzo standard (nessun tier long-context). Cache standard ×1.25/×2/×0.1.
        "claude-fable-5": .anthropic(input: 1e-5, output: 5e-5),
        // Opus 4.5/4.6/4.7/4.8 — stesso listino (input 5e-6, output 2.5e-5).
        "claude-opus-4-8": .anthropic(input: 5e-6, output: 2.5e-5),
        "claude-opus-4-7": .anthropic(input: 5e-6, output: 2.5e-5),
        "claude-opus-4-6": .anthropic(input: 5e-6, output: 2.5e-5),
        "claude-opus-4-5": .anthropic(input: 5e-6, output: 2.5e-5),
        // Opus 4 / 4.1 — listino più alto (input 1.5e-5, output 7.5e-5).
        "claude-opus-4-1": .anthropic(input: 1.5e-5, output: 7.5e-5),
        "claude-opus-4": .anthropic(input: 1.5e-5, output: 7.5e-5),
        // Sonnet 4.5/4.6 — con long-context tier a 200k (prezzi ×2 sopra soglia).
        "claude-sonnet-4-6": .anthropic(
            input: 3e-6, output: 1.5e-5,
            thresholdTokens: 200_000, inputAbove: 6e-6, outputAbove: 2.25e-5),
        "claude-sonnet-4-5": .anthropic(
            input: 3e-6, output: 1.5e-5,
            thresholdTokens: 200_000, inputAbove: 6e-6, outputAbove: 2.25e-5),
        "claude-sonnet-4": .anthropic(
            input: 3e-6, output: 1.5e-5,
            thresholdTokens: 200_000, inputAbove: 6e-6, outputAbove: 2.25e-5),
        // Haiku 4.5.
        "claude-haiku-4-5": .anthropic(input: 1e-6, output: 5e-6),
    ]

    /// Pricing per un model id già normalizzato: override locale (se presente) sopra embedded.
    public static func pricing(
        for normalizedModel: String,
        overrides: [String: ModelPricing] = PricingOverrides.shared.table) -> ModelPricing?
    {
        overrides[normalizedModel] ?? embedded[normalizedModel]
    }

    /// Costo "stima API-equivalente" in USD per un singolo evento, con split cache 5m/1h.
    ///
    /// Applica il tiering long-context se `thresholdTokens` è presente: la soglia è sui
    /// **token di input** (come CodexBar). Aggregare per-evento e poi sommare preserva i
    /// confini di soglia (nota verificata in CodexBar).
    /// - Returns: il costo, oppure `nil` se il modello non è in tabella (costo ignoto).
    public static func cost(
        model normalizedModel: String,
        input: Int,
        cacheRead: Int,
        cacheWrite5m: Int,
        cacheWrite1h: Int,
        output: Int,
        overrides: [String: ModelPricing] = PricingOverrides.shared.table) -> Double?
    {
        guard let p = pricing(for: normalizedModel, overrides: overrides) else { return nil }

        // Tiering long-context applicato per-componente: sotto/sopra `thresholdTokens` (sui token).
        func tiered(_ tokens: Int, base: Double, above: Double?) -> Double {
            guard let threshold = p.thresholdTokens, let above else {
                return Double(max(0, tokens)) * base
            }
            let t = max(0, tokens)
            let below = min(t, threshold)
            let over = max(t - threshold, 0)
            return Double(below) * base + Double(over) * above
        }

        return tiered(input, base: p.input, above: p.inputAbove)
            + tiered(cacheRead, base: p.cacheRead, above: p.cacheReadAbove)
            + tiered(cacheWrite5m, base: p.cacheWrite5m, above: p.cacheWrite5mAbove)
            + tiered(cacheWrite1h, base: p.cacheWrite1h, above: p.cacheWrite1hAbove)
            + tiered(output, base: p.output, above: p.outputAbove)
    }

    /// Fingerprint della tabella embedded (per invalidare la cache aggregati quando i prezzi cambiano).
    public static func fingerprint(overrides: [String: ModelPricing] = PricingOverrides.shared.table) -> String {
        let merged = embedded.merging(overrides) { _, new in new }
        return merged.keys.sorted().map { key in
            let p = merged[key]!
            return "\(key):\(p.input),\(p.output),\(p.cacheWrite5m),\(p.cacheWrite1h),\(p.cacheRead),\(p.thresholdTokens ?? 0)"
        }.joined(separator: "|")
    }
}

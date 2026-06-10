import Testing
@testable import ClaudeBarCore

// Pricing: prezzi reali verificati + moltiplicatori cache ufficiali (5m ×1.25, 1h ×2, read ×0.1).

@Suite("PricingTable")
struct PricingTableTests {
    @Test("Fable 5 ha i prezzi attesi e i moltiplicatori cache corretti")
    func fable5Pricing() throws {
        let p = try #require(PricingTable.pricing(for: "claude-fable-5", overrides: [:]))
        #expect(p.input == 1e-5)
        #expect(p.output == 5e-5)
        #expect(abs(p.cacheWrite5m - 1e-5 * 1.25) < 1e-18)
        #expect(abs(p.cacheWrite1h - 1e-5 * 2.0) < 1e-18)
        #expect(abs(p.cacheRead - 1e-5 * 0.1) < 1e-18)
        #expect(p.thresholdTokens == nil)
    }

    @Test("Opus 4.7 ha i prezzi attesi e i moltiplicatori cache corretti")
    func opus47Pricing() throws {
        let p = try #require(PricingTable.pricing(for: "claude-opus-4-7", overrides: [:]))
        #expect(p.input == 5e-6)
        #expect(p.output == 2.5e-5)
        // Moltiplicatori ufficiali sul prezzo input.
        #expect(abs(p.cacheWrite5m - 5e-6 * 1.25) < 1e-18)
        #expect(abs(p.cacheWrite1h - 5e-6 * 2.0) < 1e-18)
        #expect(abs(p.cacheRead - 5e-6 * 0.1) < 1e-18)
    }

    @Test("Costo per-evento somma le componenti con lo split cache 1h/5m")
    func costSumsComponents() throws {
        // 1M input, 1M output, 1M cache-read, 1M cache-5m, 1M cache-1h su opus-4-7.
        let cost = try #require(PricingTable.cost(
            model: "claude-opus-4-7",
            input: 1_000_000,
            cacheRead: 1_000_000,
            cacheWrite5m: 1_000_000,
            cacheWrite1h: 1_000_000,
            output: 1_000_000,
            overrides: [:]))
        let expected = 1_000_000.0 * (5e-6 + 5e-7 + 6.25e-6 + 1e-5 + 2.5e-5)
        #expect(abs(cost - expected) < 1e-6)
    }

    @Test("Modello fuori tabella → costo nil (mai sbagliato)")
    func unknownModelIsNil() {
        #expect(PricingTable.cost(
            model: "modello-inesistente",
            input: 1000, cacheRead: 0, cacheWrite5m: 0, cacheWrite1h: 0, output: 100,
            overrides: [:]) == nil)
    }

    @Test("Sonnet applica il tier long-context sopra 200k token di input")
    func sonnetLongContextTier() throws {
        let below = try #require(PricingTable.cost(
            model: "claude-sonnet-4-6",
            input: 100_000, cacheRead: 0, cacheWrite5m: 0, cacheWrite1h: 0, output: 0,
            overrides: [:]))
        let above = try #require(PricingTable.cost(
            model: "claude-sonnet-4-6",
            input: 300_000, cacheRead: 0, cacheWrite5m: 0, cacheWrite1h: 0, output: 0,
            overrides: [:]))
        // below: 100k × 3e-6. above: 200k × 3e-6 + 100k × 6e-6.
        #expect(abs(below - 100_000 * 3e-6) < 1e-9)
        #expect(abs(above - (200_000 * 3e-6 + 100_000 * 6e-6)) < 1e-9)
    }

    @Test("L'override locale ha precedenza sull'embedded")
    func overrideWins() throws {
        let override = ModelPricing(input: 1, output: 1, cacheWrite5m: 1, cacheWrite1h: 1, cacheRead: 1)
        let p = try #require(PricingTable.pricing(for: "claude-opus-4-7", overrides: ["claude-opus-4-7": override]))
        #expect(p.input == 1)
    }
}

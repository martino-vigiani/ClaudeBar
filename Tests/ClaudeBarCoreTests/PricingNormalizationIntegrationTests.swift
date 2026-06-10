import Foundation
import Testing
@testable import ClaudeBarCore

// Test di INTEGRAZIONE (IMPL-E) della catena rawModel → ModelNormalizer → PricingTable → costo.
// Copre il caso reale citato in DECISIONS.md e nel mandato: un model id con suffisso `[1m]`
// (es. "claude-opus-4-7[1m]") deve normalizzarsi e trovare il prezzo, NON cadere a costo nil.
// I test esistenti coprono normalizer e pricing in isolamento; qui si verifica la catena unita
// passando attraverso il parser (TranscriptLine.decode) e l'aggregatore (CostCalculator).

@Suite("Pricing × normalizzazione (catena end-to-end)")
struct PricingNormalizationIntegrationTests {
    /// Riga assistant reale con model id che porta il suffisso `[1m]` (contesto esteso).
    private func line(model: String, input: Int, output: Int) -> Data {
        Data(#"""
        {"type":"assistant","timestamp":"2026-05-30T10:00:00.000Z","cwd":"/p","requestId":"req_\#(model)","sessionId":"s","message":{"id":"msg_\#(model)","model":"\#(model)","usage":{"input_tokens":\#(input),"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":\#(output)}}}
        """#.utf8)
    }

    @Test("rawModel con suffisso [1m] viene normalizzato e ha lo stesso costo del base")
    func suffix1mNormalizesToBasePrice() throws {
        // claude-opus-4-7[1m] → normalizza a claude-opus-4-7 → prezzo opus 4.7.
        let event = try #require(TranscriptLine.decode(line(model: "claude-opus-4-7[1m]", input: 1000, output: 100)))
        #expect(event.model == "claude-opus-4-7")           // normalizzato.
        #expect(event.rawModel == "claude-opus-4-7[1m]")    // raw conservato.

        let report = CostCalculator.build(events: [event])
        let expected = 1000.0 * 5e-6 + 100.0 * 2.5e-5       // prezzo opus 4.7.
        let cost = try #require(report.totals.costUSD)
        #expect(abs(cost - expected) < 1e-9)
        #expect(report.costEstimated == false)              // non è un alias: costo certo.
    }

    @Test("Il suffisso [1m] NON deve mai produrre costo nil per un modello noto")
    func suffix1mNeverNil() throws {
        for raw in ["claude-fable-5[1m]", "claude-opus-4-8[1m]", "claude-sonnet-4-6[1m]", "claude-haiku-4-5[1m]"] {
            let event = try #require(TranscriptLine.decode(line(model: raw, input: 500, output: 50)))
            let report = CostCalculator.build(events: [event])
            #expect(report.totals.costUSD != nil, "costo nil per \(raw) → normalizzazione [1m] rotta")
        }
    }

    @Test("Alias non versionato ('opus') è prezzato come STIMA e marca costEstimated")
    func aliasIsEstimated() throws {
        let event = try #require(TranscriptLine.decode(line(model: "opus", input: 1000, output: 0)))
        let report = CostCalculator.build(events: [event])
        #expect(report.totals.costUSD != nil)   // l'alias risolve a un modello concreto.
        #expect(report.costEstimated == true)   // ma è marcato stima (alias → modello esatto incerto).
    }

    @Test("Alias 'fable' è prezzato come STIMA e marca costEstimated")
    func fableAliasIsEstimated() throws {
        let event = try #require(TranscriptLine.decode(line(model: "fable", input: 1000, output: 0)))
        let report = CostCalculator.build(events: [event])
        #expect(report.totals.costUSD != nil)   // 'fable' → claude-fable-5: costo concreto.
        #expect(report.costEstimated == true)   // alias non versionato → marcato stima.
    }

    @Test("Costo aggregato su più modelli normalizzati = somma dei costi per-modello")
    func aggregateAcrossModels() throws {
        let opus = try #require(TranscriptLine.decode(line(model: "claude-opus-4-7[1m]", input: 1000, output: 0)))
        let haiku = try #require(TranscriptLine.decode(line(model: "claude-haiku-4-5", input: 2000, output: 0)))
        let report = CostCalculator.build(events: [opus, haiku])
        let expected = 1000.0 * 5e-6 + 2000.0 * 1e-6
        let cost = try #require(report.totals.costUSD)
        #expect(abs(cost - expected) < 1e-9)
        #expect(report.byModel.count == 2)      // due modelli normalizzati distinti.
    }
}

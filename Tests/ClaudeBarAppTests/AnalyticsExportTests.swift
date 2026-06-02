import Foundation
import Testing
@testable import ClaudeBarApp
@testable import ClaudeBarCore

// Test della serializzazione CSV/JSON usata da "Esporta analytics" (sezione Avanzato).
// Verifica le intestazioni, i totali, l'escaping CSV dei campi con virgola, e che il JSON sia
// decodificabile come `AnalyticsReport` (round-trip lossless).

@Suite("Analytics export (CSV/JSON)")
struct AnalyticsExportTests {
    /// Report di esempio con un progetto il cui nome contiene una virgola (per testare l'escaping).
    private func sampleReport() -> AnalyticsReport {
        AnalyticsReport(
            totals: TokenTotals(
                input: 1000, output: 200, cacheRead: 50, cacheWrite5m: 10, cacheWrite1h: 5,
                totalTokens: 1265, costUSD: 0.123456),
            byDay: [
                DayBucket(dayKey: "2026-06-01", totalTokens: 1265, costUSD: 0.12, input: 1000, output: 200, cacheRead: 50),
            ],
            byModel: [
                ModelBucket(model: "claude-opus-4-8", totalTokens: 1265, costUSD: 0.12, costEstimated: false),
            ],
            byProject: [
                ProjectBucket(projectPath: "/Users/x/proj, with comma", displayName: "proj, with comma", totalTokens: 1265, costUSD: 0.12),
            ],
            bySession: [],
            cacheEfficiency: 0.0476,
            costEstimated: false,
            generatedAt: Date(timeIntervalSince1970: 1_750_000_000))
    }

    @Test("CSV: contiene le sezioni e i totali attesi")
    func csvSectionsAndTotals() {
        let csv = AnalyticsExport.csv(from: self.sampleReport())
        #expect(csv.contains("# Totals"))
        #expect(csv.contains("# By day"))
        #expect(csv.contains("# By model"))
        #expect(csv.contains("# By project"))
        #expect(csv.contains("total_tokens,1265"))
        #expect(csv.contains("2026-06-01,1265,1000,200,50,"))
        #expect(csv.contains("claude-opus-4-8,1265,"))
        #expect(csv.hasSuffix("\n"))
    }

    @Test("CSV: il campo con virgola viene quotato (RFC 4180)")
    func csvEscapesComma() {
        let csv = AnalyticsExport.csv(from: self.sampleReport())
        // Sia displayName sia projectPath contengono una virgola → devono essere tra virgolette.
        #expect(csv.contains("\"proj, with comma\""))
        #expect(csv.contains("\"/Users/x/proj, with comma\""))
    }

    @Test("JSON: round-trip lossless verso AnalyticsReport")
    func jsonRoundTrip() throws {
        let original = self.sampleReport()
        let json = try #require(AnalyticsExport.json(from: original))
        let data = try #require(json.data(using: .utf8))

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(AnalyticsReport.self, from: data)
        #expect(decoded.totals.input == original.totals.input)
        #expect(decoded.totals.totalTokens == original.totals.totalTokens)
        #expect(decoded.byModel.first?.model == "claude-opus-4-8")
        #expect(decoded.byProject.first?.displayName == "proj, with comma")
    }

    @Test("CSV: costo sconosciuto resta vuoto, non zero")
    func csvUnknownCostBlank() {
        let report = AnalyticsReport(
            totals: TokenTotals(input: 1, output: 0, cacheRead: 0, cacheWrite5m: 0, cacheWrite1h: 0, totalTokens: 1, costUSD: nil),
            byDay: [], byModel: [], byProject: [], bySession: [],
            cacheEfficiency: 0, costEstimated: false, generatedAt: Date())
        let csv = AnalyticsExport.csv(from: report)
        #expect(csv.contains("cost_usd,\n"))   // campo vuoto, non "0".
    }
}

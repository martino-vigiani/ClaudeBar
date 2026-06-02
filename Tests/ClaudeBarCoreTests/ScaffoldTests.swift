import Testing
@testable import ClaudeBarCore

// PLACEHOLDER (IMPL-A): test minimi sullo scaffold del Core.
// I test reali (PricingTable, parser incrementale + dedup, Pace/Forecast, OAuth parse)
// sono di competenza del data-engineer (IMPL-B) e dell'integrazione (IMPL-E).

@Suite("Core scaffold")
struct ScaffoldTests {
    @Test("Lo schema version del Core è positivo")
    func schemaVersionIsPositive() {
        #expect(ClaudeBarCoreInfo.schemaVersion > 0)
    }

    @Test("Tutte le aree del Core sono dichiarate")
    func coreAreasDeclared() {
        #expect(ClaudeBarCoreArea.allCases.count == 5)
    }
}

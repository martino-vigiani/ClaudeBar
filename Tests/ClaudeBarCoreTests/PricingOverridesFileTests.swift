import Foundation
import Testing
@testable import ClaudeBarCore

// Override pricing CARICATO DA DISCO — è il comportamento su cui poggia la sezione Analytics
// delle Impostazioni (SET-3): l'utente sceglie un JSON locale, l'app lo copia in
// `AppPaths.pricingOverridesURL()` e chiama `PricingOverrides.reload()`. Qui verifichiamo
// il contratto Core di quel flusso, isolato su un URL temporaneo (no toccare AppSupport reale).

@Suite("PricingOverrides — caricamento da file")
struct PricingOverridesFileTests {
    /// Scrive un JSON in un file temporaneo e ritorna l'URL (pulito dal chiamante).
    private func writeTempJSON(_ json: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("clbar-pricing-\(UUID().uuidString).json")
        try Data(json.utf8).write(to: url)
        return url
    }

    @Test("Carica un JSON valido dal disco e lo applica sopra l'embedded")
    func loadsValidJSONFromDisk() throws {
        // Override di un modello noto con un prezzo input "marcato" facile da distinguere.
        let json = """
        { "claude-opus-4-8": { "input": 9.0, "output": 9.0, "cacheWrite5m": 9.0, "cacheWrite1h": 9.0, "cacheRead": 9.0 } }
        """
        let url = try writeTempJSON(json)
        defer { try? FileManager.default.removeItem(at: url) }

        let overrides = PricingOverrides(url: url)
        let table = overrides.table
        let p = try #require(table["claude-opus-4-8"])
        #expect(p.input == 9.0)

        // La PricingTable, con questi override, usa il prezzo override (non l'embedded).
        let cost = try #require(PricingTable.cost(
            model: "claude-opus-4-8",
            input: 1, cacheRead: 0, cacheWrite5m: 0, cacheWrite1h: 0, output: 0,
            overrides: table))
        #expect(cost == 9.0)
    }

    @Test("Le chiavi del file vengono normalizzate (alias/suffissi)")
    func normalizesKeys() throws {
        // Chiave con suffisso `[1m]`: deve normalizzare a "claude-opus-4-8".
        let json = """
        { "claude-opus-4-8[1m]": { "input": 7.0, "output": 7.0, "cacheWrite5m": 7.0, "cacheWrite1h": 7.0, "cacheRead": 7.0 } }
        """
        let url = try writeTempJSON(json)
        defer { try? FileManager.default.removeItem(at: url) }

        let overrides = PricingOverrides(url: url)
        #expect(overrides.table[ModelNormalizer.normalize("claude-opus-4-8[1m]")]?.input == 7.0)
    }

    @Test("File assente o JSON non valido → tabella vuota (degrada con grazia)")
    func invalidOrMissingFileIsEmpty() throws {
        // File inesistente.
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("clbar-missing-\(UUID().uuidString).json")
        #expect(PricingOverrides(url: missing).table.isEmpty)

        // File con JSON malformato.
        let url = try writeTempJSON("{ not valid json")
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(PricingOverrides(url: url).table.isEmpty)
    }

    @Test("reload() rilegge il file dopo una modifica")
    func reloadPicksUpChanges() throws {
        let url = try writeTempJSON("""
        { "claude-opus-4-8": { "input": 1.0, "output": 1.0, "cacheWrite5m": 1.0, "cacheWrite1h": 1.0, "cacheRead": 1.0 } }
        """)
        defer { try? FileManager.default.removeItem(at: url) }

        let overrides = PricingOverrides(url: url)
        #expect(overrides.table["claude-opus-4-8"]?.input == 1.0)

        // Sostituisce il file e ricarica.
        try Data("""
        { "claude-opus-4-8": { "input": 2.0, "output": 2.0, "cacheWrite5m": 2.0, "cacheWrite1h": 2.0, "cacheRead": 2.0 } }
        """.utf8).write(to: url)
        overrides.reload()
        #expect(overrides.table["claude-opus-4-8"]?.input == 2.0)
    }
}

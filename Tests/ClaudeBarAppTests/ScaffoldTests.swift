import Testing
@testable import ClaudeBarCore

// PLACEHOLDER (IMPL-A): test minimi lato app.
// I test reali (icon rendering snapshot, scheduler, mapping stati) sono di competenza
// di core-engineer (IMPL-C) e dell'integrazione finale (IMPL-E).
//
// NB: si importa solo ClaudeBarCore qui per non dipendere dai simboli @main dell'app
// finché lo shell non è implementato. L'integrazione (IMPL-E) estenderà questi test.

@Suite("App scaffold")
struct AppScaffoldTests {
    @Test("Il Core è raggiungibile dal test target dell'app")
    func coreReachable() {
        #expect(ClaudeBarCoreInfo.schemaVersion >= 1)
    }
}

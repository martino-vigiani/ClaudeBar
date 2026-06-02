import Testing
@testable import ClaudeBarCore

// Normalizzazione modelli — casi reali verificati nei .jsonl dell'utente:
// claude-opus-4-7, varianti [1m], alias opus/sonnet/haiku, <synthetic>.

@Suite("ModelNormalizer")
struct ModelNormalizerTests {
    @Test("Normalizza i casi reali", arguments: [
        ("claude-opus-4-7", "claude-opus-4-7"),
        ("claude-opus-4-7[1m]", "claude-opus-4-7"),
        ("claude-opus-4-8[1m]", "claude-opus-4-8"),
        ("claude-opus-4-6[1m]", "claude-opus-4-6"),
        ("anthropic.claude-opus-4-5", "claude-opus-4-5"),
        ("claude-opus-4-5@20251101", "claude-opus-4-5"),
        ("claude-opus-4-5-20251101", "claude-opus-4-5"),
        ("opus", "claude-opus-4-8"),
        ("sonnet", "claude-sonnet-4-6"),
        ("haiku", "claude-haiku-4-5"),
    ])
    func normalize(raw: String, expected: String) {
        #expect(ModelNormalizer.normalize(raw) == expected)
    }

    @Test("Riconosce synthetic e alias")
    func flags() {
        #expect(ModelNormalizer.isSynthetic("<synthetic>"))
        #expect(ModelNormalizer.normalize("<synthetic>") == "<synthetic>")
        #expect(ModelNormalizer.isAlias("opus"))
        #expect(!ModelNormalizer.isAlias("claude-opus-4-7"))
    }
}

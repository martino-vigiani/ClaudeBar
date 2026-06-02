import ClaudeBarCore
import Foundation

// Composition root dei provider lato app: costruisce il `ProviderRegistry` con TUTTE le
// istanze concrete (Claude + Codex + Gemini + Cursor + OpenAI/Anthropic API), iniettando lo
// stesso `KeychainSecretStore` ai provider che leggono segreti dal Keychain.
//
// L'ordine è la PRIORITÀ per l'auto-detect del default (Claude primo → resta il default storico).
// Il Core non conosce questo elenco (registry = value type immutabile costruito qui), così non
// c'è stato globale né macro di auto-registrazione (a differenza di CodexBar).
enum ProviderRegistryFactory {
    /// Crea il registry completo. `claudeService` è condiviso così l'AppModel e il ClaudeProvider
    /// usano lo STESSO attore limiti (cache in memoria, gate 429, regola refresh): per Claude il
    /// comportamento resta identico all'MVP.
    static func makeRegistry(
        claudeService: ClaudeLimitsService,
        secretStore: any ProviderSecretStoring = KeychainSecretStore()) -> ProviderRegistry
    {
        ProviderRegistry(providers: [
            ClaudeProvider(service: claudeService),
            CodexProvider(),
            // Gemini = OAuth della Gemini CLI (file ~/.gemini), non un segreto nostro nel Keychain.
            GeminiProvider(),
            CursorProvider(secretStore: secretStore),
            OpenAIAPIProvider(secretStore: secretStore),
            AnthropicAPIProvider(secretStore: secretStore),
        ])
    }
}

import ClaudeBarCore
import Foundation

// Catalogo dei `ProviderDescriptor` per la UI delle Impostazioni.
//
// Le Impostazioni devono elencare TUTTI i provider noti (`ProviderID.allCases`), anche quelli
// non ancora abilitati o non ancora istanziati in un `ProviderRegistry` (che contiene solo i
// provider attivi del momento). Qui forniamo il descriptor "di catalogo" per ogni `ProviderID`,
// delegando al descriptor REALE del provider concreto corrispondente.
//
// Tutti i provider concreti hanno un `public init` con parametri di default (gli store/session
// servono solo al fetch, non alla descrizione statica): costruirli qui è economico e mantiene il
// catalogo SEMPRE allineato alle capabilities/authKinds/branding reali — incluse le correzioni
// additive ai descriptor (es. Gemini OAuth-CLI→limiti, Cursor cookie) senza dover toccare la UI.
enum ProviderCatalog {
    /// Descriptor per ogni `ProviderID` noto, nell'ordine di priorità (Claude primo).
    static let all: [ProviderDescriptor] = ProviderID.allCases.map(descriptor(for:))

    /// Descriptor di catalogo per un provider = il descriptor reale del provider concreto.
    static func descriptor(for id: ProviderID) -> ProviderDescriptor {
        switch id {
        case .claude: return ClaudeProvider().descriptor
        case .codex: return CodexProvider().descriptor
        case .gemini: return GeminiProvider().descriptor
        case .cursor: return CursorProvider().descriptor
        case .openaiAPI: return OpenAIAPIProvider().descriptor
        case .anthropicAPI: return AnthropicAPIProvider().descriptor
        }
    }
}

import Foundation

// Astrazione multi-provider — identità dei provider.
//
// A differenza dell'upstream CodexBar (47 provider in un solo grande enum + macro di
// registrazione), qui teniamo un set MINIMALE e CHIUSO per l'MVP (DECISIONS / BRIEF):
//   Claude (default, già funzionante), Codex/OpenAI, Gemini, Cursor, + API generiche
//   "a consumo" (Anthropic API, OpenAI API) per chi non ha abbonamento.
//
// `ProviderID` è una `String` raw (Codable) così che Settings e cache su disco restino
// stabili anche se aggiungiamo provider in futuro: un raw sconosciuto è semplicemente
// ignorato (forward-compatible), non rompe il decode.

/// Identità stabile di un provider. Il raw value è persistito in Settings/cache.
public enum ProviderID: String, Sendable, Equatable, Hashable, CaseIterable, Codable {
    /// Claude (abbonamento Max → limiti). Default storico dell'app.
    case claude
    /// Codex / ChatGPT plan (limiti sessione/settimana) + OpenAI Admin/usage.
    case codex
    /// Gemini (API key → usage/costo).
    case gemini
    /// Cursor (plan usage).
    case cursor
    /// Anthropic API "a consumo" (API key → usage/costo, niente limiti-piano).
    case anthropicAPI = "anthropic_api"
    /// OpenAI API "a consumo" (API key → usage/costo).
    case openaiAPI = "openai_api"

    /// Nome leggibile di default (può essere sovrascritto dal `ProviderDescriptor`).
    public var defaultDisplayName: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        case .gemini: "Gemini"
        case .cursor: "Cursor"
        case .anthropicAPI: "Anthropic API"
        case .openaiAPI: "OpenAI API"
        }
    }
}

import Foundation

// Descrizione statica di un provider: identità, capability, auth supportate, branding.
// È un value type `Sendable` puro (no AppKit): la UI lo legge per decidere cosa mostrare e
// quali controlli auth presentare in Impostazioni. Niente logica di rete qui (vedi `Provider`).

/// Capability di un provider: cosa è in grado di esporre. Guida il layout del pannello
/// (DECISIONS / BRIEF §"Modello concettuale": limiti vs usage+costo).
public struct ProviderCapabilities: Sendable, Equatable, Hashable, Codable {
    /// Espone finestre di utilizzo con `utilization %` + reset (abbonamento/piano). → vista "limiti".
    public var hasUsageLimits: Bool
    /// Espone usage token + costo per range (API a consumo). → vista "usage/costo".
    public var hasCostUsage: Bool
    /// Espone credito/budget residuo (es. crediti API prepagati).
    public var hasCredits: Bool
    /// Espone un cap settimanale per-modello separato (es. Claude Opus/Sonnet weekly).
    public var hasPerModelWeekly: Bool

    public init(
        hasUsageLimits: Bool,
        hasCostUsage: Bool,
        hasCredits: Bool = false,
        hasPerModelWeekly: Bool = false)
    {
        self.hasUsageLimits = hasUsageLimits
        self.hasCostUsage = hasCostUsage
        self.hasCredits = hasCredits
        self.hasPerModelWeekly = hasPerModelWeekly
    }

    /// Solo limiti-piano (come Claude/Codex/Cursor abbonamento).
    public static let limitsOnly = ProviderCapabilities(hasUsageLimits: true, hasCostUsage: false)
    /// Solo usage+costo (come le API a consumo).
    public static let costOnly = ProviderCapabilities(hasUsageLimits: false, hasCostUsage: true)
}

/// Metodo di autenticazione supportato da un provider. I SEGRETI vanno SEMPRE in Keychain
/// (vincolo BRIEF), mai su disco in chiaro. Vedi `ProviderAuthStoring`.
public enum ProviderAuthKind: String, Sendable, Equatable, Hashable, CaseIterable, Codable {
    /// OAuth con token gestiti da una CLI/altra app (es. Claude Code). Lettura via Keychain
    /// di sistema; non "rubiamo" il refresh al proprietario (regola Claude esistente).
    case oauthManaged = "oauth_managed"
    /// API key inserita dall'utente, salvata da noi in Keychain. Caso "a consumo".
    case apiKey = "api_key"
    /// Sessione via cookie del browser. OPZIONALE/stretch (più invasivo): non blocca l'MVP.
    case browserCookie = "browser_cookie"
}

/// Branding NEUTRO del provider (DECISIONS §3 vetro neutro): nessun colore di brand nell'MVP.
/// Teniamo solo un nome simbolo SF e un identificatore di accent semantico opzionale, che la UI
/// può ignorare per restare B/N. Non importiamo AppKit/SwiftUI qui.
public struct ProviderBranding: Sendable, Equatable, Hashable, Codable {
    /// Nome di un SF Symbol di fallback per il provider (la UI può sostituirlo con un asset).
    public var symbolName: String
    /// URL della dashboard ufficiale (apribile dal pannello/Impostazioni). Opzionale.
    public var dashboardURL: String?

    public init(symbolName: String, dashboardURL: String? = nil) {
        self.symbolName = symbolName
        self.dashboardURL = dashboardURL
    }
}

/// Descrizione statica e `Sendable` di un provider.
public struct ProviderDescriptor: Sendable, Equatable, Hashable, Codable {
    public var id: ProviderID
    /// Nome leggibile (default da `ProviderID`, sovrascrivibile).
    public var displayName: String
    public var capabilities: ProviderCapabilities
    /// Metodi auth supportati, in ordine di preferenza per l'auto-detect.
    public var authKinds: [ProviderAuthKind]
    public var branding: ProviderBranding
    /// true se è un provider "primario" candidabile a default automatico (es. Claude/Codex).
    public var isPrimaryCandidate: Bool

    public init(
        id: ProviderID,
        displayName: String? = nil,
        capabilities: ProviderCapabilities,
        authKinds: [ProviderAuthKind],
        branding: ProviderBranding,
        isPrimaryCandidate: Bool = false)
    {
        self.id = id
        self.displayName = displayName ?? id.defaultDisplayName
        self.capabilities = capabilities
        self.authKinds = authKinds
        self.branding = branding
        self.isPrimaryCandidate = isPrimaryCandidate
    }
}

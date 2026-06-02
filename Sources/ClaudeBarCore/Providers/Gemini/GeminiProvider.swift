import Foundation

// `GeminiProvider`: provider a LIMITI via OAuth della Gemini CLI. Decisione utente
// (docs/plan/mp/DECISIONS.md §Addendum): Gemini = OAuth CLI (~/.gemini/oauth_creds.json) → quote
// giornaliere per-modello (layout limiti), NON API key (la key Google AI Studio non espone usage).
//
// Disponibilità: se la Gemini CLI non è loggata (nessuna cred OAuth) o è in modalità api-key/
// vertex-ai → provider NON disponibile (`detectAvailability` = unavailable, no rete). Il pannello
// lo mostra come "configurabile, nessun dato" (degrada con grazia). Nessun segreto da salvare in
// Keychain: le credenziali sono il file gestito dalla Gemini CLI (auth `.oauthManaged`).

/// Reader della disponibilità OAuth della Gemini CLI (no rete: solo lettura file).
public enum GeminiOAuthCredential {
    /// true se esistono credenziali OAuth utilizzabili (auth personale, non api-key/vertex-ai).
    public static func isAvailable(homeDirectory: String) -> Bool {
        GeminiOAuthEndpoint.hasUsableCredentials(homeDirectory: homeDirectory)
    }
}

public struct GeminiProvider: Provider {
    private let homeDirectory: String
    private let loader: GeminiOAuthDataLoader

    public init(
        homeDirectory: String = NSHomeDirectory(),
        session: URLSession = .shared)
    {
        self.homeDirectory = homeDirectory
        self.loader = GeminiOAuthEndpoint.defaultLoader(session)
    }

    /// Init con loader iniettabile (per i test: niente rete).
    init(homeDirectory: String, loader: @escaping GeminiOAuthDataLoader) {
        self.homeDirectory = homeDirectory
        self.loader = loader
    }

    public var descriptor: ProviderDescriptor {
        ProviderDescriptor(
            id: .gemini,
            capabilities: ProviderCapabilities(hasUsageLimits: true, hasCostUsage: false),
            authKinds: [.oauthManaged],
            branding: ProviderBranding(
                symbolName: "sparkles",
                dashboardURL: "https://gemini.google.com"),
            isPrimaryCandidate: false)
    }

    public func strategies(for _: ProviderFetchContext) async -> [any ProviderFetchStrategy] {
        [GeminiOAuthStrategy(homeDirectory: self.homeDirectory, loader: self.loader)]
    }

    public func detectAvailability(_: ProviderFetchContext) async -> ProviderAvailability {
        guard GeminiOAuthCredential.isAvailable(homeDirectory: self.homeDirectory)
        else { return .unavailable }
        return ProviderAvailability(isAvailable: true, detectedAuth: .oauthManaged)
    }
}

/// Strategia OAuth Gemini: legge le credenziali della Gemini CLI, recupera le quote per-modello
/// (cloudcode-pa) e le proietta in `ProviderSnapshot` a limiti (windows = Pro/Flash/Flash-Lite).
struct GeminiOAuthStrategy: ProviderFetchStrategy {
    let homeDirectory: String
    let loader: GeminiOAuthDataLoader
    let id = "gemini.oauth"
    let kind: ProviderFetchKind = .oauthManaged

    func isAvailable(_: ProviderFetchContext) async -> Bool {
        GeminiOAuthCredential.isAvailable(homeDirectory: self.homeDirectory)
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderSnapshot {
        try await GeminiUsageFetcher.fetch(
            homeDirectory: self.homeDirectory,
            loader: self.loader,
            now: context.now())
    }
}

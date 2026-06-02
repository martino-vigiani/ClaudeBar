import Foundation

// `CursorProvider`: provider "abbonamento/limiti" per il piano Cursor (Pro/Hobby/Team/Enterprise).
// Capability: usage-limiti (BRIEF §"Modello concettuale" → vista limiti come Claude). Lo snapshot
// ha `windows` valorizzato (Total/Auto/API) + `credits` per la spesa on-demand oltre il piano.
//
// AUTH: Cursor NON ha API key né OAuth pubblico. L'unica auth reale è il COOKIE di sessione
// (cursor.com). Per rispettare "zero dipendenze" + "segreti in Keychain", NON leggiamo i cookie dal
// browser (come CodexBar con SweetCookieKit): l'utente incolla il proprio cookie header dalle
// DevTools (Impostazioni) e lo salviamo in Keychain via `ProviderSecretStoring` (provider `.cursor`,
// account `default`). L'auto-import dei cookie dal browser è uno stretch post-MVP.
//
// `authKinds = [.browserCookie]`: semanticamente è una sessione cookie, non una API key. Lo store
// dei segreti è lo stesso (un cookie header è un segreto come una key).

/// Reader del cookie header di Cursor: Keychain (primario) → env (comodità dev).
public enum CursorCredential {
    /// Env var di comodità per lo sviluppo (cookie header completo).
    public static let environmentKeys = ["CURSOR_COOKIE", "CURSOR_COOKIE_HEADER"]

    /// Risolve il cookie header: prima il Keychain (account `default`), poi l'ambiente.
    public static func resolve(
        store: any ProviderSecretStoring,
        environment: [String: String]) -> String?
    {
        if let fromStore = (try? store.secret(provider: .cursor, account: KeychainSecretStore.defaultAccount)) ?? nil,
           let cleaned = clean(fromStore)
        {
            return cleaned
        }
        for key in self.environmentKeys {
            if let cleaned = clean(environment[key]) { return cleaned }
        }
        return nil
    }

    /// true se un cookie header è presente (no rete) — per l'auto-detect.
    public static func isAvailable(store: any ProviderSecretStoring, environment: [String: String]) -> Bool {
        self.resolve(store: store, environment: environment) != nil
    }

    static func clean(_ raw: String?) -> String? {
        guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        if (value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'")) {
            value = String(value.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return value.isEmpty ? nil : value
    }
}

public struct CursorProvider: Provider {
    private let secretStore: any ProviderSecretStoring
    private let loader: CursorDataLoader

    public init(
        secretStore: any ProviderSecretStoring = KeychainSecretStore(),
        session: URLSession = .shared)
    {
        self.secretStore = secretStore
        self.loader = CursorUsageEndpoint.defaultLoader(session)
    }

    /// Init con loader iniettabile (per i test: niente rete).
    init(secretStore: any ProviderSecretStoring, loader: @escaping CursorDataLoader) {
        self.secretStore = secretStore
        self.loader = loader
    }

    public var descriptor: ProviderDescriptor {
        ProviderDescriptor(
            id: .cursor,
            capabilities: ProviderCapabilities(hasUsageLimits: true, hasCostUsage: false, hasCredits: true),
            authKinds: [.browserCookie],
            branding: ProviderBranding(
                symbolName: "cursorarrow.rays",
                dashboardURL: "https://cursor.com/dashboard?tab=usage"),
            isPrimaryCandidate: false)
    }

    public func strategies(for _: ProviderFetchContext) async -> [any ProviderFetchStrategy] {
        [CursorCookieStrategy(secretStore: self.secretStore, loader: self.loader)]
    }

    public func detectAvailability(_ context: ProviderFetchContext) async -> ProviderAvailability {
        guard CursorCredential.isAvailable(store: self.secretStore, environment: context.environment)
        else { return .unavailable }
        let label = (try? self.secretStore.accounts(provider: .cursor))?.first
        return ProviderAvailability(isAvailable: true, detectedAuth: .browserCookie, accountLabel: label)
    }
}

/// Strategia cookie Cursor: legge il cookie header dal Keychain/env, scarica `usage-summary`,
/// proietta in `ProviderSnapshot` (windows = Total/Auto/API, credits = on-demand USD).
struct CursorCookieStrategy: ProviderFetchStrategy {
    let secretStore: any ProviderSecretStoring
    let loader: CursorDataLoader
    let id = "cursor.cookie"
    let kind: ProviderFetchKind = .browserCookie

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        CursorCredential.isAvailable(store: self.secretStore, environment: context.environment)
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderSnapshot {
        guard let cookieHeader = CursorCredential.resolve(
            store: self.secretStore, environment: context.environment)
        else { throw ProviderError.noCredentials }

        return try await CursorUsageFetcher.fetch(
            cookieHeader: cookieHeader,
            loader: self.loader,
            now: context.now())
    }
}

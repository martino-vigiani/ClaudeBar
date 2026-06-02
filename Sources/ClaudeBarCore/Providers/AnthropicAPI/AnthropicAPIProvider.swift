import Foundation

// `AnthropicAPIProvider`: provider "API a consumo" per chi usa l'API key Anthropic (NON
// l'abbonamento Claude Max → quello e' `.claude`, OAuth). Capability: SOLO usage+costo, niente
// finestre-limite (BRIEF §"API a consumo"). Lo snapshot ha `windows = []` e `cost` valorizzato,
// cosi' la UI sceglie il layout "usage + costo".
//
// AUTH: API key Admin (`sk-ant-admin...`) salvata da NOI in Keychain via `ProviderSecretStoring`
// (vincolo BRIEF: segreti SEMPRE in Keychain). In sviluppo si accetta anche un'env var.
// La risoluzione e' Keychain > env (la fonte stabile e' il Keychain).

/// Reader della credenziale Anthropic API: Keychain (primario) → env (comodita' dev).
public enum AnthropicAPICredential {
    /// Env var compatibili (allineate a CodexBar/Anthropic): chiave Admin org.
    public static let environmentKeys = ["ANTHROPIC_ADMIN_KEY", "ANTHROPIC_ADMIN_API_KEY"]

    /// Messaggio d'avviso (DECISIONS MP §5): l'Admin API richiede una key di account ORG. Mostrato
    /// quando manca la key o il server risponde 401/403 → il provider resta VISIBILE con avviso.
    public static let adminKeyRequiredMessage =
        "Richiede una Admin API key di account organizzazione Anthropic (Console → Admin keys)."

    /// Risolve l'API key: prima il Keychain (account `default`), poi l'ambiente.
    public static func resolve(
        store: any ProviderSecretStoring,
        environment: [String: String]) -> String?
    {
        if let fromStore = (try? store.secret(provider: .anthropicAPI, account: KeychainSecretStore.defaultAccount)) ?? nil,
           let cleaned = clean(fromStore)
        {
            return cleaned
        }
        for key in self.environmentKeys {
            if let cleaned = clean(environment[key]) { return cleaned }
        }
        return nil
    }

    /// true se una credenziale e' presente (no rete) — per l'auto-detect.
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

public struct AnthropicAPIProvider: Provider {
    private let secretStore: any ProviderSecretStoring
    private let session: URLSession

    public init(
        secretStore: any ProviderSecretStoring = KeychainSecretStore(),
        session: URLSession = .shared)
    {
        self.secretStore = secretStore
        self.session = session
    }

    public var descriptor: ProviderDescriptor {
        ProviderDescriptor(
            id: .anthropicAPI,
            capabilities: .costOnly,
            authKinds: [.apiKey],
            branding: ProviderBranding(
                symbolName: "key.horizontal",
                dashboardURL: "https://console.anthropic.com/settings/usage"),
            isPrimaryCandidate: false)
    }

    public func strategies(for _: ProviderFetchContext) async -> [any ProviderFetchStrategy] {
        [AnthropicAPIKeyStrategy(secretStore: self.secretStore, session: self.session)]
    }

    public func detectAvailability(_ context: ProviderFetchContext) async -> ProviderAvailability {
        guard AnthropicAPICredential.isAvailable(store: self.secretStore, environment: context.environment)
        else { return .unavailable }
        let label = (try? self.secretStore.accounts(provider: .anthropicAPI))?.first
        return ProviderAvailability(isAvailable: true, detectedAuth: .apiKey, accountLabel: label)
    }
}

/// Strategia API key Anthropic: legge la chiave dal Keychain/env, scarica usage+costo, proietta
/// in `ProviderSnapshot` (windows vuoto, cost valorizzato).
struct AnthropicAPIKeyStrategy: ProviderFetchStrategy {
    let secretStore: any ProviderSecretStoring
    let session: URLSession
    let id = "anthropic.api"
    let kind: ProviderFetchKind = .apiKey

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        AnthropicAPICredential.isAvailable(store: self.secretStore, environment: context.environment)
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderSnapshot {
        guard let apiKey = AnthropicAPICredential.resolve(
            store: self.secretStore, environment: context.environment)
        else { throw ProviderError.unauthorized(AnthropicAPICredential.adminKeyRequiredMessage) }

        let now = context.now()
        let cost: ProviderCostUsage
        do {
            cost = try await AnthropicAPIUsageFetcher.fetchCostUsage(
                apiKey: apiKey,
                historyDays: context.costHistoryDays,
                session: self.session,
                now: now)
        } catch ProviderError.unauthorized {
            // 401/403: key non valida o senza permessi org → avviso chiaro, provider VISIBILE.
            throw ProviderError.unauthorized(AnthropicAPICredential.adminKeyRequiredMessage)
        }

        return ProviderSnapshot(
            providerID: .anthropicAPI,
            windows: [],
            cost: cost,
            credits: nil,
            identity: ProviderAccountIdentity(plan: "pay-as-you-go"),
            fetchedAt: now,
            source: .live)
    }
}

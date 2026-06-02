import Foundation

// `OpenAIAPIProvider`: provider "API a consumo" per chi usa l'API key OpenAI (NON l'abbonamento
// ChatGPT/Codex → quello e' `.codex`, gestito da codex-engineer). ID distinti, nessuna
// sovrapposizione. Capability: SOLO usage+costo (+ credito opzionale via fallback legacy).
//
// AUTH: API key Admin (`sk-admin-...`) salvata da NOI in Keychain via `ProviderSecretStoring`.
// In sviluppo si accetta anche un'env var. Risoluzione Keychain > env.

/// Reader della credenziale OpenAI API: Keychain (primario) → env (comodita' dev).
public enum OpenAIAPICredential {
    /// Env var compatibili (Admin key preferita, poi API key). Allineate a CodexBar/OpenAI.
    public static let apiKeyEnvironmentKeys = ["OPENAI_ADMIN_KEY", "OPENAI_API_KEY"]
    public static let projectIDEnvironmentKey = "OPENAI_PROJECT_ID"

    /// Messaggio d'avviso (DECISIONS MP §5): l'Organization Usage API richiede una Admin key org.
    /// Mostrato quando manca la key o il server risponde 401/403 → provider VISIBILE con avviso.
    public static let adminKeyRequiredMessage =
        "Richiede una Admin API key di account organizzazione OpenAI (platform.openai.com → Admin keys)."

    public struct Resolved: Sendable, Equatable {
        public let apiKey: String
        public let projectID: String?
    }

    /// Risolve API key + projectID: prima il Keychain (account `default`), poi l'ambiente.
    public static func resolve(
        store: any ProviderSecretStoring,
        environment: [String: String]) -> Resolved?
    {
        let apiKey: String?
        if let fromStore = (try? store.secret(provider: .openaiAPI, account: KeychainSecretStore.defaultAccount)) ?? nil,
           let cleaned = clean(fromStore)
        {
            apiKey = cleaned
        } else {
            apiKey = self.apiKeyEnvironmentKeys.lazy.compactMap { clean(environment[$0]) }.first
        }
        guard let key = apiKey else { return nil }
        return Resolved(apiKey: key, projectID: clean(environment[self.projectIDEnvironmentKey]))
    }

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

public struct OpenAIAPIProvider: Provider {
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
            id: .openaiAPI,
            capabilities: ProviderCapabilities(hasUsageLimits: false, hasCostUsage: true, hasCredits: true),
            authKinds: [.apiKey],
            branding: ProviderBranding(
                symbolName: "key.horizontal",
                dashboardURL: "https://platform.openai.com/usage"),
            isPrimaryCandidate: false)
    }

    public func strategies(for _: ProviderFetchContext) async -> [any ProviderFetchStrategy] {
        [OpenAIAPIKeyStrategy(secretStore: self.secretStore, session: self.session)]
    }

    public func detectAvailability(_ context: ProviderFetchContext) async -> ProviderAvailability {
        guard OpenAIAPICredential.isAvailable(store: self.secretStore, environment: context.environment)
        else { return .unavailable }
        let label = (try? self.secretStore.accounts(provider: .openaiAPI))?.first
        return ProviderAvailability(isAvailable: true, detectedAuth: .apiKey, accountLabel: label)
    }
}

/// Strategia API key OpenAI: legge la chiave dal Keychain/env, scarica usage+costo (+credito
/// fallback), proietta in `ProviderSnapshot` (windows vuoto, cost/credits valorizzati).
struct OpenAIAPIKeyStrategy: ProviderFetchStrategy {
    let secretStore: any ProviderSecretStoring
    let session: URLSession
    let id = "openai.api"
    let kind: ProviderFetchKind = .apiKey

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        OpenAIAPICredential.isAvailable(store: self.secretStore, environment: context.environment)
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderSnapshot {
        guard let resolved = OpenAIAPICredential.resolve(
            store: self.secretStore, environment: context.environment)
        else { throw ProviderError.unauthorized(OpenAIAPICredential.adminKeyRequiredMessage) }

        let now = context.now()
        let result: OpenAIAPIFetchResult
        do {
            result = try await OpenAIAPIUsageFetcher.fetch(
                apiKey: resolved.apiKey,
                projectID: resolved.projectID,
                historyDays: context.costHistoryDays,
                session: self.session,
                now: now)
        } catch ProviderError.unauthorized {
            // 401/403 sia su Admin usage sia sul fallback credito → avviso chiaro, provider VISIBILE.
            throw ProviderError.unauthorized(OpenAIAPICredential.adminKeyRequiredMessage)
        }

        return ProviderSnapshot(
            providerID: .openaiAPI,
            windows: [],
            cost: result.cost,
            credits: result.credits,
            identity: ProviderAccountIdentity(
                organization: resolved.projectID.map { "Project: \($0)" },
                plan: "pay-as-you-go"),
            fetchedAt: now,
            source: .live)
    }
}

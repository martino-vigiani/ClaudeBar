import Foundation

// `ClaudeProvider`: il provider Claude dietro l'astrazione multi-provider.
//
// REFACTOR SENZA REGRESSIONI: NON riscrive la logica limiti. Avvolge l'attore esistente e
// testato `ClaudeLimitsService` (OAuth + Keychain + endpoint usage + gate 429 + refresh) e ne
// proietta l'output in `ProviderSnapshot` via `LimitsSnapshot.asProviderSnapshot()`. Tutta la
// logica delicata (regola "non rubare il refresh alla CLI", no-UI in background, degradazione
// 429) resta dov'era. `ClaudeLimitsService` continua a esistere e i suoi test restano verdi.
//
// Auth: `.oauthManaged` (token di Claude Code letti dal Keychain di sistema). L'API key
// Anthropic "a consumo" è un PROVIDER SEPARATO (`.anthropicAPI`, apikeys-engineer), non qui.

public struct ClaudeProvider: Provider {
    private let service: ClaudeLimitsService

    public init(service: ClaudeLimitsService = ClaudeLimitsService()) {
        self.service = service
    }

    public var descriptor: ProviderDescriptor {
        ProviderDescriptor(
            id: .claude,
            capabilities: ProviderCapabilities(
                hasUsageLimits: true,
                hasCostUsage: false,
                hasCredits: false,
                hasPerModelWeekly: true),
            authKinds: [.oauthManaged],
            branding: ProviderBranding(
                symbolName: "sparkles",
                dashboardURL: "https://claude.ai/settings/usage"),
            isPrimaryCandidate: true)
    }

    public func strategies(for _: ProviderFetchContext) async -> [any ProviderFetchStrategy] {
        [ClaudeOAuthStrategy(service: self.service)]
    }

    public func cachedSnapshot() async -> ProviderSnapshot? {
        await self.service.cachedSnapshot()?.asProviderSnapshot()
    }

    public func detectAvailability(_ context: ProviderFetchContext) async -> ProviderAvailability {
        // No-UI: enumera il Keychain di Claude Code senza prompt. Disponibile se c'è un item.
        let available = (try? KeychainReader.readMostRecent(allowUI: false)) ?? nil
        // Anche un token via env conta come disponibile (debug/test).
        let hasEnvToken = !(context.environment["CLAUDEBAR_OAUTH_TOKEN"]?.isEmpty ?? true)
        guard available != nil || hasEnvToken else { return .unavailable }
        return ProviderAvailability(
            isAvailable: true,
            detectedAuth: .oauthManaged,
            accountLabel: available?.account)
    }
}

/// Strategia OAuth di Claude: delega al `ClaudeLimitsService` esistente e proietta in snapshot.
struct ClaudeOAuthStrategy: ProviderFetchStrategy {
    let service: ClaudeLimitsService
    let id = "claude.oauth"
    let kind: ProviderFetchKind = .oauthManaged

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        // Disponibile se c'è un token via env o un item nel Keychain (no prompt in background).
        if !(context.environment["CLAUDEBAR_OAUTH_TOKEN"]?.isEmpty ?? true) { return true }
        let item = (try? KeychainReader.readMostRecent(allowUI: false)) ?? nil
        return item != nil
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderSnapshot {
        do {
            let limits = try await self.service.fetchUsage(userInitiated: context.userInitiated)
            return limits.asProviderSnapshot()
        } catch let error as ClaudeLimitsError {
            // Riusa la traduzione 1:1 verso l'errore provider-agnostico.
            throw error.asProviderError
        }
    }

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool {
        // Claude ha una sola strategia nell'MVP: nessun fallback, l'errore va in superficie.
        false
    }
}

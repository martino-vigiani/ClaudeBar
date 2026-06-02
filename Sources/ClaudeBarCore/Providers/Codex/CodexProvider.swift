import Foundation

// `CodexProvider`: il provider Codex / ChatGPT plan (abbonamento) dietro l'astrazione
// multi-provider. Famiglia "abbonamento/limiti": espone le finestre sessione/settimana
// dell'endpoint `wham/usage` (+ credits pay-as-you-go) — la STESSA UX a finestre di Claude.
//
// AUTH: `.oauthManaged`. I token OAuth sono prodotti dalla CLI `codex` e salvati in
// `~/.codex/auth.json`. Li LEGGIAMO soltanto. In sviluppo si accetta anche un access token via
// env (`CLAUDEBAR_CODEX_TOKEN`).
//
// REGOLA DI REFRESH (come Claude): il refresh token di Codex è ROTANTE → rinnovarlo noi
// invaliderebbe la sessione della CLI. Di DEFAULT deleghiamo: se il token è scaduto/rifiutato,
// emettiamo `refreshDelegatedToOwner` ("apri/usa `codex` per ri-autenticare"). Il refresh nostro
// è opt-in (`allowSelfRefresh`), per scenari in cui ClaudeBar è l'unico client.
//
// L'usage/costo "a consumo" via Admin API è un PROVIDER SEPARATO (`.openaiAPI`), non qui:
// ID distinti, nessuna sovrapposizione.

public struct CodexProvider: Provider {
    private let session: URLSession
    /// Se true, su token scaduto proviamo il refresh OAuth noi (rischio: invalida la CLI).
    /// Default false = deleghiamo alla CLI (parità con la policy Claude).
    private let allowSelfRefresh: Bool

    public init(session: URLSession = CodexProvider.makeSession(), allowSelfRefresh: Bool = false) {
        self.session = session
        self.allowSelfRefresh = allowSelfRefresh
    }

    /// URLSession dedicata: timeout 30s, no cookie, no cache su disco (come `ClaudeLimitsService`).
    public static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.httpCookieStorage = nil
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }

    /// Env var con un access token Codex pronto (debug/test): salta lettura file e refresh.
    public static let tokenEnvironmentKey = "CLAUDEBAR_CODEX_TOKEN"

    public var descriptor: ProviderDescriptor {
        // v1 (decisione team-lead): Codex = SOLO limiti-piano + credits via OAuth → `hasCostUsage`
        // è FALSE, così la UI non mostra una sezione costo vuota. Il costo "a consumo" OpenAI è
        // coperto dal provider distinto `.openaiAPI`.
        // TODO: una futura strategia Admin API key per Codex potrà popolare il blocco `cost` dello
        // snapshot; in quel caso rialzare `hasCostUsage` a true.
        ProviderDescriptor(
            id: .codex,
            capabilities: ProviderCapabilities(
                hasUsageLimits: true,
                hasCostUsage: false,
                hasCredits: true,
                hasPerModelWeekly: true),
            authKinds: [.oauthManaged, .apiKey],
            branding: ProviderBranding(
                symbolName: "chevron.left.forwardslash.chevron.right",
                dashboardURL: "https://chatgpt.com/codex/settings/usage"),
            isPrimaryCandidate: true)
    }

    public func strategies(for _: ProviderFetchContext) async -> [any ProviderFetchStrategy] {
        [CodexOAuthStrategy(session: self.session, allowSelfRefresh: self.allowSelfRefresh)]
    }

    public func detectAvailability(_ context: ProviderFetchContext) async -> ProviderAvailability {
        // Token via env (debug) → disponibile.
        if !(context.environment[Self.tokenEnvironmentKey]?.isEmpty ?? true) {
            return ProviderAvailability(isAvailable: true, detectedAuth: .oauthManaged)
        }
        // Presenza di auth.json leggibile → disponibile (no rete, no prompt).
        guard let credentials = try? CodexOAuthCredentialsStore.load(env: context.environment) else {
            return .unavailable
        }
        let claims = credentials.idToken.flatMap(CodexSnapshotMapper.decodeJWTClaims)
        let label = (claims?["email"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return ProviderAvailability(isAvailable: true, detectedAuth: .oauthManaged, accountLabel: label)
    }
}

/// Strategia OAuth di Codex: carica credenziali (env → auth.json) → (refresh/delega) →
/// GET wham/usage → proietta in `ProviderSnapshot`.
struct CodexOAuthStrategy: ProviderFetchStrategy {
    let session: URLSession
    let allowSelfRefresh: Bool
    let id = "codex.oauth"
    let kind: ProviderFetchKind = .oauthManaged

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        if !(context.environment[CodexProvider.tokenEnvironmentKey]?.isEmpty ?? true) { return true }
        return (try? CodexOAuthCredentialsStore.load(env: context.environment)) != nil
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderSnapshot {
        let now = context.now()
        var credentials = try self.loadCredentials(context: context, now: now)

        // Refresh proattivo opt-in: solo se abilitato, c'è un refresh token e il token è "vecchio".
        if self.allowSelfRefresh, !credentials.refreshToken.isEmpty, credentials.needsRefresh {
            credentials = try await CodexTokenRefresher.refresh(credentials, session: self.session, now: now)
        }

        do {
            let response = try await CodexUsageEndpoint.fetch(
                accessToken: credentials.accessToken,
                accountId: credentials.accountId,
                session: self.session,
                env: context.environment,
                now: now)
            return CodexSnapshotMapper.makeSnapshot(
                from: response,
                credentials: credentials,
                accountLabel: nil,
                now: now,
                source: .live)
        } catch let error as ProviderError {
            throw self.mapUsageError(error, credentials: credentials)
        }
    }

    /// Su 401/403 (token scaduto): se non possiamo/vogliamo rinnovare noi, deleghiamo alla CLI
    /// (`refreshDelegatedToOwner`) così la UI suggerisce di usare `codex` invece di un generico
    /// "non autorizzato". Con `allowSelfRefresh` e refresh token assente, resta `unauthorized`.
    private func mapUsageError(_ error: ProviderError, credentials: CodexOAuthCredentials) -> ProviderError {
        guard case .unauthorized = error else { return error }
        if !self.allowSelfRefresh, !credentials.refreshToken.isEmpty {
            return .refreshDelegatedToOwner
        }
        return error
    }

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool {
        // Codex ha una sola strategia nell'MVP: nessun fallback, l'errore va in superficie.
        false
    }

    /// Catena di lettura credenziali: env (debug) → auth.json (+ eventuale refresh opt-in).
    private func loadCredentials(context: ProviderFetchContext, now: Date) throws -> CodexOAuthCredentials {
        if let token = context.environment[CodexProvider.tokenEnvironmentKey],
           !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return CodexOAuthCredentials(
                accessToken: token.trimmingCharacters(in: .whitespacesAndNewlines),
                refreshToken: "",
                idToken: nil,
                accountId: nil,
                lastRefresh: now)
        }

        let credentials: CodexOAuthCredentials
        do {
            credentials = try CodexOAuthCredentialsStore.load(env: context.environment)
        } catch let error as CodexOAuthCredentialsError {
            switch error {
            case .notFound, .missingTokens:
                throw ProviderError.noCredentials
            case .decodeFailed:
                throw ProviderError.invalidResponse
            }
        }
        return credentials
    }
}

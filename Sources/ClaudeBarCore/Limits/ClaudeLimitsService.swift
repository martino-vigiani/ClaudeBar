import Foundation

// Orchestratore dei limiti ufficiali (actor): credenziali → (refresh) → GET usage → snapshot.
// Implementa: catena di lettura credenziali, regola "non rubare il refresh alla CLI",
// gate 429 locale (mostra cache con badge stale), cache in memoria dell'ultimo snapshot.

public actor ClaudeLimitsService {
    private let session: URLSession
    private let claudeCodeVersion: String?
    private let environment: [String: String]
    private let now: @Sendable () -> Date

    /// Ultimo snapshot riuscito (per cachedSnapshot / degradazione su 429).
    private var lastSnapshot: LimitsSnapshot?
    /// Cache credenziali in memoria (owner .claudeBar dopo un refresh nostro).
    private var cachedCredentials: CredentialRecord?
    /// Gate 429: non rifacciamo la GET prima di questo istante.
    private var blockedUntil: Date?

    public init(
        session: URLSession = ClaudeLimitsService.makeSession(),
        claudeCodeVersion: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        now: @escaping @Sendable () -> Date = { Date() })
    {
        self.session = session
        self.claudeCodeVersion = claudeCodeVersion
        self.environment = environment
        self.now = now
    }

    /// URLSession dedicata: timeout 30s, no cookie, no cache su disco.
    public static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.httpCookieStorage = nil
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }

    /// Ultimo snapshot riuscito, senza rete (per il primo paint).
    public func cachedSnapshot() -> LimitsSnapshot? { lastSnapshot }

    /// Recupera i limiti correnti.
    /// - Parameter userInitiated: se `true`, il Keychain può mostrare il prompt (apertura
    ///   pannello / Refresh manuale); se `false` (timer), usa query no-UI.
    public func fetchUsage(userInitiated: Bool) async throws -> LimitsSnapshot {
        let current = now()

        // Gate 429: se siamo bloccati, restituisci la cache marcata stale (o lancia se non c'è).
        if let until = blockedUntil, current < until {
            if let cached = lastSnapshot {
                return cached.markedStale()
            }
            throw ClaudeLimitsError.rateLimited(retryAfter: until)
        }

        // 1. Carica credenziali (env → cache memoria → Keychain).
        let record = try loadRecord(allowUI: userInitiated)

        // 2. Se scaduto, applica la regola di refresh per owner.
        let credentials = try await resolveFreshCredentials(record: record)

        // 3. GET usage.
        do {
            let raw = try await ClaudeUsageEndpoint.fetch(
                accessToken: credentials.accessToken,
                claudeCodeVersion: claudeCodeVersion,
                session: session,
                now: current)
            blockedUntil = nil
            let snapshot = makeSnapshot(
                from: raw,
                credentials: credentials,
                accountLabel: record.source == .environment ? "env" : (record.accountLabel ?? ""),
                now: current)
            lastSnapshot = snapshot
            return snapshot
        } catch let ClaudeLimitsError.rateLimited(retryAfter) {
            // Imposta il gate; restituisci cache stale se disponibile.
            blockedUntil = retryAfter ?? current.addingTimeInterval(backoffSeconds())
            if let cached = lastSnapshot {
                return cached.markedStale()
            }
            throw ClaudeLimitsError.rateLimited(retryAfter: blockedUntil)
        }
    }

    // MARK: - Credenziali

    private func loadRecord(allowUI: Bool) throws -> CredentialRecord {
        // 1. Env var (debug/test).
        if let token = environment["CLAUDEBAR_OAUTH_TOKEN"], !token.isEmpty {
            let creds = ClaudeOAuthCredentials(
                accessToken: token,
                refreshToken: nil,
                expiresAt: now().addingTimeInterval(3600),
                scopes: [],
                rateLimitTier: nil,
                subscriptionType: environment["CLAUDEBAR_SUBSCRIPTION"] ?? "max")
            return CredentialRecord(credentials: creds, owner: .environment, source: .environment)
        }

        // 2. Cache in memoria (owner .claudeBar dopo refresh nostro), se ancora valida.
        if let cached = cachedCredentials, !cached.credentials.isExpired {
            return cached
        }

        // 3. Keychain (sorgente primaria su macOS). File ~/.claude/.credentials.json non
        //    presente sul sistema dell'utente; il Keychain copre il caso reale.
        guard let result = try KeychainReader.readMostRecent(allowUI: allowUI) else {
            throw ClaudeLimitsError.noCredentials
        }
        let creds = try ClaudeOAuthCredentials.parse(data: result.data)
        return CredentialRecord(
            credentials: creds,
            owner: .claudeCLI,
            source: .claudeKeychain,
            accountLabel: result.account)
    }

    /// Se il token è scaduto, applica la regola di refresh in base all'owner.
    private func resolveFreshCredentials(record: CredentialRecord) async throws -> ClaudeOAuthCredentials {
        let creds = record.credentials
        guard creds.isExpired else { return creds }

        switch record.owner {
        case .claudeCLI:
            // NON rubiamo il refresh alla CLI: rileggiamo il Keychain (Claude potrebbe aver
            // già rinnovato). Se ancora scaduto, deleghiamo.
            if let reread = try? KeychainReader.readMostRecent(allowUI: false),
               let fresh = try? ClaudeOAuthCredentials.parse(data: reread.data),
               !fresh.isExpired
            {
                return fresh
            }
            throw ClaudeLimitsError.refreshDelegatedToCLI

        case .environment:
            throw ClaudeLimitsError.noRefreshToken

        case .claudeBar:
            guard let rt = creds.refreshToken, !rt.isEmpty else {
                throw ClaudeLimitsError.noRefreshToken
            }
            let refreshed = try await ClaudeTokenRefresher.refresh(
                refreshToken: rt,
                existing: creds,
                session: session,
                now: now())
            cachedCredentials = CredentialRecord(
                credentials: refreshed,
                owner: .claudeBar,
                source: .memoryCache)
            return refreshed
        }
    }

    // MARK: - Mapping

    private func makeSnapshot(
        from raw: OAuthUsageResponse,
        credentials: ClaudeOAuthCredentials,
        accountLabel: String,
        now current: Date) -> LimitsSnapshot
    {
        func window(_ kind: PaceWindowKind, _ w: OAuthUsageWindow?) -> UsageWindow? {
            guard let w else { return nil }
            let util = max(0, min(100, w.utilization ?? 0))
            let resets = ClaudeUsageEndpoint.parseISO8601(w.resetsAt)
            var window = UsageWindow(kind: kind, utilization: util, resetsAt: resets)
            window.pace = PaceCalculator.project(
                kind: kind, utilization: util, resetsAt: resets, now: current)
            return window
        }

        // fiveHour e sevenDay sono non-opzionali (02 §11): se mancano, degrada a util 0.
        let five = window(.fiveHour, raw.fiveHour)
            ?? UsageWindow(kind: .fiveHour, utilization: 0, resetsAt: nil)
        let seven = window(.sevenDay, raw.sevenDay)
            ?? UsageWindow(kind: .sevenDay, utilization: 0, resetsAt: nil)

        return LimitsSnapshot(
            fiveHour: five,
            sevenDay: seven,
            sevenDayOpus: window(.sevenDayOpus, raw.sevenDayOpus),
            sevenDaySonnet: window(.sevenDaySonnet, raw.sevenDaySonnet),
            extraUsage: extraWindow(raw.extraUsage, now: current),
            subscriptionType: credentials.subscriptionType ?? "",
            accountLabel: accountLabel,
            fetchedAt: current,
            source: .live)
    }

    /// `extra_usage` modellato come finestra (utilization). Niente reset noto → no pace.
    private func extraWindow(_ extra: OAuthExtraUsage?, now _: Date) -> UsageWindow? {
        guard let extra, extra.isEnabled == true else { return nil }
        let util = max(0, min(100, extra.utilization ?? 0))
        // Riusiamo .sevenDay come kind contenitore: la UI distingue via il campo dedicato.
        return UsageWindow(kind: .sevenDay, utilization: util, resetsAt: nil)
    }

    /// Backoff esponenziale base quando manca `Retry-After` (cap 5 min).
    private func backoffSeconds() -> TimeInterval { 120 }
}

// MARK: - Helpers

private extension LimitsSnapshot {
    func markedStale() -> LimitsSnapshot {
        var copy = self
        copy.source = .stale
        return copy
    }
}

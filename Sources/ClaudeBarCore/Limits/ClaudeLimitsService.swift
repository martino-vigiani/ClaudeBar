import Foundation

// Orchestratore dei limiti ufficiali (actor): credenziali → (refresh) → GET usage → snapshot.
// Implementa: catena di lettura credenziali, regola "non rubare il refresh alla CLI",
// gate 429 locale (mostra cache con badge stale), cache in memoria dell'ultimo snapshot.

public actor ClaudeLimitsService {
    /// Seam di lettura del Keychain (owner Claude CLI): iniettabile per i test.
    /// Default = chiamata statica reale a `KeychainReader.readMostRecent(allowUI:)`.
    public typealias CredentialReader = @Sendable (_ allowUI: Bool) throws -> KeychainReader.ReadResult?

    /// Seam di SCRITTURA del Keychain (write-back del token auto-rinnovato): iniettabile per i test.
    /// Ritorna `true` se la scrittura è riuscita. Default = `KeychainReader.writeBack`.
    public typealias CredentialWriter = @Sendable (_ data: Data, _ persistentRef: Data) -> Bool

    private let session: URLSession
    private let claudeCodeVersion: String?
    private let environment: [String: String]
    private let now: @Sendable () -> Date
    private let credentialReader: CredentialReader
    private let credentialWriter: CredentialWriter

    /// Ultimo snapshot riuscito (per cachedSnapshot / degradazione su 429).
    private var lastSnapshot: LimitsSnapshot?
    /// Cache credenziali in memoria: read-through delle creds CLI (owner .claudeCLI)
    /// e creds rinnovate da noi (owner .claudeBar). Serve a non ricolpire il Keychain
    /// a ogni fetch dentro la validità del token → niente prompt password ripetuti.
    private var cachedCredentials: CredentialRecord?
    /// Gate 429: non rifacciamo la GET prima di questo istante.
    private var blockedUntil: Date?
    /// Self-refresh in volo: coalescing per evitare due refresh concorrenti che consumerebbero lo
    /// stesso refresh_token (Reconnect ravvicinati / doppio trigger). Il secondo chiamante aspetta il
    /// risultato del primo invece di lanciarne un altro.
    private var inFlightSelfRefresh: Task<ClaudeOAuthCredentials?, Error>?

    public init(
        session: URLSession = ClaudeLimitsService.makeSession(),
        claudeCodeVersion: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        now: @escaping @Sendable () -> Date = { Date() },
        credentialReader: @escaping CredentialReader = { try KeychainReader.readMostRecent(allowUI: $0) },
        credentialWriter: @escaping CredentialWriter = { KeychainReader.writeBack($0, persistentRef: $1) })
    {
        self.session = session
        self.claudeCodeVersion = claudeCodeVersion
        self.environment = environment
        self.now = now
        self.credentialReader = credentialReader
        self.credentialWriter = credentialWriter
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

        // 2. Se scaduto, applica la regola di refresh per owner. Su un Reconnect
        //    (userInitiated) il reread del Keychain può promptare → raccoglie un eventuale
        //    refresh appena scritto dalla CLI (item riscritto = ACL "Always Allow" nuovo).
        let credentials = try await resolveFreshCredentials(record: record, allowUI: userInitiated)

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
        guard let result = try credentialReader(allowUI) else {
            throw ClaudeLimitsError.noCredentials
        }
        CoreLog.keychain.info("[CRED] keychain hit allowUI=\(allowUI, privacy: .public) account=\(result.account ?? "nil")")
        let creds = try ClaudeOAuthCredentials.parse(data: result.data)
        let record = CredentialRecord(
            credentials: creds,
            owner: .claudeCLI,
            source: .claudeKeychain,
            accountLabel: result.account)
        // Read-through cache: serviamo i prossimi fetch dalla memoria finché il token è
        // valido, senza ricolpire il Keychain (→ niente prompt password ripetuti). Non
        // rinnoviamo noi il token CLI: quando scade, lo step 2 cade e rileggiamo il
        // Keychain (la CLI nel frattempo lo avrà rinnovato).
        cachedCredentials = record
        return record
    }

    /// Se il token è scaduto, applica la regola di refresh in base all'owner.
    /// - Parameter allowUI: propagato al reread del Keychain (owner .claudeCLI) → su un
    ///   Reconnect userInitiated il reread può promptare; in background resta no-UI.
    private func resolveFreshCredentials(record: CredentialRecord, allowUI: Bool) async throws -> ClaudeOAuthCredentials {
        let creds = record.credentials
        guard creds.isExpired else { return creds }

        switch record.owner {
        case .claudeCLI:
            // Prima chance: la CLI potrebbe aver GIÀ rinnovato → rileggiamo il Keychain.
            CoreLog.keychain.info("[CRED] token scaduto, rileggo keychain allowUI=\(allowUI, privacy: .public)")
            let reread = try? credentialReader(allowUI)
            if let reread,
               let fresh = try? ClaudeOAuthCredentials.parse(data: reread.data),
               !fresh.isExpired
            {
                // Aggiorna la read-through cache con le creds appena rinnovate dalla CLI.
                cachedCredentials = CredentialRecord(
                    credentials: fresh,
                    owner: .claudeCLI,
                    source: .claudeKeychain,
                    accountLabel: reread.account)
                return fresh
            }
            // Seconda chance: self-refresh + write-back nell'item CONDIVISO, SOLO su azione utente
            // (`allowUI`). Non "rubiamo" il refresh: rinnoviamo e RISCRIVIAMO l'item, così la CLI
            // ritrova il token nuovo e resta in sync. `selfRefreshClaudeCLI` ritorna nil se non è
            // sicuro (item non scrivibile) → cade sulla delega; throwa se il refresh fallisce.
            if allowUI, let reread, let ref = reread.persistentRef,
               let stale = try? ClaudeOAuthCredentials.parse(data: reread.data),
               let rt = stale.refreshToken, !rt.isEmpty,
               let refreshed = try await selfRefreshClaudeCLI(
                   original: reread.data, refreshToken: rt, existing: stale,
                   persistentRef: ref, account: reread.account)
            {
                return refreshed
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

    /// Self-refresh del token CLI con WRITE-BACK nell'item Keychain condiviso.
    ///
    /// Ridefinizione sicura della "regola d'oro": rinnovare il token della CLI è ammesso SOLO se
    /// subito dopo RISCRIVIAMO l'item condiviso. Altrimenti, se il server ruota il refresh_token,
    /// la CLI resterebbe col token vecchio (morto) → logout. Il PRE-CHECK di scrivibilità (write
    /// idempotente degli stessi byte) verifica a runtime che POTREMO riscrivere PRIMA di consumare
    /// il refresh_token: se non possiamo scrivere, non lo tocchiamo e deleghiamo alla CLI.
    ///
    /// - Returns: le creds rinnovate, oppure `nil` se non è sicuro procedere (→ il chiamante delega).
    /// - Throws: `refreshFailedTransient`/`refreshFailedTerminal` se il refresh di rete fallisce.
    private func selfRefreshClaudeCLI(
        original: Data,
        refreshToken rt: String,
        existing: ClaudeOAuthCredentials,
        persistentRef ref: Data,
        account: String?) async throws -> ClaudeOAuthCredentials?
    {
        // COALESCING: se un self-refresh è già in volo, aspetta IL SUO esito invece di lanciarne un
        // secondo — due refresh concorrenti consumerebbero lo stesso refresh_token e uno prenderebbe
        // invalid_grant (Reconnect ravvicinati / doppio trigger). I parametri del secondo chiamante
        // sono equivalenti: si refresha la STESSA credenziale condivisa.
        if let inFlight = inFlightSelfRefresh {
            return try await inFlight.value
        }
        let task = Task { [self] in
            try await performSelfRefresh(
                original: original, refreshToken: rt, existing: existing,
                persistentRef: ref, account: account)
        }
        inFlightSelfRefresh = task
        defer { inFlightSelfRefresh = nil }
        return try await task.value
    }

    /// Corpo del self-refresh (pre-check → refresh → write-back). Invocato dietro il coalescing di
    /// `selfRefreshClaudeCLI`, mai direttamente.
    private func performSelfRefresh(
        original: Data,
        refreshToken rt: String,
        existing: ClaudeOAuthCredentials,
        persistentRef ref: Data,
        account: String?) async throws -> ClaudeOAuthCredentials?
    {
        // 1) PRE-CHECK: write idempotente degli stessi byte. Se fallisce (ACL nega / no-UI in
        //    background), NON tocchiamo il refresh_token e deleghiamo: meglio "apri Claude" che
        //    rischiare di rompere il login della CLI.
        guard credentialWriter(original, ref) else {
            CoreLog.keychain.info("[CRED] self-refresh: pre-check write FALLITO → delego alla CLI")
            return nil
        }

        // 2) Refresh vero (consuma il refresh_token).
        let refreshed: ClaudeOAuthCredentials
        do {
            refreshed = try await ClaudeTokenRefresher.refresh(
                refreshToken: rt, existing: existing, session: session, now: now())
        } catch let ClaudeLimitsError.refreshFailedTerminal(message) {
            // refresh_token morto: la CLI può averlo ruotato CONCORRENTEMENTE. Reread una volta
            // (con UI: l'utente sta riconnettendo): se ora è fresco usalo, altrimenti ri-login.
            if let reread = try? credentialReader(true),
               let fresh = try? ClaudeOAuthCredentials.parse(data: reread.data), !fresh.isExpired
            {
                cachedCredentials = CredentialRecord(
                    credentials: fresh, owner: .claudeCLI, source: .claudeKeychain, accountLabel: reread.account)
                return fresh
            }
            throw ClaudeLimitsError.refreshFailedTerminal(message)
        }

        // 3) WRITE-BACK (con retry): patcha SOLO i 3 campi nel JSON grezzo (preserva tutto il resto)
        //    e riscrive l'item condiviso. Il pre-check è passato pochi ms fa, ma resta una finestra
        //    TOCTOU: tra pre-check e qui la CLI può aver riscritto l'item (nuovo persistentRef) → il
        //    primo update fallirebbe. Ritentiamo poche volte (no-prompt: ref già autorizzato) per
        //    coprire la finestra; ogni tentativo è veloce (un fallimento da ref stale è errSecItemNotFound).
        guard let patched = ClaudeOAuthCredentials.patchedRawJSON(original: original, refreshed: refreshed) else {
            CoreLog.keychain.error("[CRED] self-refresh: patch JSON fallito (item non riscritto)")
            return refreshed
        }
        var wroteBack = false
        for _ in 0 ..< 3 where !wroteBack {
            wroteBack = credentialWriter(patched, ref)
        }
        if wroteBack {
            CoreLog.keychain.info("[CRED] self-refresh write-back ok")
        } else if (refreshed.refreshToken ?? rt) != rt {
            // Write-back fallito DOPO una ROTAZIONE del refresh_token: il vecchio è ora morto e non
            // siamo riusciti a scrivere il nuovo nell'item condiviso → la CLI può richiedere ri-login.
            // (Se la CLI ha riscritto l'item lei stessa — causa più probabile — il suo token è già
            // fresco e questo log è innocuo.)
            CoreLog.keychain.error("[CRED] self-refresh: write-back fallito dopo rotazione → la CLI potrebbe richiedere ri-login")
        } else {
            // Nessuna rotazione: il refresh_token della CLI è ancora valido, nessun rischio per la CLI.
            CoreLog.keychain.info("[CRED] self-refresh: write-back fallito ma senza rotazione (CLI resta valida)")
        }

        // 4) Read-through cache aggiornata. Owner resta .claudeCLI: l'item condiviso ora è fresco.
        cachedCredentials = CredentialRecord(
            credentials: refreshed, owner: .claudeCLI, source: .claudeKeychain, accountLabel: account)
        return refreshed
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

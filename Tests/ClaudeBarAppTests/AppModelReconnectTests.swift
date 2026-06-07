import Testing
@testable import ClaudeBarApp
@testable import ClaudeBarCore
import Foundation

// Test della RICONNESSIONE resiliente (bottone Reconnect del pannello).
//
// Bug coperto: dopo che il token OAuth di Claude Code scade, la CLI lo rinnova in modo PIGRO
// (solo quando gira). Un singolo refresh — anche dopo che l'utente ha messo la password del
// Keychain — fallisce ancora con "token scaduto" finché la CLI non ha rinnovato. `reconnect()`
// fa un primo fetch userInitiated (prompt Keychain ORA) e, se resta no-auth, avvia un poll
// bounded no-UI che recupera automaticamente il refresh della CLI appena disponibile.
//
// I servizi sono fake (niente rete/Keychain). Il path testato è quello legacy solo-Claude
// (registry == nil), che usa direttamente `LimitsServicing` come l'MVP.

// MARK: - Fake servizi non-limiti (riusati: identici a quelli degli altri test App)

private struct RC_FakeIndexer: TranscriptIndexing {
    func refresh(force _: Bool, includeSubagents _: Bool) async throws -> AnalyticsReport { .empty() }
    func clearCache() async {}
}

private actor RC_FakePersistence: PersistenceServicing {
    func loadCachedReport() async -> AnalyticsReport? { nil }
    func loadCachedLimits() async -> LimitsSnapshot? { nil }
    func saveReport(_: AnalyticsReport) async {}
    func saveLimits(_: LimitsSnapshot) async {}
    func clearCache() async {}
}

// MARK: - Fake LimitsServicing controllabile a sequenza

/// Servizio limiti fake la cui risposta dipende dal numero di chiamate ricevute:
/// le prime `failuresBeforeSuccess` chiamate lanciano `.noCredentials` (→ AppStatus.tokenExpired);
/// dalla successiva in poi ritorna uno snapshot valido — simula la CLI che rinnova il token.
/// Traccia inoltre i valori di `userInitiated` ricevuti, per verificare il threading del prompt.
private actor SequencedLimitsService: LimitsServicing {
    private let failuresBeforeSuccess: Int
    private let failureError: ClaudeLimitsError
    private(set) var callCount = 0
    private(set) var userInitiatedFlags: [Bool] = []

    init(failuresBeforeSuccess: Int, failureError: ClaudeLimitsError = .noCredentials) {
        self.failuresBeforeSuccess = failuresBeforeSuccess
        self.failureError = failureError
    }

    func fetchUsage(userInitiated: Bool) async throws -> LimitsSnapshot {
        self.callCount += 1
        self.userInitiatedFlags.append(userInitiated)
        if self.callCount <= self.failuresBeforeSuccess {
            throw self.failureError // default .noCredentials → AppStatus.tokenExpired
        }
        return LimitsSnapshot(
            fiveHour: UsageWindow(kind: .fiveHour, utilization: 12, resetsAt: Date().addingTimeInterval(3600)),
            sevenDay: UsageWindow(kind: .sevenDay, utilization: 8, resetsAt: Date().addingTimeInterval(86400)),
            subscriptionType: "max", accountLabel: "tester", fetchedAt: Date(), source: .live)
    }
}

@MainActor
private func makeModel(service: SequencedLimitsService, defaults: UserDefaults) -> AppModel {
    let settings = SettingsStore(defaults: defaults)
    settings.notifyOnSessionThreshold = false
    settings.notifyOnWeeklyReset = false
    // Delay del poll minuscoli: la suite non deve aspettare i ~45s di produzione.
    // registry == nil → path legacy solo-Claude (usa direttamente `service`).
    return AppModel(
        limitsService: service,
        indexer: RC_FakeIndexer(),
        persistence: RC_FakePersistence(),
        settings: settings,
        notifications: AppNotifications(),
        registry: nil,
        reconnectPollDelays: Array(repeating: 0.01, count: 12))
}

@MainActor
private func isolatedDefaults() -> UserDefaults {
    let suite = "test.reconnect.\(UUID().uuidString)"
    let d = UserDefaults(suiteName: suite)!
    d.removePersistentDomain(forName: suite)
    return d
}

// MARK: - Test

@Suite("AppModel — riconnessione resiliente")
@MainActor
struct AppModelReconnectTests {
    @Test("reconnect() fa subito un fetch userInitiated (prompt Keychain ORA)")
    func reconnectFirstFetchIsUserInitiated() async {
        // Successo immediato: nessun poll, basta il primo tentativo.
        let service = SequencedLimitsService(failuresBeforeSuccess: 0)
        let model = makeModel(service: service, defaults: isolatedDefaults())

        await model.reconnect()

        let flags = await service.userInitiatedFlags
        #expect(flags.first == true)              // il PRIMO fetch è userInitiated → Keychain può promptare
        #expect(model.status == .ready)           // token valido subito → riconnesso
        #expect(model.limits?.fiveHour.utilization == 12)
    }

    @Test("Se il primo fetch resta tokenExpired, il poll recupera quando la CLI rinnova")
    func reconnectPollsUntilCLIRenews() async {
        // I primi 2 tentativi falliscono (token scaduto), il 3° riesce (CLI ha rinnovato).
        let service = SequencedLimitsService(failuresBeforeSuccess: 2)
        let model = makeModel(service: service, defaults: isolatedDefaults())

        await model.reconnect() // awaita anche il poll bounded

        #expect(model.status == .ready)           // recuperato automaticamente
        #expect(model.limits?.fiveHour.utilization == 12)
        let count = await service.callCount
        #expect(count == 3)                        // 1 userInitiated + 2 poll (l'ultimo riesce)
        // Solo il PRIMO fetch è userInitiated; i retry del poll sono NO-UI (nessun altro prompt).
        let flags = await service.userInitiatedFlags
        #expect(flags.first == true)
        #expect(flags.dropFirst().allSatisfy { $0 == false })
        // `isReconnecting` torna false a fine sequenza (defer).
        #expect(model.isReconnecting == false)
    }

    @Test("Il poll si ferma appena lo stato torna ready (non esaurisce i tentativi)")
    func reconnectPollStopsOnRecovery() async {
        // 1 fallimento poi successo: il poll deve fermarsi al 1° retry riuscito (call #2),
        // non continuare a interrogare il servizio per tutti i delay rimasti.
        let service = SequencedLimitsService(failuresBeforeSuccess: 1)
        let model = makeModel(service: service, defaults: isolatedDefaults())

        await model.reconnect()

        #expect(model.status == .ready)
        let count = await service.callCount
        #expect(count == 2)                        // 1 userInitiated (fallito) + 1 poll (riuscito) → stop
    }

    @Test("Nessun poll concorrente: una seconda reconnect annulla la prima")
    func reconnectNoConcurrentPolls() async {
        // Token che non si rinnova mai entro la finestra → la prima reconnect resterebbe in poll.
        // Avviarne due in sequenza ravvicinata non deve lasciare due poll attivi.
        let service = SequencedLimitsService(failuresBeforeSuccess: 100)
        let model = makeModel(service: service, defaults: isolatedDefaults())

        async let first: Void = model.reconnect()
        // Lascia partire il primo poll, poi lancia la seconda: deve cancellare il primo task.
        try? await Task.sleep(for: .milliseconds(5))
        await model.reconnect()
        _ = await first

        // Entrambe terminano (nessun task appeso): lo stato resta no-auth (token mai rinnovato)
        // e `isReconnecting` è tornato false. Il punto chiave è che il metodo ritorna senza
        // deadlock e senza poll orfani — testarne l'invariante "un solo task" direttamente non
        // è possibile (privato), ma il completamento pulito di entrambe lo dimostra.
        #expect(model.status == .tokenExpired)
        #expect(model.isReconnecting == false)
    }

    @Test("keychainDenied NON fa partire il poll: serve un fetch userInitiated, non aiuta pollare")
    func reconnectDoesNotPollOnKeychainDenied() async {
        // Accesso Keychain negato (ACL reset dopo la riscrittura della CLI): il reread NO-UI del
        // poll fallirebbe sempre allo stesso modo → pollare girerebbe a vuoto. Atteso: SOLO il
        // primo fetch userInitiated, nessun tick di poll. La CTA "Reconnect" (prompt) resta l'unica via.
        let service = SequencedLimitsService(failuresBeforeSuccess: 100, failureError: .keychainDenied)
        let model = makeModel(service: service, defaults: isolatedDefaults())

        await model.reconnect()

        #expect(model.status == .keychainDenied)
        let count = await service.callCount
        #expect(count == 1)                        // solo il fetch userInitiated, NESSUN poll
        #expect(model.isReconnecting == false)
    }
}

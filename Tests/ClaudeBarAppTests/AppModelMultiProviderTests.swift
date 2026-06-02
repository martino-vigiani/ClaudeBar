import Testing
@testable import ClaudeBarApp
@testable import ClaudeBarCore
import Foundation

// Test d'integrazione MP-7: l'AppModel interroga il PROVIDER ATTIVO via il ProviderRegistry,
// mappa lo snapshot unificato su limiti (glance/Pace) o su usage/costo, e re-fetcha al cambio
// provider. Vincolo: con provider attivo = Claude il comportamento resta quello dell'MVP.
//
// I provider sono fake (niente rete/Keychain): iniettiamo un registry costruito a mano.

// MARK: - Fake dei servizi di confine

private struct FakeLimitsService: LimitsServicing {
    func fetchUsage(userInitiated _: Bool) async throws -> LimitsSnapshot {
        LimitsSnapshot(
            fiveHour: UsageWindow(kind: .fiveHour, utilization: 10, resetsAt: Date()),
            sevenDay: UsageWindow(kind: .sevenDay, utilization: 10, resetsAt: Date()),
            subscriptionType: "max", accountLabel: "legacy", fetchedAt: Date(), source: .live)
    }
}

private struct FakeIndexer: TranscriptIndexing {
    func refresh(force _: Bool, includeSubagents _: Bool) async throws -> AnalyticsReport { .empty() }
    func clearCache() async {}
}

private actor FakePersistence: PersistenceServicing {
    func loadCachedReport() async -> AnalyticsReport? { nil }
    func loadCachedLimits() async -> LimitsSnapshot? { nil }
    func saveReport(_: AnalyticsReport) async {}
    func saveLimits(_: LimitsSnapshot) async {}
    func clearCache() async {}
}

// MARK: - Fake provider parametrizzabili

/// Provider fake che ritorna uno snapshot fisso (o lancia) — per testare il mapping nell'AppModel.
private struct FakeProvider: Provider {
    let descriptor: ProviderDescriptor
    let snapshotResult: @Sendable () async throws -> ProviderSnapshot
    let available: Bool

    init(
        id: ProviderID,
        capabilities: ProviderCapabilities,
        primary: Bool = false,
        available: Bool = true,
        snapshot: @escaping @Sendable () async throws -> ProviderSnapshot)
    {
        self.descriptor = ProviderDescriptor(
            id: id, capabilities: capabilities, authKinds: [.apiKey],
            branding: ProviderBranding(symbolName: "x"), isPrimaryCandidate: primary)
        self.snapshotResult = snapshot
        self.available = available
    }

    func strategies(for _: ProviderFetchContext) async -> [any ProviderFetchStrategy] { [] }
    func snapshot(context _: ProviderFetchContext) async throws -> ProviderSnapshot { try await snapshotResult() }
    func detectAvailability(_: ProviderFetchContext) async -> ProviderAvailability {
        available ? ProviderAvailability(isAvailable: true, detectedAuth: .apiKey) : .unavailable
    }
}

private func limitsSnapshot(_ id: ProviderID, fiveHour: Double, sevenDay: Double) -> ProviderSnapshot {
    ProviderSnapshot(
        providerID: id,
        windows: [
            UsageWindow(kind: .fiveHour, utilization: fiveHour, resetsAt: Date().addingTimeInterval(3600)),
            UsageWindow(kind: .sevenDay, utilization: sevenDay, resetsAt: Date().addingTimeInterval(86400)),
        ],
        identity: ProviderAccountIdentity(label: id.defaultDisplayName, plan: "plan"),
        fetchedAt: Date(), source: .live)
}

private func costSnapshot(_ id: ProviderID, costToday: Double, creditsRemaining: Double?, creditsTotal: Double?) -> ProviderSnapshot {
    ProviderSnapshot(
        providerID: id,
        cost: ProviderCostUsage(buckets: [
            ProviderCostBucket(rangeDays: 1, inputTokens: 100, outputTokens: 50, totalTokens: 150, costUSD: costToday),
        ], byModel: [ProviderModelCost(model: "m", totalTokens: 150, costUSD: costToday)]),
        credits: creditsRemaining.map { ProviderCredits(remaining: $0, total: creditsTotal) },
        identity: ProviderAccountIdentity(label: id.defaultDisplayName),
        fetchedAt: Date(), source: .live)
}

@MainActor
private func makeModel(registry: ProviderRegistry, defaults: UserDefaults) -> AppModel {
    let settings = SettingsStore(defaults: defaults)
    // Le notifiche toccano UNUserNotificationCenter (richiede bundle app): disabilitate nei test.
    settings.notifyOnSessionThreshold = false
    settings.notifyOnWeeklyReset = false
    return AppModel(
        limitsService: FakeLimitsService(),
        indexer: FakeIndexer(),
        persistence: FakePersistence(),
        settings: settings,
        notifications: AppNotifications(),
        registry: registry)
}

/// UserDefaults isolato per ogni test (no inquinamento dello standard).
@MainActor
private func isolatedDefaults() -> UserDefaults {
    let suite = "test.mp7.\(UUID().uuidString)"
    let d = UserDefaults(suiteName: suite)!
    d.removePersistentDomain(forName: suite)
    return d
}

// MARK: - Test

@Suite("AppModel — multi-provider (MP-7)")
@MainActor
struct AppModelMultiProviderTests {
    @Test("Provider attivo a LIMITI → limits popolato, usageCost nil (layout limiti)")
    func activeLimitsProvider() async {
        let registry = ProviderRegistry(providers: [
            FakeProvider(id: .claude, capabilities: .limitsOnly, primary: true) {
                limitsSnapshot(.claude, fiveHour: 42, sevenDay: 20)
            },
        ])
        let model = makeModel(registry: registry, defaults: isolatedDefaults())

        await model.refreshLimitsNow(userInitiated: false)

        #expect(model.limits != nil)
        #expect(model.limits?.fiveHour.utilization == 42)
        #expect(model.activeSnapshot?.providerID == .claude)
        let adapter = AppModelPanelAdapter(model)
        #expect(adapter.usageCost == nil)       // layout limiti
        #expect(!adapter.windows.isEmpty)
    }

    @Test("Provider attivo a CONSUMO → limits nil, usageCost valorizzato (layout costo)")
    func activeCostProvider() async {
        let defaults = isolatedDefaults()
        let registry = ProviderRegistry(providers: [
            FakeProvider(id: .openaiAPI, capabilities: .costOnly) {
                costSnapshot(.openaiAPI, costToday: 1.23, creditsRemaining: 10, creditsTotal: 50)
            },
        ])
        let model = makeModel(registry: registry, defaults: defaults)
        // Abilita + attiva OpenAI API.
        model.settings.setProviderEnabled(true, for: .openaiAPI)
        model.settings.setDefaultProvider(.openaiAPI)

        await model.refreshLimitsNow(userInitiated: false)

        #expect(model.limits == nil)                       // niente finestre-limite
        #expect(model.activeSnapshot?.cost != nil)
        let adapter = AppModelPanelAdapter(model)
        #expect(adapter.usageCost?.today?.costUSD == 1.23)  // layout costo
        #expect(adapter.credits?.remaining == 10)
        #expect(adapter.windows.isEmpty)
    }

    @Test("setActiveProvider cambia il default e ri-fetcha il nuovo provider")
    func switchProviderRefetches() async {
        let defaults = isolatedDefaults()
        let registry = ProviderRegistry(providers: [
            FakeProvider(id: .claude, capabilities: .limitsOnly, primary: true) {
                limitsSnapshot(.claude, fiveHour: 30, sevenDay: 15)
            },
            FakeProvider(id: .anthropicAPI, capabilities: .costOnly) {
                costSnapshot(.anthropicAPI, costToday: 5, creditsRemaining: nil, creditsTotal: nil)
            },
        ])
        let model = makeModel(registry: registry, defaults: defaults)
        model.settings.setProviderEnabled(true, for: .anthropicAPI)

        await model.refreshLimitsNow(userInitiated: false) // attivo = Claude (default)
        #expect(model.activeSnapshot?.providerID == .claude)
        #expect(model.limits != nil)

        model.setActiveProvider(.anthropicAPI)
        // setActiveProvider lancia un Task di refresh: attendi che lo snapshot cambi.
        for _ in 0..<50 where model.activeSnapshot?.providerID != .anthropicAPI {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.activeSnapshot?.providerID == .anthropicAPI)
        #expect(model.limits == nil)                  // provider a consumo → niente limiti
        #expect(model.settings.activeProviderID == .anthropicAPI)
    }

    @Test("Errore unauthorized di un'API a consumo → messaggio 'Admin key org' azionabile")
    func adminKeyErrorMessage() async {
        let defaults = isolatedDefaults()
        let registry = ProviderRegistry(providers: [
            FakeProvider(id: .anthropicAPI, capabilities: .costOnly) {
                throw ProviderError.unauthorized("Richiede una Admin key di account org.")
            },
        ])
        let model = makeModel(registry: registry, defaults: defaults)
        model.settings.setProviderEnabled(true, for: .anthropicAPI)
        model.settings.setDefaultProvider(.anthropicAPI)

        await model.refreshLimitsNow(userInitiated: false)

        // Lo status riflette l'errore azionabile (non un generico tokenExpired).
        if case let .error(message) = model.status {
            #expect(message.contains("Admin key"))
        } else {
            Issue.record("atteso .error con messaggio Admin key, trovato \(model.status)")
        }
        #expect(model.activeSnapshot == nil) // snapshot azzerato su errore
    }

    @Test("Con attivo = Claude il path non regredisce: limits derivato dalle finestre")
    func claudeParity() async {
        let registry = ProviderRegistry(providers: [
            FakeProvider(id: .claude, capabilities: .limitsOnly, primary: true) {
                limitsSnapshot(.claude, fiveHour: 88, sevenDay: 40)
            },
        ])
        let model = makeModel(registry: registry, defaults: isolatedDefaults())

        await model.refreshLimitsNow(userInitiated: false)

        // La finestra più critica (88%) guida lo stato glance, come l'MVP.
        #expect(model.limits?.mostCritical.utilization == 88)
        #expect(model.limits?.mostCritical.glance == .critical) // >85 usato
    }
}

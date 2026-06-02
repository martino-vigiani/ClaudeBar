import Foundation
import Testing
@testable import ClaudeBarApp
@testable import ClaudeBarCore

// Verifica il WIRING della preferenza "includi subagent" (Impostazioni → Analytics):
// AppModel.refreshAnalytics deve propagare settings.includeSubagentsInAnalytics
// all'indexer (TranscriptIndexing.refresh(force:includeSubagents:)).

/// Indexer fake che registra l'ultimo valore di `includeSubagents` ricevuto e quante volte
/// `refresh` è stato invocato (per verificare il force-refresh al cambio della preferenza).
private actor CapturingIndexer: TranscriptIndexing {
    private(set) var lastIncludeSubagents: Bool?
    private(set) var clearCalled = false
    private(set) var refreshCount = 0

    func refresh(force _: Bool, includeSubagents: Bool) async throws -> AnalyticsReport {
        self.lastIncludeSubagents = includeSubagents
        self.refreshCount += 1
        return .empty()
    }

    func clearCache() async { self.clearCalled = true }
}

private struct NoopLimits: LimitsServicing {
    func fetchUsage(userInitiated _: Bool) async throws -> LimitsSnapshot {
        LimitsSnapshot(
            fiveHour: UsageWindow(kind: .fiveHour, utilization: 0, resetsAt: Date()),
            sevenDay: UsageWindow(kind: .sevenDay, utilization: 0, resetsAt: Date()),
            subscriptionType: "max", accountLabel: "x", fetchedAt: Date(), source: .live)
    }
}

private actor NoopPersistence: PersistenceServicing {
    func loadCachedReport() async -> AnalyticsReport? { nil }
    func loadCachedLimits() async -> LimitsSnapshot? { nil }
    func saveReport(_: AnalyticsReport) async {}
    func saveLimits(_: LimitsSnapshot) async {}
    func clearCache() async {}
}

@MainActor
@Suite("Analytics wiring — includi subagent")
struct AnalyticsWiringTests {
    private func makeModel(indexer: CapturingIndexer, includeSubagents: Bool) -> AppModel {
        let suite = "test.analytics.\(UUID().uuidString)"
        let settings = SettingsStore(defaults: UserDefaults(suiteName: suite)!)
        settings.notifyOnSessionThreshold = false
        settings.notifyOnWeeklyReset = false
        settings.includeSubagentsInAnalytics = includeSubagents
        return AppModel(
            limitsService: NoopLimits(),
            indexer: indexer,
            persistence: NoopPersistence(),
            settings: settings,
            notifications: AppNotifications())
    }

    @Test("refreshAnalytics propaga la preferenza all'indexer (true)")
    func propagatesTrue() async {
        let indexer = CapturingIndexer()
        let model = self.makeModel(indexer: indexer, includeSubagents: true)
        await model.refreshAnalytics(force: false)
        #expect(await indexer.lastIncludeSubagents == true)
    }

    @Test("refreshAnalytics propaga la preferenza all'indexer (false)")
    func propagatesFalse() async {
        let indexer = CapturingIndexer()
        let model = self.makeModel(indexer: indexer, includeSubagents: false)
        await model.refreshAnalytics(force: false)
        #expect(await indexer.lastIncludeSubagents == false)
    }

    @Test("clearIndexCacheAndRebuild azzera la cache e ricostruisce")
    func clearRebuilds() async {
        let indexer = CapturingIndexer()
        let model = self.makeModel(indexer: indexer, includeSubagents: true)
        await model.clearIndexCacheAndRebuild()
        #expect(await indexer.clearCalled == true)
        #expect(await indexer.lastIncludeSubagents == true) // il rebuild successivo è avvenuto
    }

    @Test("Cambiare il flag include-subagent forza un refresh col nuovo valore")
    func flagChangeForcesRefresh() async {
        let indexer = CapturingIndexer()
        let model = self.makeModel(indexer: indexer, includeSubagents: true)
        // L'utente disattiva i subagent nelle Impostazioni, poi parte il callback onChange.
        model.settings.includeSubagentsInAnalytics = false
        model.applySettingsChange()
        // applySettingsChange lancia un Task per il refresh: attendiamo che l'indexer lo riceva.
        await Self.waitUntil { await indexer.lastIncludeSubagents == false }
        #expect(await indexer.lastIncludeSubagents == false)
    }

    @Test("applySettingsChange senza cambio del flag NON rigenera il report")
    func noFlagChangeNoRefresh() async {
        let indexer = CapturingIndexer()
        let model = self.makeModel(indexer: indexer, includeSubagents: true)
        // Una preferenza non-analytics cambia (es. solo glance): nessun refresh analytics atteso.
        model.applySettingsChange()
        // Diamo tempo a un eventuale Task spurio di girare, poi verifichiamo che non sia partito.
        await Self.spin()
        #expect(await indexer.refreshCount == 0)
    }

    /// Polling cooperativo: attende che `condition` sia vera (max ~1s) senza bloccare l'attore.
    private static func waitUntil(_ condition: @Sendable () async -> Bool) async {
        for _ in 0..<100 {
            if await condition() { return }
            try? await Task.sleep(nanoseconds: 10_000_000) // 10ms
        }
    }

    /// Cede il controllo abbastanza a lungo da far girare un eventuale Task in coda.
    private static func spin() async {
        for _ in 0..<10 { await Task.yield() }
        try? await Task.sleep(nanoseconds: 50_000_000) // 50ms
    }
}

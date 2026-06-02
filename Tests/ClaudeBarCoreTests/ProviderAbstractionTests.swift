import Foundation
import Testing
@testable import ClaudeBarCore

// Test dell'astrazione multi-provider: blinda le INTERFACCE CONGELATE (firme + comportamento
// di pipeline/bridge/registry/snapshot). Non sostituisce i test per-provider (li scrivono gli
// engineer), ma garantisce che lo scheletro e il refactor Claude reggano.

@Suite("Provider — bridge LimitsSnapshot → ProviderSnapshot")
struct ProviderBridgeTests {
    private func makeLimits(fiveHourUtil: Double, sevenDayUtil: Double) -> LimitsSnapshot {
        let resets = Date(timeIntervalSince1970: 2_000_000)
        return LimitsSnapshot(
            fiveHour: UsageWindow(kind: .fiveHour, utilization: fiveHourUtil, resetsAt: resets),
            sevenDay: UsageWindow(kind: .sevenDay, utilization: sevenDayUtil, resetsAt: resets),
            subscriptionType: "max",
            accountLabel: "tester",
            fetchedAt: Date(timeIntervalSince1970: 1_000_000),
            source: .live)
    }

    @Test("La proiezione preserva finestre, identità e source")
    func projectionPreservesData() {
        let limits = makeLimits(fiveHourUtil: 40, sevenDayUtil: 90)
        let snapshot = limits.asProviderSnapshot()

        #expect(snapshot.providerID == .claude)
        #expect(snapshot.windows.count == 2)
        #expect(snapshot.hasLimits)
        #expect(snapshot.cost == nil)
        #expect(snapshot.identity.label == "tester")
        #expect(snapshot.identity.plan == "max")
        #expect(snapshot.source == .live)
        #expect(snapshot.fetchedAt == limits.fetchedAt)
    }

    @Test("mostCriticalWindow e glance coincidono con la finestra più usata")
    func mostCriticalMatchesLimits() {
        let limits = makeLimits(fiveHourUtil: 40, sevenDayUtil: 90)
        let snapshot = limits.asProviderSnapshot()

        #expect(snapshot.mostCriticalWindow?.kind == .sevenDay)
        #expect(snapshot.mostCriticalWindow?.utilization == 90)
        // 90% usato → soglia critical (>85) della scala glance condivisa.
        #expect(snapshot.glance == limits.mostCritical.glance)
    }

    @Test("markedStale propaga lo stato stale")
    func markedStale() {
        let snapshot = makeLimits(fiveHourUtil: 10, sevenDayUtil: 10).asProviderSnapshot()
        #expect(!snapshot.isStale)
        #expect(snapshot.markedStale().isStale)
    }
}

@Suite("Provider — snapshot unificato a consumo (cost/credits)")
struct ProviderCostSnapshotTests {
    @Test("Senza finestre, hasLimits è falso e mostCritical è nil")
    func costOnlyHasNoLimits() {
        let snapshot = ProviderSnapshot(
            providerID: .openaiAPI,
            cost: ProviderCostUsage(buckets: [
                ProviderCostBucket(rangeDays: 1, inputTokens: 100, outputTokens: 50, totalTokens: 150, costUSD: 0.3),
            ]),
            fetchedAt: Date(),
            source: .live)

        #expect(!snapshot.hasLimits)
        #expect(snapshot.mostCriticalWindow == nil)
        #expect(snapshot.cost?.buckets.first?.costUSD == 0.3)
        // Niente limiti né credits → glance neutro (.ok), non un falso rosso.
        #expect(snapshot.glance == .ok)
    }

    @Test("glance deriva dalla frazione di credito consumata quando non ci sono finestre")
    func glanceFromCredits() {
        let snapshot = ProviderSnapshot(
            providerID: .anthropicAPI,
            credits: ProviderCredits(remaining: 5, total: 100), // 95% consumato → empty
            fetchedAt: Date(),
            source: .live)

        #expect(snapshot.credits?.usedFraction == 0.95)
        #expect(snapshot.glance == .empty)
    }

    @Test("usedFraction è nil senza total")
    func usedFractionNilWithoutTotal() {
        let credits = ProviderCredits(remaining: 5)
        #expect(credits.usedFraction == nil)
    }

    @Test("ProviderSnapshot è Codable round-trip")
    func snapshotCodableRoundTrip() throws {
        let original = ProviderSnapshot(
            providerID: .claude,
            windows: [UsageWindow(kind: .fiveHour, utilization: 33, resetsAt: Date(timeIntervalSince1970: 9_000))],
            cost: ProviderCostUsage(
                buckets: [ProviderCostBucket(rangeDays: 7, inputTokens: 1, outputTokens: 2, totalTokens: 3, costUSD: 0.1)],
                byModel: [ProviderModelCost(model: "gpt-x", totalTokens: 3, costUSD: 0.1)]),
            credits: ProviderCredits(remaining: 10, total: 20),
            identity: ProviderAccountIdentity(label: "x", plan: "pro"),
            fetchedAt: Date(timeIntervalSince1970: 5_000),
            source: .cached)

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ProviderSnapshot.self, from: data)
        #expect(decoded == original)
    }
}

@Suite("Provider — pipeline di strategie (fallback)")
struct ProviderPipelineTests {
    /// Strategia fake parametrizzabile per testare l'ordine e il fallback.
    private struct FakeStrategy: ProviderFetchStrategy {
        let id: String
        let kind: ProviderFetchKind = .apiKey
        var available: Bool
        var result: Result<ProviderSnapshot, ProviderError>
        var fallback: Bool

        func isAvailable(_: ProviderFetchContext) async -> Bool { available }
        func fetch(_: ProviderFetchContext) async throws -> ProviderSnapshot { try result.get() }
        func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool { fallback }
    }

    private struct FakeProvider: Provider {
        let descriptor: ProviderDescriptor
        let list: [any ProviderFetchStrategy]
        func strategies(for _: ProviderFetchContext) async -> [any ProviderFetchStrategy] { list }
        func detectAvailability(_: ProviderFetchContext) async -> ProviderAvailability { .unavailable }
    }

    private func makeProvider(_ strategies: [any ProviderFetchStrategy]) -> FakeProvider {
        FakeProvider(
            descriptor: ProviderDescriptor(
                id: .openaiAPI, capabilities: .costOnly,
                authKinds: [.apiKey], branding: ProviderBranding(symbolName: "x")),
            list: strategies)
    }

    private func snap(_ id: ProviderID) -> ProviderSnapshot {
        ProviderSnapshot(providerID: id, fetchedAt: Date(timeIntervalSince1970: 1), source: .live)
    }

    @Test("La prima strategia disponibile che riesce vince")
    func firstAvailableWins() async throws {
        let provider = makeProvider([
            FakeStrategy(id: "a", available: false, result: .success(snap(.claude)), fallback: false),
            FakeStrategy(id: "b", available: true, result: .success(snap(.openaiAPI)), fallback: false),
        ])
        let result = try await provider.snapshot(context: ProviderFetchContext(userInitiated: false))
        #expect(result.providerID == .openaiAPI)
    }

    @Test("Su errore con shouldFallback=true passa alla successiva")
    func fallbackOnError() async throws {
        let provider = makeProvider([
            FakeStrategy(id: "a", available: true, result: .failure(.network("x")), fallback: true),
            FakeStrategy(id: "b", available: true, result: .success(snap(.gemini)), fallback: false),
        ])
        let result = try await provider.snapshot(context: ProviderFetchContext(userInitiated: false))
        #expect(result.providerID == .gemini)
    }

    @Test("Errore terminale senza fallback viene rilanciato")
    func terminalErrorRethrown() async {
        let provider = makeProvider([
            FakeStrategy(id: "a", available: true, result: .failure(.noCredentials), fallback: false),
        ])
        await #expect(throws: ProviderError.self) {
            _ = try await provider.snapshot(context: ProviderFetchContext(userInitiated: false))
        }
    }

    @Test("Nessuna strategia disponibile → noAvailableStrategy")
    func noAvailableStrategy() async {
        let provider = makeProvider([
            FakeStrategy(id: "a", available: false, result: .success(snap(.claude)), fallback: false),
        ])
        await #expect(throws: ProviderError.noAvailableStrategy(.openaiAPI)) {
            _ = try await provider.snapshot(context: ProviderFetchContext(userInitiated: false))
        }
    }
}

@Suite("Provider — bridge errori Claude")
struct ProviderErrorBridgeTests {
    @Test("ClaudeLimitsError si mappa 1:1 senza perdere terminalità")
    func claudeErrorBridge() {
        #expect(ClaudeLimitsError.noCredentials.asProviderError == .noCredentials)
        #expect(ClaudeLimitsError.refreshDelegatedToCLI.asProviderError == .refreshDelegatedToOwner)
        #expect(ClaudeLimitsError.keychainDenied.asProviderError == .keychainDenied)
        #expect(ClaudeLimitsError.invalidResponse.asProviderError == .invalidResponse)
        // Terminalità preservata sul lato provider.
        #expect(ClaudeLimitsError.noCredentials.asProviderError.isTerminal)
        #expect(!ClaudeLimitsError.network("x").asProviderError.isTerminal)
    }
}

@Suite("Provider — registry + auto-detect")
struct ProviderRegistryTests {
    /// Provider fake con disponibilità controllabile.
    private struct StubProvider: Provider {
        let descriptor: ProviderDescriptor
        let available: Bool
        func strategies(for _: ProviderFetchContext) async -> [any ProviderFetchStrategy] { [] }
        func detectAvailability(_: ProviderFetchContext) async -> ProviderAvailability {
            available ? ProviderAvailability(isAvailable: true, detectedAuth: descriptor.authKinds.first) : .unavailable
        }
    }

    private func stub(_ id: ProviderID, primary: Bool, available: Bool) -> StubProvider {
        StubProvider(
            descriptor: ProviderDescriptor(
                id: id, capabilities: .limitsOnly, authKinds: [.apiKey],
                branding: ProviderBranding(symbolName: "x"), isPrimaryCandidate: primary),
            available: available)
    }

    private let ctx = ProviderFetchContext(userInitiated: false)

    @Test("Il primario disponibile con priorità più alta diventa default")
    func primaryWins() async {
        let registry = ProviderRegistry(providers: [
            stub(.claude, primary: true, available: true),
            stub(.codex, primary: true, available: true),
        ])
        #expect(await registry.autoDetectDefault(ctx) == .claude)
    }

    @Test("Se nessun primario è disponibile, vince il primo disponibile")
    func firstAvailableWhenNoPrimary() async {
        let registry = ProviderRegistry(providers: [
            stub(.claude, primary: true, available: false),
            stub(.gemini, primary: false, available: true),
        ])
        #expect(await registry.autoDetectDefault(ctx) == .gemini)
    }

    @Test("Senza nessun provider disponibile, fallback a Claude")
    func fallbackToClaude() async {
        let registry = ProviderRegistry(providers: [
            stub(.claude, primary: true, available: false),
            stub(.codex, primary: false, available: false),
        ])
        #expect(await registry.autoDetectDefault(ctx) == .claude)
    }

    @Test("detectAvailability popola la mappa per ogni provider")
    func availabilityMap() async {
        let registry = ProviderRegistry(providers: [
            stub(.claude, primary: true, available: true),
            stub(.codex, primary: false, available: false),
        ])
        let map = await registry.detectAvailability(ctx)
        #expect(map[.claude]?.isAvailable == true)
        #expect(map[.codex]?.isAvailable == false)
    }
}

@Suite("Provider — secret store (in memory)")
struct ProviderSecretStoreTests {
    @Test("set/get/list/remove round-trip")
    func roundTrip() throws {
        let store = InMemorySecretStore()
        #expect(!store.hasSecret(provider: .openaiAPI))

        try store.setSecret("sk-123", provider: .openaiAPI, account: "default")
        #expect(try store.secret(provider: .openaiAPI, account: "default") == "sk-123")
        #expect(store.hasSecret(provider: .openaiAPI))
        #expect(try store.accounts(provider: .openaiAPI) == ["default"])

        try store.removeSecret(provider: .openaiAPI, account: "default")
        #expect(try store.secret(provider: .openaiAPI, account: "default") == nil)
        #expect(!store.hasSecret(provider: .openaiAPI))
    }
}

@Suite("Provider — settings model")
struct ProviderSettingsTests {
    @Test("initial abilita solo Claude, singleActive, auto-detect")
    func initialDefaults() {
        let settings = MultiProviderSettings.initial
        #expect(settings.enabledProviders == [.claude])
        #expect(settings.defaultProvider == .claude)
        #expect(settings.autoDetectDefault)
        #expect(settings.barDisplayMode == .singleActive)
    }

    @Test("updating inserisce o aggiorna una config")
    func updatingConfig() {
        var settings = MultiProviderSettings.initial
        settings = settings.updating(ProviderConfig(id: .gemini, enabled: true))
        #expect(settings.enabledProviders.contains(.gemini))
        settings = settings.updating(ProviderConfig(id: .gemini, enabled: false))
        #expect(!settings.enabledProviders.contains(.gemini))
    }

    @Test("MultiProviderSettings è Codable round-trip")
    func settingsCodable() throws {
        let original = MultiProviderSettings.initial
            .updating(ProviderConfig(id: .openaiAPI, enabled: true, preferredAuth: .apiKey, selectedAccount: "work"))
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(MultiProviderSettings.self, from: data)
        #expect(decoded == original)
    }
}

// MARK: - Estensioni additive post-congelamento (finestre non-Claude, spend limit, auto-detect-gaps)

@Suite("Provider — finestre non-Claude (durata custom + label)")
struct ProviderCustomWindowTests {
    @Test("UsageWindow Claude: effectiveDuration = kind.duration (invariato)")
    func claudeWindowUnchanged() {
        let window = UsageWindow(kind: .fiveHour, utilization: 50, resetsAt: Date())
        #expect(window.effectiveDuration == PaceWindowKind.fiveHour.duration)
        #expect(window.customDurationMinutes == nil)
        #expect(window.label == nil)
    }

    @Test("Finestra giornaliera (Gemini): durata custom 1440 min ha precedenza")
    func dailyWindowDuration() {
        let window = UsageWindow(
            kind: .fiveHour, utilization: 25, resetsAt: Date(),
            customDurationMinutes: 1440, label: "Pro")
        #expect(window.effectiveDuration == 24 * 60 * 60)
        #expect(window.label == "Pro")
    }

    @Test("Pace usa la durata effettiva: a metà giornata con 25% usato sei SOTTO ritmo")
    func paceWithCustomDuration() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        // Finestra 24h che resetta tra 12h → elapsedFrac = 0.5. Usato 25% → under pace.
        let resetsAt = now.addingTimeInterval(12 * 60 * 60)
        let window = UsageWindow(
            kind: .fiveHour, utilization: 25, resetsAt: resetsAt,
            customDurationMinutes: 1440, label: "Flash")
        let withPace = PaceCalculator.withPace(window, now: now)
        #expect(withPace.pace?.paceMarker == 0.5)
        #expect(withPace.pace?.rhythm == .under)
        #expect(withPace.pace?.isOverPace == false)
    }

    @Test("Senza durata custom, withPace resta identico al comportamento Claude")
    func withPaceClaudeParity() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let resetsAt = now.addingTimeInterval(PaceWindowKind.fiveHour.duration / 2) // metà finestra
        let window = UsageWindow(kind: .fiveHour, utilization: 50, resetsAt: resetsAt)
        let withPace = PaceCalculator.withPace(window, now: now)
        #expect(withPace.pace?.paceMarker == 0.5)
        #expect(withPace.pace?.rhythm == .onTrack)
    }
}

@Suite("Provider — spend limit on-demand (Cursor / API a consumo)")
struct ProviderSpendLimitTests {
    @Test("usedFraction calcola la % consumata quando c'è un limite")
    func usedFraction() {
        let spend = ProviderSpendLimit(used: 7.5, limit: 10, currency: "USD", period: "Monthly")
        #expect(spend.usedFraction == 0.75)
    }

    @Test("usedFraction è nil senza limite (on-demand illimitato)")
    func unlimited() {
        let spend = ProviderSpendLimit(used: 42, limit: nil)
        #expect(spend.usedFraction == nil)
    }

    @Test("ProviderCostUsage con spendLimit è Codable round-trip")
    func costUsageWithSpendCodable() throws {
        let cost = ProviderCostUsage(
            buckets: [ProviderCostBucket(rangeDays: 30, inputTokens: 10, outputTokens: 5, totalTokens: 15, costUSD: 1.2)],
            spendLimit: ProviderSpendLimit(
                used: 3, limit: 20, currency: "USD", period: "Billing cycle",
                resetsAt: Date(timeIntervalSince1970: 7_000)))
        let data = try JSONEncoder().encode(cost)
        let decoded = try JSONDecoder().decode(ProviderCostUsage.self, from: data)
        #expect(decoded == cost)
        #expect(decoded.spendLimit?.usedFraction == 0.15)
    }
}

@Suite("Provider — auto-detect riempie solo i vuoti")
struct ProviderAutoDetectGapsTests {
    private struct StubProvider: Provider {
        let descriptor: ProviderDescriptor
        let available: Bool
        let auth: ProviderAuthKind
        func strategies(for _: ProviderFetchContext) async -> [any ProviderFetchStrategy] { [] }
        func detectAvailability(_: ProviderFetchContext) async -> ProviderAvailability {
            available ? ProviderAvailability(isAvailable: true, detectedAuth: auth) : .unavailable
        }
    }

    private func stub(_ id: ProviderID, available: Bool, auth: ProviderAuthKind = .apiKey) -> StubProvider {
        StubProvider(
            descriptor: ProviderDescriptor(
                id: id, capabilities: .limitsOnly, authKinds: [auth],
                branding: ProviderBranding(symbolName: "x"), isPrimaryCandidate: id == .claude),
            available: available, auth: auth)
    }

    private let ctx = ProviderFetchContext(userInitiated: false)

    @Test("Un provider disponibile mai configurato viene abilitato con l'auth rilevato")
    func fillsGap() async {
        let registry = ProviderRegistry(providers: [stub(.gemini, available: true, auth: .oauthManaged)])
        // Settings iniziali: solo Claude configurato; Gemini è un "vuoto".
        let result = await registry.applyingAutoDetect(to: .initial, context: ctx)
        let gemini = result.providers.first(where: { $0.id == .gemini })
        #expect(gemini?.enabled == true)
        #expect(gemini?.preferredAuth == .oauthManaged)
    }

    @Test("Una scelta manuale dell'utente NON viene sovrascritta")
    func doesNotOverrideManual() async {
        let registry = ProviderRegistry(providers: [stub(.gemini, available: true, auth: .oauthManaged)])
        // L'utente ha esplicitamente DISABILITATO Gemini.
        let manual = MultiProviderSettings.initial.updating(ProviderConfig(id: .gemini, enabled: false))
        let result = await registry.applyingAutoDetect(to: manual, context: ctx)
        let gemini = result.providers.first(where: { $0.id == .gemini })
        #expect(gemini?.enabled == false) // rispettata la scelta manuale
    }

    @Test("Un provider non disponibile non viene aggiunto")
    func skipsUnavailable() async {
        let registry = ProviderRegistry(providers: [stub(.cursor, available: false)])
        let result = await registry.applyingAutoDetect(to: .initial, context: ctx)
        #expect(!result.providers.contains(where: { $0.id == .cursor }))
    }
}

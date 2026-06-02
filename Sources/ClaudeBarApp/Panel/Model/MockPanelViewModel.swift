import SwiftUI
import Observation

// MARK: - Mock per preview e sviluppo isolato
//
// Implementazione @Observable del protocollo PanelViewModeling con dati finti
// ma realistici. Usata dalle #Preview e finché l'AppModel reale non è collegato.

@MainActor
@Observable
final class MockPanelViewModel: PanelViewModeling {
    var state: PanelState
    var account: AccountVM?
    var lastUpdated: Date?
    var isRefreshing: Bool = false
    var windows: [UsageWindowVM]
    var analytics: AnalyticsVM

    // Multi-provider (MP-6): opzionali, nil di default → comportamento mono-Claude invariato.
    var availableProviders: [ProviderChipVM]
    var activeProvider: ProviderChipVM?
    var usageCost: UsageCostVM?
    var credits: CreditsVM?

    var criticalWindow: UsageWindowVM? {
        // La più critica = max utilization (coerente con "finestra messa peggio").
        windows.max(by: { $0.utilization < $1.utilization })
    }

    init(state: PanelState = .ok,
         account: AccountVM? = AccountVM(name: "martino", plan: "Max"),
         windows: [UsageWindowVM]? = nil,
         analytics: AnalyticsVM? = nil,
         availableProviders: [ProviderChipVM] = [],
         activeProvider: ProviderChipVM? = nil,
         usageCost: UsageCostVM? = nil,
         credits: CreditsVM? = nil) {
        self.state = state
        self.account = account
        self.lastUpdated = Date().addingTimeInterval(-8)
        self.windows = windows ?? Self.sampleWindows()
        self.analytics = analytics ?? Self.sampleAnalytics(range: .today)
        self.availableProviders = availableProviders
        self.activeProvider = activeProvider
        self.usageCost = usageCost
        self.credits = credits
    }

    func refresh() {
        isRefreshing = true
        Task {
            try? await Task.sleep(for: .seconds(1.1))
            self.lastUpdated = Date()
            self.isRefreshing = false
        }
    }
    func retry() { state = .ok; refresh() }
    func openSettings() {}
    func reconnect() {}
    func setRange(_ range: AnalyticsRange) {
        analytics = Self.sampleAnalytics(range: range)
    }
    func setActiveProvider(_ id: String) {
        activeProvider = availableProviders.first(where: { $0.id == id }) ?? activeProvider
    }

    // MARK: Sample data

    static func sampleWindows() -> [UsageWindowVM] {
        let now = Date()
        let sessionReset = now.addingTimeInterval(2 * 3600 + 14 * 60)
        let weeklyReset = now.addingTimeInterval(3.4 * 86400)
        return [
            UsageWindowVM(
                kind: .session, utilization: 62, resetsAt: sessionReset,
                pace: PaceInfo(paceMarker: 0.56, status: .over,
                               etaToEmpty: 1.65 * 3600,
                               emptyAt: now.addingTimeInterval(1.65 * 3600))
            ),
            UsageWindowVM(
                kind: .weekly, utilization: 41, resetsAt: weeklyReset,
                pace: PaceInfo(paceMarker: 0.49, status: .under,
                               etaToEmpty: nil, emptyAt: nil)
            ),
            UsageWindowVM(
                kind: .weeklyOpus, utilization: 73, resetsAt: weeklyReset, pace: nil
            ),
            UsageWindowVM(
                kind: .weeklySonnet, utilization: 28, resetsAt: weeklyReset, pace: nil
            ),
        ]
    }

    /// Provider chip di esempio per lo switcher (Claude + due API a consumo).
    static func sampleProviders() -> [ProviderChipVM] {
        [
            ProviderChipVM(id: "claude", name: "Claude", symbol: "sparkles", stateColorUsed: 62),
            ProviderChipVM(id: "openai_api", name: "OpenAI", symbol: "key.horizontal", stateColorUsed: nil),
            ProviderChipVM(id: "gemini", name: "Gemini", symbol: "diamond", stateColorUsed: 18),
        ]
    }

    /// Blocco usage+costo di esempio per i provider a consumo.
    static func sampleUsageCost() -> UsageCostVM {
        let now = Date()
        var series: [SpendPoint] = []
        for i in 0..<7 {
            let offset: TimeInterval = Double(-(6 - i)) * 86400
            let wave: Double = sin(Double(i) * 0.8) + 1.5
            let cost: Double = wave * 0.9
            let tokens = Int(wave * 320_000)
            series.append(SpendPoint(date: now.addingTimeInterval(offset), cost: cost, tokens: tokens))
        }
        return UsageCostVM(
            buckets: [
                CostBucketVM(rangeDays: 1, costUSD: 1.20, totalTokens: 120_000),
                CostBucketVM(rangeDays: 7, costUSD: 9.80, totalTokens: 980_000),
                CostBucketVM(rangeDays: 30, costUSD: 34.10, totalTokens: 3_400_000),
            ],
            byModel: [
                BreakdownItem(label: "gpt-4o", cost: 22.0, tokens: 2_000_000, symbol: "cube"),
                BreakdownItem(label: "gpt-4o-mini", cost: 12.1, tokens: 1_400_000, symbol: "cube"),
            ],
            series: series,
            costEstimated: true,
            currencyCode: "USD")
    }

    static func sampleAnalytics(range: AnalyticsRange) -> AnalyticsVM {
        let cal = Calendar.current
        let now = Date()
        let (count, step, scale): (Int, Calendar.Component, Double) = switch range {
        case .today: (12, .hour, 1)
        case .week: (7, .day, 6)
        case .month: (30, .day, 5)
        }
        var series: [SpendPoint] = []
        for i in 0..<count {
            let d = cal.date(byAdding: step, value: -(count - 1 - i), to: now) ?? now
            let wave = (sin(Double(i) * 0.9) + 1.4) * 0.9
            let cost = (0.15 + wave * 0.45) * scale
            series.append(SpendPoint(date: d, cost: cost, tokens: Int(cost * 360_000)))
        }
        let total = series.reduce(0) { $0 + $1.cost }
        let tok = series.reduce(0) { $0 + $1.tokens }
        return AnalyticsVM(
            range: range,
            cost: total,
            costDeltaPct: range == .today ? 12 : -6,
            tokens: tok,
            inputTokens: Int(Double(tok) * 0.07),
            cacheReadTokens: Int(Double(tok) * 0.70),
            cacheWriteTokens: Int(Double(tok) * 0.19),
            outputTokens: Int(Double(tok) * 0.04),
            cacheEfficiency: 0.78,
            series: series,
            byModel: [
                BreakdownItem(label: "claude-opus-4-7", cost: total * 0.58, tokens: 740_000, symbol: "cube"),
                BreakdownItem(label: "claude-sonnet-4-6", cost: total * 0.34, tokens: 1_220_000, symbol: "cube"),
                BreakdownItem(label: "claude-haiku-4-5", cost: total * 0.08, tokens: 380_000, symbol: "cube"),
            ],
            byProject: [
                BreakdownItem(label: "ClaudeBar", cost: total * 0.46, tokens: 980_000, symbol: "folder"),
                BreakdownItem(label: "SubraCAD", cost: total * 0.31, tokens: 610_000, symbol: "folder"),
                BreakdownItem(label: "FantaKorfù", cost: total * 0.23, tokens: 430_000, symbol: "folder"),
            ]
        )
    }
}

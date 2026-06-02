import ClaudeBarCore
import Foundation
import Observation
import SwiftUI

/// Adapter che fa da ponte tra l'`AppModel` (unica fonte di verità, tipi Core) e il protocollo
/// presentazionale `PanelViewModeling` della UI (tipi VM di ui-engineer).
///
/// L'AppModel NON conosce i tipi UI; questo adapter osserva l'AppModel e traduce
/// `LimitsSnapshot`/`AnalyticsReport`/`PaceProjection` → `UsageWindowVM`/`AnalyticsVM`/`PaceInfo`.
/// Essendo `@Observable`, ogni lettura di una proprietà dell'AppModel propaga le invalidazioni
/// alla view: SwiftUI ridisegna quando l'AppModel cambia.
///
/// NOTA (ui-engineer): questo file era stato cancellato per errore durante un refactor in
/// parallelo e ricostruito identico (più `panelDidOpen()` per il nuovo requisito di protocollo).
@MainActor
@Observable
final class AppModelPanelAdapter: PanelViewModeling {
    private let model: AppModel

    init(_ model: AppModel) {
        self.model = model
    }

    // MARK: - Stato

    var state: PanelState {
        switch self.model.status {
        case .loading: .loading
        case .ready: .ok
        case let .stale(since): .stale(since: since)
        case .noSubscription: .noSubscription
        case .tokenExpired, .keychainDenied: .noAuth
        case .offline: .stale(since: self.model.lastLimitsRefresh ?? Date())
        case let .error(message): .error(message: message)
        }
    }

    var account: AccountVM? {
        guard let limits = self.model.limits else { return nil }
        let plan = limits.subscriptionType.isEmpty
            ? "—"
            : limits.subscriptionType.capitalized
        return AccountVM(name: limits.accountLabel, plan: plan)
    }

    var lastUpdated: Date? { self.model.lastLimitsRefresh }

    /// Lo spinner del bottone refresh riflette QUALSIASI refresh in corso: il bottone
    /// innesca sia il fetch dei limiti sia l'ingest analytics, quindi gira finché uno dei
    /// due è attivo (isRefreshingLimits oppure full-index analytics).
    var isRefreshing: Bool { self.model.isRefreshingLimits || self.model.indexingProgress != nil }

    // MARK: - Finestre

    var criticalWindow: UsageWindowVM? {
        guard let limits = self.model.limits else { return nil }
        return Self.windowVM(from: limits.mostCritical)
    }

    var windows: [UsageWindowVM] {
        guard let limits = self.model.limits else { return [] }
        return limits.allWindows.map(Self.windowVM(from:))
    }

    // MARK: - Analytics

    var analytics: AnalyticsVM {
        Self.analyticsVM(
            from: self.model.analytics,
            range: self.model.analyticsRange,
            showCostDisclaimer: self.settings.showCostDisclaimer)
    }

    // MARK: - Multi-provider (MP-6)
    //
    // Lo switcher e l'identità provider derivano dalle Impostazioni (`MultiProviderSettings`). I
    // dati usage+costo/credito dei provider non-Claude arriveranno via l'integrazione `AppModel`
    // (snapshot del provider attivo, core-engineer): finché non c'è, restano nil → per Claude il
    // pannello usa il layout limiti, esattamente come oggi. Nessuna regressione.

    private var settings: SettingsStore { self.model.settings }

    var availableProviders: [ProviderChipVM] {
        self.settings.multiProvider.enabledProviders.map { id in
            let descriptor = ProviderCatalog.descriptor(for: id)
            // Colore di stato solo per il provider attivo a limiti (Claude): dalla finestra critica.
            let used: Double? = (id == .claude)
                ? self.model.limits?.mostCritical.utilization
                : nil
            return ProviderChipVM(
                id: id.rawValue,
                name: descriptor.displayName,
                symbol: descriptor.branding.symbolName,
                stateColorUsed: used)
        }
    }

    var activeProvider: ProviderChipVM? {
        let active = self.settings.activeProviderID
        return self.availableProviders.first(where: { $0.id == active.rawValue })
            ?? self.availableProviders.first
    }

    /// Blocchi usage+costo/credito del provider ATTIVO (MP-7). Valorizzati quando lo snapshot
    /// attivo è di un provider a consumo (OpenAI/Anthropic API). Per Claude (e i provider a
    /// limiti) restano nil → il pannello usa il layout limiti, identico a oggi.
    var usageCost: UsageCostVM? {
        guard let cost = self.model.activeSnapshot?.cost else { return nil }
        return Self.usageCostVM(from: cost, showCostDisclaimer: self.settings.showCostDisclaimer)
    }

    var credits: CreditsVM? {
        guard let credits = self.model.activeSnapshot?.credits else { return nil }
        return CreditsVM(remaining: credits.remaining, total: credits.total, currency: credits.currency)
    }

    func setActiveProvider(_ id: String) {
        guard let providerID = ProviderID(rawValue: id) else { return }
        // Passa dall'AppModel: cambia il default E ri-fetcha subito i dati del nuovo provider.
        self.model.setActiveProvider(providerID)
    }

    // MARK: - Azioni

    func panelDidOpen() {
        self.model.panelDidOpen()
    }

    func refresh() {
        Task { await self.model.refreshLimitsNow(userInitiated: true) }
        Task { await self.model.refreshAnalytics(force: false) }
    }

    func retry() {
        self.refresh()
    }

    func openSettings() {
        self.model.openPreferences()
    }

    func reconnect() {
        Task { await self.model.refreshLimitsNow(userInitiated: true) }
    }

    func setRange(_ range: AnalyticsRange) {
        self.model.analyticsRange = range
    }

    // MARK: - Traduzioni Core → VM

    private static func windowVM(from window: UsageWindow) -> UsageWindowVM {
        UsageWindowVM(
            kind: self.windowKind(from: window.kind),
            utilization: window.utilization,
            resetsAt: window.resetsAt ?? Date(),
            pace: window.pace.map(self.paceInfo(from:)),
            // Etichetta custom dal provider (Gemini "Pro/Flash", Cursor "Total/Auto/API"), se presente.
            label: window.label)
    }

    private static func windowKind(from kind: PaceWindowKind) -> WindowKind {
        switch kind {
        case .fiveHour: .session
        case .sevenDay: .weekly
        case .sevenDayOpus: .weeklyOpus
        case .sevenDaySonnet: .weeklySonnet
        }
    }

    private static func paceInfo(from pace: PaceProjection) -> PaceInfo {
        let status: PaceStatus = switch pace.rhythm {
        case .onTrack: .onTrack
        case .over: .over
        case .under: .under
        }
        let eta: TimeInterval? = pace.etaToEmpty.map { max(0, $0.timeIntervalSinceNow) }
        return PaceInfo(
            paceMarker: pace.paceMarker,
            status: status,
            etaToEmpty: eta,
            emptyAt: pace.etaToEmpty)
    }

    private static func analyticsVM(
        from report: AnalyticsReport?,
        range: AnalyticsRange,
        showCostDisclaimer: Bool) -> AnalyticsVM
    {
        guard let report else {
            return AnalyticsVM(
                range: range,
                cost: 0,
                costDeltaPct: nil,
                tokens: 0,
                inputTokens: 0,
                cacheReadTokens: 0,
                cacheWriteTokens: 0,
                outputTokens: 0,
                cacheEfficiency: 0,
                series: [],
                byModel: [],
                byProject: [],
                showCostDisclaimer: showCostDisclaimer)
        }

        let series = self.series(from: report, range: range)
        let cost = series.reduce(0) { $0 + $1.cost }
        let tokens = series.reduce(0) { $0 + $1.tokens }

        // Breakdown token sullo STESSO range della serie (ultimi N bucket giornalieri).
        // `byDay` espone input/output/cacheRead; i token scritti in cache si ricavano per
        // differenza dal totale → i 4 valori sommano esattamente a `tokens`.
        let limitDays: Int = switch range {
        case .today: 1
        case .week: 7
        case .month: 30
        }
        let windowDays = report.byDay.suffix(limitDays)
        let inputTok = windowDays.reduce(0) { $0 + $1.input }
        let cacheReadTok = windowDays.reduce(0) { $0 + $1.cacheRead }
        let outputTok = windowDays.reduce(0) { $0 + $1.output }
        let cacheWriteTok = max(0, tokens - inputTok - cacheReadTok - outputTok)

        // Breakdown SCOPATI per range (Oggi/7g/30g), coerenti con costo/token/grafico.
        // Fallback all'intero dataset se il report viene da cache vecchia senza i per-range.
        let modelBuckets = report.byModelByDays[limitDays] ?? report.byModel
        let projectBuckets = report.byProjectByDays[limitDays] ?? report.byProject
        let byModel = modelBuckets.prefix(6).map { bucket in
            BreakdownItem(
                label: bucket.model,
                cost: bucket.costUSD ?? 0,
                tokens: bucket.totalTokens,
                symbol: "cube")
        }
        let byProject = projectBuckets.prefix(6).map { bucket in
            BreakdownItem(
                label: bucket.displayName,
                cost: bucket.costUSD ?? 0,
                tokens: bucket.totalTokens,
                symbol: "folder")
        }

        return AnalyticsVM(
            range: range,
            cost: cost,
            // Core dà la VARIAZIONE FRAZIONARIA (0.086 = +8.6%); il DeltaBadge vuole il valore
            // in percentuale, quindi ×100. nil → nessun badge (storico insufficiente / prev = 0).
            costDeltaPct: report.costDeltaPercent.map { $0 * 100 },
            tokens: tokens,
            inputTokens: inputTok,
            cacheReadTokens: cacheReadTok,
            cacheWriteTokens: cacheWriteTok,
            outputTokens: outputTok,
            cacheEfficiency: report.cacheEfficiency,
            series: series,
            byModel: Array(byModel),
            byProject: Array(byProject),
            showCostDisclaimer: showCostDisclaimer)
    }

    /// Costruisce la serie temporale per il range scelto a partire dai bucket del report.
    private static func series(from report: AnalyticsReport, range: AnalyticsRange) -> [SpendPoint] {
        // "Oggi": serie ORARIA (24h) — un solo bucket giornaliero darebbe un grafico con un punto.
        if range == .today, !report.byHourToday.isEmpty {
            return report.byHourToday.map { h in
                SpendPoint(date: h.startDate, cost: h.costUSD ?? 0, tokens: h.totalTokens)
            }
        }
        let limit: Int = switch range {
        case .today: 1
        case .week: 7
        case .month: 30
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = .current

        let days = report.byDay.suffix(limit)
        return days.compactMap { bucket in
            guard let date = formatter.date(from: bucket.dayKey) else { return nil }
            return SpendPoint(
                date: date,
                cost: bucket.costUSD ?? 0,
                tokens: bucket.totalTokens)
        }
    }

    // MARK: - Traduzione ProviderCostUsage → UsageCostVM (provider a consumo)

    /// Mappa il blocco costo unificato del Core nel VM presentazionale del pannello (settings-ui).
    private static func usageCostVM(from cost: ProviderCostUsage, showCostDisclaimer: Bool) -> UsageCostVM {
        let buckets = cost.buckets
            .sorted { $0.rangeDays < $1.rangeDays }
            .map { CostBucketVM(rangeDays: $0.rangeDays, costUSD: $0.costUSD, totalTokens: $0.totalTokens) }
        let byModel = cost.byModel.prefix(6).map { model in
            BreakdownItem(
                label: model.model,
                cost: model.costUSD ?? 0,
                tokens: model.totalTokens,
                symbol: "cube")
        }
        // Tetto di spesa on-demand / budget del periodo (es. on-demand Cursor, budget API): mappato
        // nel VM così la `SpendLimitCard` del pannello lo mostra (used/limit + reset).
        let spendLimit = cost.spendLimit.map { sl in
            SpendLimitVM(
                used: sl.used,
                limit: sl.limit,
                currency: sl.currency,
                period: sl.period,
                resetsAt: sl.resetsAt)
        }
        return UsageCostVM(
            buckets: buckets,
            byModel: Array(byModel),
            series: [], // serie temporale per-giorno: non esposta dallo snapshot a consumo in v1
            spendLimit: spendLimit,
            costEstimated: cost.costEstimated,
            currencyCode: cost.spendLimit?.currency ?? "USD",
            showCostDisclaimer: showCostDisclaimer)
    }
}

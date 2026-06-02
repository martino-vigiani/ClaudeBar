import SwiftUI

// MARK: - Modello presentazionale del pannello
//
// Per non bloccarci sull'AppModel reale (core-engineer) e sui tipi dominio
// (data-engineer), la UI parla con un PROTOCOLLO + tipi value presentazionali.
// L'AppModel reale verrà fatto conformare con un piccolo adapter; qui sotto c'è
// anche un mock completo per preview/sviluppo isolato.
//
// I tipi value qui replicano la SEMANTICA concordata (DECISIONS.md):
// - utilization = % USATA (0…100), il canale primario;
// - resetsAt = istante di reset della finestra;
// - il Pace è PRE-CALCOLATO da Core (la UI non rifà la matematica).

// MARK: Finestra di utilizzo (limite ufficiale)

enum WindowKind: Sendable, Hashable {
    case session      // five_hour
    case weekly       // seven_day
    case weeklyOpus   // seven_day_opus
    case weeklySonnet // seven_day_sonnet

    var eyebrow: String {
        switch self {
        case .session: String(localized: "5H SESSION")
        case .weekly: String(localized: "THIS WEEK")
        case .weeklyOpus: String(localized: "OPUS CAP")
        case .weeklySonnet: String(localized: "SONNET CAP")
        }
    }

    var symbol: String {
        switch self {
        case .session: "clock"
        case .weekly: "calendar"
        case .weeklyOpus, .weeklySonnet: "cube"
        }
    }
}

/// Stato del ritmo (verde/ambra/rosso) — DECISIONS.md "Pace & Forecast".
enum PaceStatus: Sendable {
    case onTrack   // in linea col tempo trascorso
    case over      // sopra ritmo (consumi più in fretta del tempo)
    case under     // sotto ritmo (margine)

    var label: String {
        switch self {
        case .onTrack: String(localized: "on track")
        case .over: String(localized: "over pace")
        case .under: String(localized: "under pace")
        }
    }
    /// Colore dello stato di ritmo. Semantica UX (coerente con la scala % usato):
    /// - over  = consumi più in fretta del tempo trascorso → rischio → ROSSO
    /// - onTrack = in linea col tempo → neutro/ok → AMBRA tenue
    /// - under = consumi meno del tempo (margine) → situazione migliore → VERDE
    var color: Color {
        switch self {
        case .over: UsageColorScale.color(used: 92)   // rosso
        case .onTrack: UsageColorScale.color(used: 68) // ambra tenue
        case .under: UsageColorScale.color(used: 20)   // verde
        }
    }
    var symbol: String {
        switch self {
        case .onTrack: "equal.circle"
        case .over: "arrow.up.right.circle"
        case .under: "arrow.down.right.circle"
        }
    }
}

/// Forecast/pace pre-calcolato in Core (DECISIONS.md "Matematica del pace").
struct PaceInfo: Sendable {
    /// 0…1 — dove "dovresti essere" (frazione di tempo trascorso nella finestra).
    let paceMarker: Double
    let status: PaceStatus
    /// ETA all'esaurimento al ritmo corrente. nil = arrivi al reset con margine.
    let etaToEmpty: TimeInterval?
    /// Istante assoluto di esaurimento stimato (se `etaToEmpty != nil`).
    let emptyAt: Date?
}

/// Una finestra di utilizzo pronta per la UI.
struct UsageWindowVM: Sendable, Identifiable {
    let kind: WindowKind
    /// % USATA (0…100) — canale primario.
    let utilization: Double
    let resetsAt: Date
    /// Pace/forecast pre-calcolato (può mancare per i cap per-modello).
    let pace: PaceInfo?
    /// Etichetta custom dal provider (es. Gemini "Pro"/"Flash", Cursor "Total"/"Auto"/"API").
    /// Se presente, sostituisce l'eyebrow derivato dal `kind`. `nil` per Claude (usa il kind).
    var label: String? = nil

    /// Id univoco: il kind, eventualmente disambiguato dalla label (più finestre stesso kind).
    var id: String { label.map { "\(kind)-\($0)" } ?? "\(kind)" }
    var state: UsageState { UsageState.from(used: utilization) }
    var remaining: Double { max(0, 100 - utilization) }
    /// Eyebrow da mostrare: la label custom se presente, altrimenti quella derivata dal kind.
    var eyebrow: String { label?.uppercased() ?? kind.eyebrow }
    /// Colore glance della finestra, sulla curva canonica condivisa con l'icona ("Option B").
    var glanceColor: Color { UsageColorScale.color(used: utilization) }
}

// MARK: Analytics

enum AnalyticsRange: String, Sendable, CaseIterable, Identifiable {
    case today, week, month
    var id: String { rawValue }
    var label: String {
        switch self {
        case .today: String(localized: "Today")
        case .week: String(localized: "7d")
        case .month: String(localized: "30d")
        }
    }
}

struct SpendPoint: Sendable, Identifiable {
    let date: Date
    /// Stima costo API-equivalente per il bin.
    let cost: Double
    /// Token totali del bin (per il toggle costo/token nel grafico).
    let tokens: Int
    var id: Date { date }
}

struct BreakdownItem: Sendable, Identifiable {
    let label: String      // nome modello o progetto
    let cost: Double       // stima API-equivalente
    let tokens: Int
    let symbol: String     // SF Symbol (cube / folder)
    var id: String { label }
}

struct AnalyticsVM: Sendable {
    let range: AnalyticsRange
    /// Stima API-equivalente del periodo.
    let cost: Double
    /// Delta % vs periodo precedente (nil se non calcolabile).
    let costDeltaPct: Double?
    let tokens: Int
    // Breakdown dei token del periodo (somma = `tokens`): input "nuovi", token scritti in
    // cache, token letti dalla cache, output. Alimenta la card "TOKEN" a barra impilata.
    let inputTokens: Int
    let cacheReadTokens: Int
    let cacheWriteTokens: Int
    let outputTokens: Int
    /// Efficienza cache 0…1 (cache_read / (input+cache)).
    let cacheEfficiency: Double
    let series: [SpendPoint]
    let byModel: [BreakdownItem]
    let byProject: [BreakdownItem]
    /// Mostra il disclaimer "stima API-equivalente" (preferenza Impostazioni → Analytics).
    /// Default `true` = comportamento storico (disclaimer sempre visibile).
    var showCostDisclaimer: Bool = true
}

// MARK: Identità

struct AccountVM: Sendable {
    let name: String
    let plan: String  // es. "Max"
}

// MARK: Provider (MP-6 — multi-provider)

/// Chip di un provider per lo switcher nell'header del pannello. Branding NEUTRO (solo SF Symbol,
/// nessun colore di brand — DECISIONS §3). `stateColor` opzionale = colore semantico dello stato
/// (dal % usato della finestra critica o dalla frazione di credito), per un pallino di stato.
struct ProviderChipVM: Sendable, Identifiable, Equatable {
    let id: String          // ProviderID.rawValue (stringa, per non importare Core nei VM puri)
    let name: String
    let symbol: String      // SF Symbol di fallback
    let stateColorUsed: Double?  // 0…100 % usato per derivare il colore; nil = neutro
}

// MARK: Famiglia "usage + costo" (API a consumo)

/// Bucket costo/token per un range (1 = oggi, 7, 30). Presentazionale.
struct CostBucketVM: Sendable, Identifiable, Equatable {
    let rangeDays: Int
    var id: Int { rangeDays }
    let costUSD: Double?
    let totalTokens: Int
}

/// Credito/budget residuo (API prepagate). Presentazionale.
struct CreditsVM: Sendable, Equatable {
    let remaining: Double
    let total: Double?
    let currency: String
    /// Frazione consumata 0…1 (se `total` noto e > 0).
    var usedFraction: Double? {
        guard let total, total > 0 else { return nil }
        return min(max((total - remaining) / total, 0), 1)
    }
}

/// Tetto di spesa on-demand / budget di periodo (used/limit + reset). Distinto da `CreditsVM`
/// (credito prepagato residuo): qui c'è un LIMITE speso nel periodo con un reset (es. on-demand
/// Cursor nel ciclo di fatturazione, budget mensile di un'API a consumo).
struct SpendLimitVM: Sendable, Equatable {
    let used: Double
    let limit: Double?
    let currency: String
    let period: String?
    let resetsAt: Date?
    /// Frazione consumata 0…1 (se `limit` noto e > 0).
    var usedFraction: Double? {
        guard let limit, limit > 0 else { return nil }
        return min(max(used / limit, 0), 1)
    }
}

/// Blocco "usage + costo" per i provider a consumo. Presente solo per quei provider.
/// (Non `Equatable`: `BreakdownItem`/`SpendPoint` non lo sono; non serve confrontarlo.)
struct UsageCostVM: Sendable {
    /// Bucket per range temporale (oggi/7g/30g), ordinati per `rangeDays`.
    let buckets: [CostBucketVM]
    /// Breakdown per modello (riusa `BreakdownItem`).
    let byModel: [BreakdownItem]
    /// Serie temporale per il grafico (riusa `SpendPoint`).
    let series: [SpendPoint]
    /// Tetto di spesa on-demand / budget del periodo (used/limit + reset), se esposto. `nil` = assente.
    var spendLimit: SpendLimitVM? = nil
    /// true se almeno un costo è una stima → mostra il disclaimer "stima API-equivalente".
    let costEstimated: Bool
    /// Codice valuta (default "USD").
    let currencyCode: String
    /// Mostra il disclaimer "stima API-equivalente" (preferenza Impostazioni → Analytics).
    /// Default `true` = comportamento storico. NB: il disclaimer compare comunque solo quando
    /// `costEstimated` è vero; questo flag permette all'utente di nasconderlo del tutto.
    var showCostDisclaimer: Bool = true

    /// Bucket "oggi" (rangeDays == 1) se presente.
    var today: CostBucketVM? { buckets.first(where: { $0.rangeDays == 1 }) }
    /// Bucket "mese" (rangeDays == 30) se presente.
    var month: CostBucketVM? { buckets.first(where: { $0.rangeDays == 30 }) }
}

// MARK: Stato globale del pannello

enum PanelState: Sendable, Equatable {
    case loading
    case ok
    case stale(since: Date)
    case error(message: String)
    case noAuth
    case noSubscription
}

// MARK: - Protocollo che la view consuma

/// La view legge da qui e invoca le azioni. L'AppModel reale (@Observable)
/// conformerà a questo protocollo (o useremo un thin adapter).
@MainActor
protocol PanelViewModeling: AnyObject {
    var state: PanelState { get }
    var account: AccountVM? { get }
    var lastUpdated: Date? { get }
    var isRefreshing: Bool { get }

    /// Finestra più critica (guida hero/icona). nil quando non disponibile.
    var criticalWindow: UsageWindowVM? { get }
    /// Tutte le finestre da mostrare nel pannello (sessione, settimana, cap…).
    var windows: [UsageWindowVM] { get }

    /// Analytics locali (sempre disponibili, anche offline/no-auth).
    var analytics: AnalyticsVM { get }

    // MARK: Multi-provider (MP-6) — default in extension per non rompere le conformità esistenti.

    /// Provider attivo (mostrato nel pannello/icona). Default `nil` = legacy mono-Claude.
    var activeProvider: ProviderChipVM? { get }
    /// Provider abilitati per lo switcher. Vuoto/1 → switcher nascosto (UX attuale invariata).
    var availableProviders: [ProviderChipVM] { get }
    /// Blocco usage+costo del provider attivo (API a consumo). `nil` per gli abbonamenti (Claude).
    var usageCost: UsageCostVM? { get }
    /// Credito/budget residuo del provider attivo (API prepagate). `nil` se non applicabile.
    var credits: CreditsVM? { get }
    /// Cambia il provider visualizzato (no-op nei mock legacy).
    func setActiveProvider(_ id: String)

    /// Notifica che il pannello è appena apparso → refresh on-demand se i dati sono vecchi.
    /// Default no-op: l'adapter reale la inoltra a `AppModel.panelDidOpen()`.
    func panelDidOpen()

    func refresh()
    func retry()
    func openSettings()
    func reconnect()
    func setRange(_ range: AnalyticsRange)
}

extension PanelViewModeling {
    /// Default no-op: i mock/adapter che non hanno bisogno del refresh on-demand non devono implementarla.
    func panelDidOpen() {}

    // Default multi-provider: per i mock/adapter legacy il pannello resta mono-provider (Claude
    // abbonamento), layout limiti invariato. Nessuna regressione.
    var activeProvider: ProviderChipVM? { nil }
    var availableProviders: [ProviderChipVM] { [] }
    var usageCost: UsageCostVM? { nil }
    var credits: CreditsVM? { nil }
    func setActiveProvider(_: String) {}
}

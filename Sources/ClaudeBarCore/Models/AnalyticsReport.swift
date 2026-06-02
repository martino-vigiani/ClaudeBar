import Foundation

// Report aggregato delle analytics locali (rollup multi-dimensione dai `.jsonl`).
// `Sendable + Equatable` come richiesto dall'AppModel (02 §11): l'AppModel lo passa
// opaco alla UI e l'Equatable evita ridisegni inutili.
//
// Il costo è una **"stima API-equivalente"** (DECISIONS.md): con piano Max non è spesa
// reale ma il valore a listino dei token consumati. `costEstimated` segnala quando il
// dato include alias non versionati (stima del modello esatto).

/// Totali di token + costo stimato sull'intero dataset.
public struct TokenTotals: Sendable, Equatable, Codable {
    public var input: Int
    public var output: Int
    public var cacheRead: Int
    public var cacheWrite5m: Int
    public var cacheWrite1h: Int
    public var totalTokens: Int
    /// Costo "stima API-equivalente" in USD. `nil` se nessun evento ha pricing nota.
    public var costUSD: Double?

    public init(
        input: Int,
        output: Int,
        cacheRead: Int,
        cacheWrite5m: Int,
        cacheWrite1h: Int,
        totalTokens: Int,
        costUSD: Double?)
    {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite5m = cacheWrite5m
        self.cacheWrite1h = cacheWrite1h
        self.totalTokens = totalTokens
        self.costUSD = costUSD
    }

    public static let empty = TokenTotals(
        input: 0, output: 0, cacheRead: 0, cacheWrite5m: 0, cacheWrite1h: 0,
        totalTokens: 0, costUSD: nil)
}

/// Bucket giornaliero (serie temporale per Swift Charts).
public struct DayBucket: Sendable, Equatable, Identifiable, Codable {
    public var id: String { dayKey }
    /// "yyyy-MM-dd" in TZ locale.
    public var dayKey: String
    public var totalTokens: Int
    public var costUSD: Double?
    /// Split disponibile per grafici a serie multiple.
    public var input: Int
    public var output: Int
    public var cacheRead: Int

    public init(dayKey: String, totalTokens: Int, costUSD: Double?, input: Int, output: Int, cacheRead: Int) {
        self.dayKey = dayKey
        self.totalTokens = totalTokens
        self.costUSD = costUSD
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
    }
}

/// Bucket ORARIO di oggi (per il grafico "Oggi" suddiviso in 24h: con un solo bucket
/// giornaliero il grafico era un punto solo, inutile).
public struct HourBucket: Sendable, Equatable, Identifiable, Codable {
    public var id: Int { hour }
    /// Ora del giorno locale 0…23.
    public var hour: Int
    /// Inizio dell'ora (asse X di Swift Charts).
    public var startDate: Date
    public var totalTokens: Int
    public var costUSD: Double?

    public init(hour: Int, startDate: Date, totalTokens: Int, costUSD: Double?) {
        self.hour = hour
        self.startDate = startDate
        self.totalTokens = totalTokens
        self.costUSD = costUSD
    }
}

/// Bucket per modello (normalizzato).
public struct ModelBucket: Sendable, Equatable, Identifiable, Codable {
    public var id: String { model }
    public var model: String
    public var totalTokens: Int
    public var costUSD: Double?
    /// true se il costo di questo modello è una stima (alias non versionato / fuori tabella).
    public var costEstimated: Bool

    public init(model: String, totalTokens: Int, costUSD: Double?, costEstimated: Bool) {
        self.model = model
        self.totalTokens = totalTokens
        self.costUSD = costUSD
        self.costEstimated = costEstimated
    }
}

/// Bucket per progetto (da `cwd`).
public struct ProjectBucket: Sendable, Equatable, Identifiable, Codable {
    public var id: String { projectPath }
    public var projectPath: String
    /// Nome leggibile derivato dal path (ultimo segmento).
    public var displayName: String
    public var totalTokens: Int
    public var costUSD: Double?

    public init(projectPath: String, displayName: String, totalTokens: Int, costUSD: Double?) {
        self.projectPath = projectPath
        self.displayName = displayName
        self.totalTokens = totalTokens
        self.costUSD = costUSD
    }
}

/// Bucket per sessione.
public struct SessionBucket: Sendable, Equatable, Identifiable, Codable {
    public var id: String
    public var totalTokens: Int
    public var costUSD: Double?

    public init(id: String, totalTokens: Int, costUSD: Double?) {
        self.id = id
        self.totalTokens = totalTokens
        self.costUSD = costUSD
    }
}

/// Report aggregato completo delle analytics locali.
public struct AnalyticsReport: Sendable, Equatable, Codable {
    public var totals: TokenTotals
    /// Ordinato per `dayKey` ascendente (per i grafici a linee/aree).
    public var byDay: [DayBucket]
    /// Ordinato per `totalTokens` discendente.
    public var byModel: [ModelBucket]
    /// Ordinato per `totalTokens` discendente.
    public var byProject: [ProjectBucket]
    /// Ordinato per `totalTokens` discendente.
    public var bySession: [SessionBucket]
    /// Efficienza cache = cacheRead / (cacheRead + input), 0...1. Quanto la cache risparmia.
    public var cacheEfficiency: Double
    /// true se il report include alias non versionati → la UI mostra il disclaimer "stima".
    public var costEstimated: Bool
    public var generatedAt: Date

    /// Costo "stima API-equivalente" del periodo PRECEDENTE (7 giorni prima degli ultimi 7),
    /// per il KPI "delta costo". `nil` se non c'è storico sufficiente. Vedi `costDeltaPercent`.
    public var previousPeriodCostUSD: Double?
    /// Variazione percentuale del costo ultimi-7g vs 7g-precedenti (es. +0.25 = +25%).
    /// `nil` se manca il periodo precedente o il costo precedente è 0. La UI mostra freccia su/giù + %.
    public var costDeltaPercent: Double?

    /// Breakdown per modello SCOPATO per finestra temporale, chiave = numero di giorni
    /// (1 = Oggi, 7, 30). Coerente col `byDay.suffix(N)` usato per costo/token/grafico, così
    /// quando l'utente cambia Oggi/7g/30g anche "Per modello"/"Per progetto" seguono.
    /// Vuoto per report vecchi/da cache → la UI ricade su `byModel` (intero dataset).
    public var byModelByDays: [Int: [ModelBucket]]
    /// Vedi `byModelByDays`: stesso concetto per i progetti.
    public var byProjectByDays: [Int: [ProjectBucket]]
    /// Bucket orari di OGGI (0…ora corrente) per il grafico "Oggi" in 24h. Vuoto se nessuna
    /// attività oggi → la UI ricade sul bucket giornaliero.
    public var byHourToday: [HourBucket]

    public init(
        totals: TokenTotals,
        byDay: [DayBucket],
        byModel: [ModelBucket],
        byProject: [ProjectBucket],
        bySession: [SessionBucket],
        cacheEfficiency: Double,
        costEstimated: Bool,
        generatedAt: Date,
        previousPeriodCostUSD: Double? = nil,
        costDeltaPercent: Double? = nil,
        byModelByDays: [Int: [ModelBucket]] = [:],
        byProjectByDays: [Int: [ProjectBucket]] = [:],
        byHourToday: [HourBucket] = [])
    {
        self.totals = totals
        self.byDay = byDay
        self.byModel = byModel
        self.byProject = byProject
        self.bySession = bySession
        self.cacheEfficiency = cacheEfficiency
        self.costEstimated = costEstimated
        self.generatedAt = generatedAt
        self.previousPeriodCostUSD = previousPeriodCostUSD
        self.costDeltaPercent = costDeltaPercent
        self.byModelByDays = byModelByDays
        self.byProjectByDays = byProjectByDays
        self.byHourToday = byHourToday
    }

    /// Report vuoto (degradazione elegante: analytics visibili anche senza dati).
    public static func empty(at date: Date = Date()) -> AnalyticsReport {
        AnalyticsReport(
            totals: .empty,
            byDay: [],
            byModel: [],
            byProject: [],
            bySession: [],
            cacheEfficiency: 0,
            costEstimated: false,
            generatedAt: date)
    }
}

import Foundation

// Tipi dominio dei limiti ufficiali (sessione 5h + settimanale), allineati a
// `docs/plan/02-app-architecture.md` §11 e a `DECISIONS.md` (§Reconciliazione endpoint).
//
// SEMANTICA LOCK: l'endpoint `GET /api/oauth/usage` ritorna `utilization` = **% USATA**
// (0–100), NON "remaining". Anello, percentuale e colore rappresentano tutti l'USATO:
// più alto → più rosso. `remainingPct = 100 - utilization` resta utile solo per testi
// secondari/tooltip.

/// Quale finestra di consumo rappresenta una `UsageWindow`.
///
/// Mappa 1:1 sulle chiavi reali dell'endpoint usage:
/// `five_hour`→`fiveHour`, `seven_day`→`sevenDay`,
/// `seven_day_opus`→`sevenDayOpus`, `seven_day_sonnet`→`sevenDaySonnet`.
public enum PaceWindowKind: String, Sendable, Equatable, CaseIterable, Codable {
    case fiveHour
    case sevenDay
    case sevenDayOpus
    case sevenDaySonnet

    /// Durata nominale della finestra (per il calcolo del pace).
    public var duration: TimeInterval {
        switch self {
        case .fiveHour: 5 * 60 * 60
        case .sevenDay, .sevenDayOpus, .sevenDaySonnet: 7 * 24 * 60 * 60
        }
    }

    /// Durata in minuti (300 sessione, 10080 settimana) — utile per la UI.
    public var windowMinutes: Int { Int(duration / 60) }
}

/// Una singola finestra di consumo con il suo ritmo (pace) precalcolato.
public struct UsageWindow: Sendable, Equatable, Codable {
    public var kind: PaceWindowKind
    /// 0...100, **% USATA** (0 = fresco, 100 = esaurito).
    public var utilization: Double
    /// Istante di reset della finestra (da `resets_at` ISO8601).
    public var resetsAt: Date?
    /// Proiezione Pace & Forecast calcolata in Core (vedi `PaceCalculator`).
    public var pace: PaceProjection?
    /// Durata REALE della finestra in minuti, quando NON coincide con quella nominale del
    /// `kind` (estensione multi-provider): es. quota giornaliera Gemini (1440) o ciclo di
    /// fatturazione Cursor (variabile). Se `nil`, vale `kind.duration` (caso Claude, invariato).
    /// Ha precedenza sul `kind.duration` nel calcolo del Pace.
    public var customDurationMinutes: Int?
    /// Etichetta libera della finestra (estensione multi-provider): es. "Pro"/"Flash" (Gemini),
    /// "Total"/"Auto"/"API" (Cursor). Se `nil`, la UI usa il nome derivato dal `kind` (Claude).
    public var label: String?

    public init(
        kind: PaceWindowKind,
        utilization: Double,
        resetsAt: Date?,
        pace: PaceProjection? = nil,
        customDurationMinutes: Int? = nil,
        label: String? = nil)
    {
        self.kind = kind
        self.utilization = utilization
        self.resetsAt = resetsAt
        self.pace = pace
        self.customDurationMinutes = customDurationMinutes
        self.label = label
    }

    /// Durata effettiva della finestra (custom se presente, altrimenti nominale dal `kind`).
    public var effectiveDuration: TimeInterval {
        if let customDurationMinutes { return TimeInterval(customDurationMinutes) * 60 }
        return kind.duration
    }

    /// Percentuale rimanente (0...100). Solo per testi secondari/tooltip, mai canale primario.
    public var remainingPercent: Double { max(0, 100 - utilization) }

    /// Classificazione glance sull'USATO (riusa le soglie condivise di `GlanceState`).
    public var glance: GlanceState { GlanceState.glanceState(forUsed: utilization / 100) }
}

/// Origine dei dati dello snapshot (per badge "stale" e logica di refresh).
public enum LimitsSource: String, Sendable, Equatable, Codable {
    /// Appena recuperato dalla rete.
    case live
    /// Da cache, ancora considerato valido (es. avvio a freddo).
    case cached
    /// Da cache ma vecchio (es. gate 429 attivo): mostrare badge "stale".
    case stale
}

/// Snapshot completo dei limiti ufficiali esposto alla UI.
public struct LimitsSnapshot: Sendable, Equatable {
    /// Sessione 5 ore (`five_hour`). Sempre presente.
    public var fiveHour: UsageWindow
    /// Settimana (`seven_day`). Sempre presente.
    public var sevenDay: UsageWindow
    /// Cap settimanale Opus separato (`seven_day_opus`), se presente.
    public var sevenDayOpus: UsageWindow?
    /// Cap settimanale Sonnet separato (`seven_day_sonnet`), se presente.
    public var sevenDaySonnet: UsageWindow?
    /// Crediti pay-as-you-go oltre il piano (`extra_usage`), modellati come finestra.
    public var extraUsage: UsageWindow?
    /// Tipo di abbonamento (es. "max").
    public var subscriptionType: String
    /// Etichetta account (es. "martinovigiani").
    public var accountLabel: String
    /// Quando è stato recuperato lo snapshot.
    public var fetchedAt: Date
    /// Origine dei dati (live/cached/stale).
    public var source: LimitsSource

    public init(
        fiveHour: UsageWindow,
        sevenDay: UsageWindow,
        sevenDayOpus: UsageWindow? = nil,
        sevenDaySonnet: UsageWindow? = nil,
        extraUsage: UsageWindow? = nil,
        subscriptionType: String,
        accountLabel: String,
        fetchedAt: Date,
        source: LimitsSource)
    {
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
        self.sevenDayOpus = sevenDayOpus
        self.sevenDaySonnet = sevenDaySonnet
        self.extraUsage = extraUsage
        self.subscriptionType = subscriptionType
        self.accountLabel = accountLabel
        self.fetchedAt = fetchedAt
        self.source = source
    }

    /// Tutte le finestre presenti (per iterazioni UI/glance).
    public var allWindows: [UsageWindow] {
        [fiveHour, sevenDay, sevenDayOpus, sevenDaySonnet].compactMap { $0 }
    }

    /// La finestra **più critica** = quella con `utilization` massima (messa peggio).
    /// È il riferimento per l'icona menu bar (anello + % + colore), come da `DECISIONS.md` §2.
    /// Considera sessione e settimanali (incl. cap per-modello); esclude `extraUsage`.
    public var mostCritical: UsageWindow {
        allWindows.max(by: { $0.utilization < $1.utilization }) ?? fiveHour
    }

    /// true se i dati vanno mostrati con badge "stale" (cache vecchia / gate 429).
    public var isStale: Bool { source == .stale }
}

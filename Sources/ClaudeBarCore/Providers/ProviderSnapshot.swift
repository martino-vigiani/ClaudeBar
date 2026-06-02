import Foundation

// Snapshot UNIFICATO multi-provider (BRIEF §"Modello concettuale da progettare").
//
// Un solo tipo rappresenta SIA i provider "abbonamento/limiti" (finestre con utilization% +
// reset + pace → la vista Claude attuale) SIA i provider "API a consumo" (usage token + costo
// per range, credito/budget residuo opzionale). La UI sceglie il layout in base a quali campi
// sono presenti + alle `ProviderCapabilities` del descriptor.
//
// SCELTA DI DESIGN vs CodexBar: l'upstream usa un mega-`UsageSnapshot` con ~15 campi
// provider-specifici (kiroUsage, zaiUsage, openAIAPIUsage, …). Qui unifichiamo in TRE blocchi
// opzionali e generici: `windows` (limiti), `cost` (usage+costo), `credits` (budget). Niente
// campi per-provider nel tipo di confine → la UI non deve conoscere i singoli provider.
//
// RIUSO: `UsageWindow` / `PaceWindowKind` / `PaceProjection` / `GlanceState` / `LimitsSource`
// sono i tipi dominio GIÀ esistenti e testati di Claude. Lo snapshot Claude (`LimitsSnapshot`)
// si proietta in `ProviderSnapshot` senza perdita (vedi `LimitsSnapshot.asProviderSnapshot`).

// MARK: - Identità account

/// Identità dell'account collegato (per badge/diagnostica nel pannello). Tutti i campi opzionali.
public struct ProviderAccountIdentity: Sendable, Equatable, Codable {
    /// Etichetta breve mostrabile (es. "martinovigiani", "team@acme.com").
    public var label: String?
    public var email: String?
    public var organization: String?
    /// Tipo di piano/abbonamento, se noto (es. "max", "pro", "pay-as-you-go").
    public var plan: String?

    public init(label: String? = nil, email: String? = nil, organization: String? = nil, plan: String? = nil) {
        self.label = label
        self.email = email
        self.organization = organization
        self.plan = plan
    }

    public static let empty = ProviderAccountIdentity()
}

// MARK: - Blocco costo/usage (API a consumo)

/// Token + costo "stima API-equivalente" su un intervallo (oggi/7g/30g). Riusa la semantica
/// costo del Core (DECISIONS: con piano Max il costo è una stima, non spesa reale).
public struct ProviderCostBucket: Sendable, Equatable, Codable, Identifiable {
    /// Numero di giorni del range (1 = Oggi, 7, 30). Chiave stabile per la UI.
    public var rangeDays: Int
    public var id: Int { rangeDays }
    public var inputTokens: Int
    public var outputTokens: Int
    public var totalTokens: Int
    /// Costo in USD del range. `nil` se il provider non espone un costo.
    public var costUSD: Double?
    /// true se il costo è una stima (alias di modello non versionato / fuori tabella).
    public var costEstimated: Bool

    public init(
        rangeDays: Int,
        inputTokens: Int,
        outputTokens: Int,
        totalTokens: Int,
        costUSD: Double?,
        costEstimated: Bool = false)
    {
        self.rangeDays = rangeDays
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.totalTokens = totalTokens
        self.costUSD = costUSD
        self.costEstimated = costEstimated
    }
}

/// Breakdown per modello su un range (per la sezione "Per modello" del pannello a consumo).
public struct ProviderModelCost: Sendable, Equatable, Codable, Identifiable {
    public var model: String
    public var id: String { model }
    public var totalTokens: Int
    public var costUSD: Double?
    public var costEstimated: Bool

    public init(model: String, totalTokens: Int, costUSD: Double?, costEstimated: Bool = false) {
        self.model = model
        self.totalTokens = totalTokens
        self.costUSD = costUSD
        self.costEstimated = costEstimated
    }
}

/// Blocco "usage + costo" per i provider a consumo. Presente solo se `capabilities.hasCostUsage`.
public struct ProviderCostUsage: Sendable, Equatable, Codable {
    /// Bucket per range temporale (oggi/7g/30g), ordinati per `rangeDays` ascendente.
    public var buckets: [ProviderCostBucket]
    /// Breakdown per modello sull'ultimo range disponibile (o aggregato). Vuoto se non noto.
    public var byModel: [ProviderModelCost]
    /// Tetto di spesa on-demand/budget del periodo corrente, se il provider lo espone
    /// (es. on-demand Cursor in USD col `resetsAt = billingCycleEnd`). `nil` se non applicabile.
    public var spendLimit: ProviderSpendLimit?
    /// true se almeno un costo nel blocco è una stima → la UI mostra il disclaimer.
    public var costEstimated: Bool

    public init(
        buckets: [ProviderCostBucket],
        byModel: [ProviderModelCost] = [],
        spendLimit: ProviderSpendLimit? = nil,
        costEstimated: Bool = false)
    {
        self.buckets = buckets
        self.byModel = byModel
        self.spendLimit = spendLimit
        self.costEstimated = costEstimated
    }
}

/// Tetto di spesa "on-demand"/budget di periodo (used/limit nella valuta del provider): es.
/// l'on-demand di Cursor (USD nel ciclo di fatturazione) o un budget mensile di un'API a
/// consumo. Distinto dai `buckets` (usage storico per range): qui c'è un LIMITE e un reset.
/// Tipo costo unificato richiesto da DECISIONS (§"tipo costo unificato condiviso").
public struct ProviderSpendLimit: Sendable, Equatable, Codable {
    /// Speso nel periodo corrente (valuta del provider).
    public var used: Double
    /// Tetto del periodo. `nil` = nessun limite (illimitato / non noto).
    public var limit: Double?
    /// Codice valuta ISO (es. "USD").
    public var currency: String
    /// Etichetta del periodo (es. "Monthly", "Billing cycle").
    public var period: String?
    /// Fine del periodo / reset (es. `billingCycleEnd` di Cursor).
    public var resetsAt: Date?

    public init(
        used: Double,
        limit: Double? = nil,
        currency: String = "USD",
        period: String? = nil,
        resetsAt: Date? = nil)
    {
        self.used = used
        self.limit = limit
        self.currency = currency
        self.period = period
        self.resetsAt = resetsAt
    }

    /// Frazione di budget consumata (0...1), se `limit` è noto e > 0.
    public var usedFraction: Double? {
        guard let limit, limit > 0 else { return nil }
        return min(max(used / limit, 0), 1)
    }
}

// MARK: - Blocco credito/budget

/// Credito/budget residuo (API prepagate). Presente solo se `capabilities.hasCredits`.
public struct ProviderCredits: Sendable, Equatable, Codable {
    /// Credito residuo nella valuta del provider.
    public var remaining: Double
    /// Budget/limite totale, se noto (per calcolare la % consumata).
    public var total: Double?
    /// Codice valuta ISO (es. "USD"). Default "USD".
    public var currency: String

    public init(remaining: Double, total: Double? = nil, currency: String = "USD") {
        self.remaining = remaining
        self.total = total
        self.currency = currency
    }

    /// Frazione di budget consumata (0...1), se `total` è noto e > 0.
    public var usedFraction: Double? {
        guard let total, total > 0 else { return nil }
        return min(max((total - remaining) / total, 0), 1)
    }
}

// MARK: - Snapshot unificato

/// Snapshot unificato di un provider, esposto alla UI. UN tipo per entrambe le famiglie.
public struct ProviderSnapshot: Sendable, Equatable, Codable {
    /// Quale provider ha prodotto lo snapshot.
    public var providerID: ProviderID
    /// Finestre di utilizzo (sessione/settimana/cap-modello). Vuoto per i provider a consumo.
    /// Per Claude: fiveHour, sevenDay, [sevenDayOpus], [sevenDaySonnet] (riuso `UsageWindow`).
    public var windows: [UsageWindow]
    /// Blocco usage+costo. `nil` per i provider solo-limiti.
    public var cost: ProviderCostUsage?
    /// Credito/budget residuo. `nil` se non applicabile.
    public var credits: ProviderCredits?
    /// Identità account collegata.
    public var identity: ProviderAccountIdentity
    /// Quando è stato prodotto lo snapshot.
    public var fetchedAt: Date
    /// Origine dei dati (live/cached/stale) — riusa `LimitsSource` esistente.
    public var source: LimitsSource

    public init(
        providerID: ProviderID,
        windows: [UsageWindow] = [],
        cost: ProviderCostUsage? = nil,
        credits: ProviderCredits? = nil,
        identity: ProviderAccountIdentity = .empty,
        fetchedAt: Date,
        source: LimitsSource)
    {
        self.providerID = providerID
        self.windows = windows
        self.cost = cost
        self.credits = credits
        self.identity = identity
        self.fetchedAt = fetchedAt
        self.source = source
    }

    // MARK: Derivati per la UI (parità con `LimitsSnapshot`)

    /// true se lo snapshot ha finestre-limite da rappresentare (vista "limiti").
    public var hasLimits: Bool { !windows.isEmpty }

    /// La finestra **più critica** = max(utilization). Riferimento per l'icona menu bar
    /// (DECISIONS §2). `nil` per provider a consumo (niente finestre → icona neutra/costo).
    public var mostCriticalWindow: UsageWindow? {
        windows.max(by: { $0.utilization < $1.utilization })
    }

    /// Stato glance del provider: dalla finestra più critica se ci sono limiti; altrimenti
    /// dalla frazione di credito consumata; altrimenti `.ok` (i provider a consumo non hanno
    /// un "rosso" intrinseco). Sempre sull'USATO, coerente con la semantica LOCK.
    public var glance: GlanceState {
        if let critical = mostCriticalWindow {
            return critical.glance
        }
        if let usedFrac = credits?.usedFraction {
            return GlanceState.glanceState(forUsed: usedFrac)
        }
        return .ok
    }

    /// La prima finestra di un certo tipo (comodità per il pannello).
    public func window(_ kind: PaceWindowKind) -> UsageWindow? {
        windows.first(where: { $0.kind == kind })
    }

    /// true se i dati vanno mostrati con badge "stale".
    public var isStale: Bool { source == .stale }

    /// Copia marcata stale (per la degradazione su 429 / cache vecchia).
    public func markedStale() -> ProviderSnapshot {
        var copy = self
        copy.source = .stale
        return copy
    }
}

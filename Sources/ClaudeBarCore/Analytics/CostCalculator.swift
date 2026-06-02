import Foundation

// Aggregazione [UsageEvent] deduplicati → AnalyticsReport, applicando la PricingTable.
// Costo = somma per-evento (preserva i confini di soglia long-context, nota CodexBar).
// `<synthetic>` contribuisce ai token ma è escluso dal costo; gli alias non versionati
// contribuiscono al costo come STIMA e marcano `costEstimated`.

public enum CostCalculator {
    /// Costruisce il report aggregato dagli eventi deduplicati.
    /// - Parameter includeSubagents: se `false`, gli eventi delle sessioni subagent
    ///   (`UsageEvent.isSubagent`) sono esclusi dagli aggregati (preferenza Impostazioni →
    ///   Analytics). Default `true` = comportamento storico (tutto incluso), nessuna regressione.
    public static func build(
        events allEvents: [UsageEvent],
        includeSubagents: Bool = true,
        now: Date = Date()) -> AnalyticsReport
    {
        let events = includeSubagents ? allEvents : allEvents.filter { !$0.isSubagent }
        guard !events.isEmpty else { return .empty(at: now) }

        // Accumulatori.
        var tInput = 0, tOutput = 0, tCacheRead = 0, tCw5m = 0, tCw1h = 0
        var totalCostNanos: Int = 0          // costo in "nano-USD" per somma intera precisa.
        var anyPriced = false
        var anyEstimated = false

        struct Acc { var tokens = 0; var costNanos = 0; var priced = false; var estimated = false }
        var byDay: [String: Acc] = [:]
        var byModel: [String: Acc] = [:]
        var byProject: [String: Acc] = [:]
        var bySession: [String: Acc] = [:]

        let nanos = 1_000_000_000.0

        for e in events {
            let isSynthetic = ModelNormalizer.isSynthetic(e.rawModel)
            let isAlias = ModelNormalizer.isAlias(e.rawModel)

            // Costo per-evento (nil se synthetic o modello fuori tabella).
            let cost: Double? = isSynthetic ? nil : PricingTable.cost(
                model: e.model,
                input: e.input,
                cacheRead: e.cacheRead,
                cacheWrite5m: e.cacheCreate5m,
                cacheWrite1h: e.cacheCreate1h,
                output: e.output)
            let costNanos = cost.map { Int(($0 * nanos).rounded()) } ?? 0
            let priced = cost != nil
            let estimated = priced && isAlias

            if priced { anyPriced = true }
            if estimated { anyEstimated = true }

            // Totali.
            tInput += e.input
            tOutput += e.output
            tCacheRead += e.cacheRead
            tCw5m += e.cacheCreate5m
            tCw1h += e.cacheCreate1h
            totalCostNanos += costNanos

            let tok = e.totalTokens

            func bump(_ dict: inout [String: Acc], _ key: String) {
                var a = dict[key] ?? Acc()
                a.tokens += tok
                a.costNanos += costNanos
                if priced { a.priced = true }
                if estimated { a.estimated = true }
                dict[key] = a
            }
            bump(&byDay, e.dayKey)
            bump(&byModel, e.model)
            bump(&byProject, e.projectPath)
            if let sid = e.sessionId { bump(&bySession, sid) }
        }

        func usd(_ nanosValue: Int, priced: Bool) -> Double? {
            priced ? Double(nanosValue) / nanos : nil
        }

        let totals = TokenTotals(
            input: tInput,
            output: tOutput,
            cacheRead: tCacheRead,
            cacheWrite5m: tCw5m,
            cacheWrite1h: tCw1h,
            totalTokens: tInput + tOutput + tCacheRead + tCw5m + tCw1h,
            costUSD: usd(totalCostNanos, priced: anyPriced))

        let days = byDay.map { key, a in
            DayBucket(
                dayKey: key,
                totalTokens: a.tokens,
                costUSD: usd(a.costNanos, priced: a.priced),
                input: 0, output: 0, cacheRead: 0)
        }.sorted { $0.dayKey < $1.dayKey }

        // Ricostruiamo lo split input/output/cacheRead per giorno (serve un secondo passaggio leggero).
        let daysWithSplit = withDailySplit(days, events: events)

        // Breakdown per modello/progetto SCOPATI per finestra (Oggi/7g/30g), così "Per modello"
        // e "Per progetto" seguono il range scelto, coerenti con costo/token/grafico.
        let rangeBd = rangeBreakdowns(events: events, sortedDayKeys: daysWithSplit.map(\.dayKey))

        let models = byModel.map { key, a in
            ModelBucket(
                model: key,
                totalTokens: a.tokens,
                costUSD: usd(a.costNanos, priced: a.priced),
                costEstimated: a.estimated)
        }.sorted { $0.totalTokens > $1.totalTokens }

        let projects = byProject.map { key, a in
            ProjectBucket(
                projectPath: key,
                displayName: ProjectName.display(for: key),
                totalTokens: a.tokens,
                costUSD: usd(a.costNanos, priced: a.priced))
        }.sorted { $0.totalTokens > $1.totalTokens }

        let sessions = bySession.map { key, a in
            SessionBucket(id: key, totalTokens: a.tokens, costUSD: usd(a.costNanos, priced: a.priced))
        }.sorted { $0.totalTokens > $1.totalTokens }

        // Cache efficiency = cacheRead / (cacheRead + input).
        let denom = tCacheRead + tInput
        let cacheEff = denom > 0 ? Double(tCacheRead) / Double(denom) : 0

        // KPI delta costo: ultimi 7 giorni vs 7 precedenti (sui dayKey).
        let delta = costDelta(days: daysWithSplit, now: now)

        // Bucket orari di OGGI per il grafico "Oggi" in 24h.
        let hourly = hourlyToday(events: events, now: now)

        return AnalyticsReport(
            totals: totals,
            byDay: daysWithSplit,
            byModel: models,
            byProject: projects,
            bySession: sessions,
            cacheEfficiency: cacheEff,
            costEstimated: anyEstimated,
            generatedAt: now,
            previousPeriodCostUSD: delta.previousCost,
            costDeltaPercent: delta.deltaPercent,
            byModelByDays: rangeBd.model,
            byProjectByDays: rangeBd.project,
            byHourToday: hourly)
    }

    /// Bucket orari del giorno locale di `now` (oggi), per il grafico "Oggi" suddiviso in 24h.
    /// Copre le ore da 0 all'ora corrente (zeri dove non c'è attività → linea continua).
    /// Vuoto se nessun evento è di oggi → la UI ricade sul bucket giornaliero.
    private static func hourlyToday(events: [UsageEvent], now: Date) -> [HourBucket] {
        let cal = Calendar.current
        let startOfDay = cal.startOfDay(for: now)
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = .current
        fmt.dateFormat = "yyyy-MM-dd"
        let todayKey = fmt.string(from: now)
        let currentHour = cal.component(.hour, from: now)
        let nanos = 1_000_000_000.0

        struct Acc { var tokens = 0; var costNanos = 0; var priced = false }
        var byHour: [Int: Acc] = [:]
        for e in events where e.dayKey == todayKey {
            let hour = cal.component(.hour, from: e.timestamp)
            let cost: Double? = ModelNormalizer.isSynthetic(e.rawModel) ? nil : PricingTable.cost(
                model: e.model, input: e.input, cacheRead: e.cacheRead,
                cacheWrite5m: e.cacheCreate5m, cacheWrite1h: e.cacheCreate1h, output: e.output)
            var a = byHour[hour] ?? Acc()
            a.tokens += e.totalTokens
            a.costNanos += cost.map { Int(($0 * nanos).rounded()) } ?? 0
            if cost != nil { a.priced = true }
            byHour[hour] = a
        }
        guard !byHour.isEmpty else { return [] }
        return (0...currentHour).map { h in
            let a = byHour[h] ?? Acc()
            let date = cal.date(byAdding: .hour, value: h, to: startOfDay) ?? startOfDay
            return HourBucket(
                hour: h, startDate: date,
                totalTokens: a.tokens,
                costUSD: a.priced ? Double(a.costNanos) / nanos : nil)
        }
    }

    /// Costo del periodo corrente (ultimi 7 giorni fino a `now`) vs precedente (i 7 prima).
    /// I giorni sono `dayKey` "yyyy-MM-dd" in TZ locale; "oggi" = giorno locale di `now`.
    /// - Returns: costo del periodo precedente (nil se nessun dato precedente) e % di variazione
    ///   (nil se il costo precedente è 0 o assente → la UI mostra il KPI senza delta).
    private static func costDelta(days: [DayBucket], now: Date)
        -> (previousCost: Double?, deltaPercent: Double?)
    {
        let cal = Calendar.current
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd"

        // Soglie: [currentStart, now] = ultimi 7 giorni; [prevStart, currentStart) = 7 precedenti.
        let today = cal.startOfDay(for: now)
        guard let currentStart = cal.date(byAdding: .day, value: -6, to: today),
              let prevStart = cal.date(byAdding: .day, value: -13, to: today)
        else { return (nil, nil) }
        let currentStartKey = formatter.string(from: currentStart)
        let prevStartKey = formatter.string(from: prevStart)

        var currentCost = 0.0
        var previousCost = 0.0
        var hasPrevious = false
        for d in days {
            guard let cost = d.costUSD else { continue }
            if d.dayKey >= currentStartKey {
                currentCost += cost
            } else if d.dayKey >= prevStartKey {
                previousCost += cost
                hasPrevious = true
            }
        }

        guard hasPrevious, previousCost > 0 else {
            return (hasPrevious ? previousCost : nil, nil)
        }
        let deltaPercent = (currentCost - previousCost) / previousCost
        return (previousCost, deltaPercent)
    }

    /// Arricchisce i DayBucket con lo split input/output/cacheRead (per i grafici a serie multiple).
    private static func withDailySplit(_ days: [DayBucket], events: [UsageEvent]) -> [DayBucket] {
        var splitByDay: [String: (input: Int, output: Int, cacheRead: Int)] = [:]
        for e in events {
            var s = splitByDay[e.dayKey] ?? (0, 0, 0)
            s.input += e.input
            s.output += e.output
            s.cacheRead += e.cacheRead
            splitByDay[e.dayKey] = s
        }
        return days.map { d in
            let s = splitByDay[d.dayKey] ?? (0, 0, 0)
            return DayBucket(
                dayKey: d.dayKey,
                totalTokens: d.totalTokens,
                costUSD: d.costUSD,
                input: s.input,
                output: s.output,
                cacheRead: s.cacheRead)
        }
    }

    /// Breakdown per modello/progetto per ciascuna finestra temporale (giorni: 1=Oggi, 7, 30),
    /// coerente con il `byDay.suffix(N)` usato per costo/token. Le finestre sono ANNIDATE
    /// (gli ultimi 1 giorni ⊆ ultimi 7 ⊆ ultimi 30), quindi un evento recente alimenta tutte
    /// quelle che lo includono. Il costo per-evento è ricalcolato (aritmetica leggera) per accuratezza.
    private static func rangeBreakdowns(events: [UsageEvent], sortedDayKeys: [String])
        -> (model: [Int: [ModelBucket]], project: [Int: [ProjectBucket]])
    {
        struct Acc {
            var tokens = 0; var costNanos = 0; var priced = false; var estimated = false
            mutating func add(tok: Int, cost: Int, priced: Bool, estimated: Bool) {
                tokens += tok; costNanos += cost
                if priced { self.priced = true }
                if estimated { self.estimated = true }
            }
        }

        let limits = [1, 7, 30]
        // cutoff = dayKey minimo incluso nella finestra = primo degli ultimi L giorni ATTIVI.
        var cutoffs: [Int: String] = [:]
        for L in limits { if let c = sortedDayKeys.suffix(L).first { cutoffs[L] = c } }

        let nanos = 1_000_000_000.0
        var modelAccs: [Int: [String: Acc]] = [1: [:], 7: [:], 30: [:]]
        var projectAccs: [Int: [String: Acc]] = [1: [:], 7: [:], 30: [:]]

        for e in events {
            let isSynthetic = ModelNormalizer.isSynthetic(e.rawModel)
            let isAlias = ModelNormalizer.isAlias(e.rawModel)
            let cost: Double? = isSynthetic ? nil : PricingTable.cost(
                model: e.model, input: e.input, cacheRead: e.cacheRead,
                cacheWrite5m: e.cacheCreate5m, cacheWrite1h: e.cacheCreate1h, output: e.output)
            let costNanos = cost.map { Int(($0 * nanos).rounded()) } ?? 0
            let priced = cost != nil
            let estimated = priced && isAlias
            let tok = e.totalTokens

            for L in limits {
                guard let cutoff = cutoffs[L], e.dayKey >= cutoff else { continue }
                modelAccs[L]?[e.model, default: Acc()]
                    .add(tok: tok, cost: costNanos, priced: priced, estimated: estimated)
                projectAccs[L]?[e.projectPath, default: Acc()]
                    .add(tok: tok, cost: costNanos, priced: priced, estimated: estimated)
            }
        }

        func usd(_ n: Int, _ priced: Bool) -> Double? { priced ? Double(n) / nanos : nil }
        var outModel: [Int: [ModelBucket]] = [:]
        var outProject: [Int: [ProjectBucket]] = [:]
        for L in limits {
            outModel[L] = (modelAccs[L] ?? [:]).map { key, a in
                ModelBucket(model: key, totalTokens: a.tokens,
                            costUSD: usd(a.costNanos, a.priced), costEstimated: a.estimated)
            }.sorted { $0.totalTokens > $1.totalTokens }
            outProject[L] = (projectAccs[L] ?? [:]).map { key, a in
                ProjectBucket(projectPath: key, displayName: ProjectName.display(for: key),
                              totalTokens: a.tokens, costUSD: usd(a.costNanos, a.priced))
            }.sorted { $0.totalTokens > $1.totalTokens }
        }
        return (outModel, outProject)
    }
}

/// Nome leggibile di un progetto dal path (ultimo segmento, decodificato se encoded).
enum ProjectName {
    static func display(for path: String) -> String {
        guard !path.isEmpty else { return "—" }
        return (path as NSString).lastPathComponent
    }
}

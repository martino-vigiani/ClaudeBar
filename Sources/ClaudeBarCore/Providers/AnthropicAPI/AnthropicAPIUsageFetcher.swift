import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Aggregatore Anthropic Admin → `ProviderCostUsage` (il blocco usage+costo unificato).
//
// Combina cost_report (USD) e usage_report/messages (token) in bucket per range (Oggi/7g/30g)
// + breakdown per modello, pronti per la vista "usage + costo, niente limiti".
//
// La logica di aggregazione e' separata dalla rete (`_aggregateForTesting`) per testarla con
// fixture JSON deterministiche senza toccare la rete.

enum AnthropicAPIUsageFetcher {
    /// Range mostrati nel pannello a consumo (coerenti con OpenAI API e con la UX a consumo).
    static let displayRanges = [1, 7, 30]

    /// Scarica e aggrega usage+costo. `historyDays` definisce il range piu' lungo (clamp 1...31).
    static func fetchCostUsage(
        apiKey: String,
        historyDays: Int = 30,
        session: URLSession,
        now: Date = Date()) async throws -> ProviderCostUsage
    {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ProviderError.noCredentials }

        let range = AnthropicAPIDateRange.lastDays(historyDays, now: now)
        let costs = try await AnthropicAPIUsageEndpoint.fetchCostReport(
            apiKey: trimmed, range: range, session: session, now: now)
        let messages = try await AnthropicAPIUsageEndpoint.fetchMessagesUsage(
            apiKey: trimmed, range: range, session: session, now: now)
        return self.aggregate(costs: costs, messages: messages, historyDays: historyDays, now: now)
    }

    /// Hook di test: aggrega da JSON grezzi (cost_report + messages) senza rete.
    static func _aggregateForTesting(
        costsJSON: Data,
        messagesJSON: Data,
        historyDays: Int = 30,
        now: Date) throws -> ProviderCostUsage
    {
        let costs = try JSONDecoder().decode(AnthropicCostReportResponse.self, from: costsJSON)
        let messages = try JSONDecoder().decode(AnthropicMessagesUsageResponse.self, from: messagesJSON)
        return self.aggregate(costs: costs, messages: messages, historyDays: historyDays, now: now)
    }

    // MARK: - Aggregazione

    private struct DayTotals {
        var startTime: Date
        var costUSD: Double = 0
        var inputTokens: Int = 0
        var outputTokens: Int = 0
        var totalTokens: Int = 0
        /// Token per modello in quel giorno (input+cache+output sommati per il display).
        var modelTotalTokens: [String: Int] = [:]
    }

    private static func aggregate(
        costs: AnthropicCostReportResponse,
        messages: AnthropicMessagesUsageResponse,
        historyDays: Int,
        now: Date) -> ProviderCostUsage
    {
        var days: [String: DayTotals] = [:]

        // Costo (USD) per giorno: amount in centesimi → /100.
        for bucket in costs.data {
            let key = bucket.startingAt
            var totals = days[key] ?? DayTotals(startTime: Self.parseDate(bucket.startingAt) ?? .distantPast)
            for result in bucket.results {
                totals.costUSD += (Double(result.amount) ?? 0) / 100
            }
            days[key] = totals
        }

        // Token per giorno + per modello.
        for bucket in messages.data {
            let key = bucket.startingAt
            var totals = days[key] ?? DayTotals(startTime: Self.parseDate(bucket.startingAt) ?? .distantPast)
            for result in bucket.results {
                let input = result.uncachedInputTokens ?? 0
                let cacheCreation = result.cacheCreation?.totalInputTokens ?? 0
                let cacheRead = result.cacheReadInputTokens ?? 0
                let output = result.outputTokens ?? 0
                let total = input + cacheCreation + cacheRead + output
                totals.inputTokens += input + cacheCreation + cacheRead
                totals.outputTokens += output
                totals.totalTokens += total
                let model = Self.displayName(result.model, fallback: "Anthropic API")
                totals.modelTotalTokens[model, default: 0] += total
            }
            days[key] = totals
        }

        let sortedDays = days.values
            .filter { $0.startTime <= now }
            .sorted { $0.startTime < $1.startTime }

        let buckets = Self.displayRanges.map { rangeDays in
            Self.bucket(rangeDays: rangeDays, days: sortedDays)
        }
        let byModel = Self.modelBreakdown(days: sortedDays, rangeDays: historyDays)
        return ProviderCostUsage(buckets: buckets, byModel: byModel, costEstimated: false)
    }

    /// Costruisce il bucket per gli ultimi `rangeDays` giorni (suffix sulla lista ordinata).
    private static func bucket(rangeDays: Int, days: [DayTotals]) -> ProviderCostBucket {
        let selected = days.suffix(max(1, rangeDays))
        let input = selected.reduce(0) { $0 + $1.inputTokens }
        let output = selected.reduce(0) { $0 + $1.outputTokens }
        let total = selected.reduce(0) { $0 + $1.totalTokens }
        let cost = selected.reduce(0.0) { $0 + $1.costUSD }
        return ProviderCostBucket(
            rangeDays: rangeDays,
            inputTokens: input,
            outputTokens: output,
            totalTokens: total,
            costUSD: cost,
            costEstimated: false)
    }

    /// Breakdown per modello aggregato sull'intero range mostrato, ordinato per token desc.
    private static func modelBreakdown(days: [DayTotals], rangeDays: Int) -> [ProviderModelCost] {
        let selected = days.suffix(max(1, min(AnthropicAPIUsageEndpoint.maxDailyBuckets, rangeDays)))
        var totals: [String: Int] = [:]
        for day in selected {
            for (model, tokens) in day.modelTotalTokens {
                totals[model, default: 0] += tokens
            }
        }
        return totals
            .map { ProviderModelCost(model: $0.key, totalTokens: $0.value, costUSD: nil, costEstimated: false) }
            .sorted {
                if $0.totalTokens == $1.totalTokens { return $0.model < $1.model }
                return $0.totalTokens > $1.totalTokens
            }
    }

    private static func displayName(_ raw: String?, fallback: String) -> String {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return fallback
        }
        return trimmed
    }

    private static func parseDate(_ raw: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.date(from: raw)
    }
}

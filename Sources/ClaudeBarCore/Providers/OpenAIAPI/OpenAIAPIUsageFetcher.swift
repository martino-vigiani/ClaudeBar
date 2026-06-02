import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Aggregatore OpenAI Admin → blocco usage+costo (`ProviderCostUsage`) + credito (`ProviderCredits`).
//
// Path primario: /costs (USD) + /usage/completions (token). Fallback: se le Admin usage falliscono
// (401/403 o key non-admin) e il credit_grants legacy risponde, mostriamo solo il credito residuo
// come `ProviderCredits` (caso "API prepagate"). La logica di aggregazione e' separata dalla rete.

/// Risultato del fetch OpenAI: usage+costo e/o credito residuo.
struct OpenAIAPIFetchResult: Sendable, Equatable {
    var cost: ProviderCostUsage?
    var credits: ProviderCredits?
}

enum OpenAIAPIUsageFetcher {
    static let displayRanges = [1, 7, 30]

    /// Scarica e aggrega. Primo tentativo: usage+costs Admin; su errore terminale prova il
    /// credito legacy (best-effort) se consentito.
    static func fetch(
        apiKey: String,
        projectID: String?,
        historyDays: Int = 30,
        session: URLSession,
        now: Date = Date()) async throws -> OpenAIAPIFetchResult
    {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ProviderError.noCredentials }

        let range = OpenAIAPIDateRange.lastDays(historyDays, now: now)
        do {
            let costs = try await OpenAIAPIUsageEndpoint.fetchCosts(
                apiKey: trimmed, projectID: projectID, range: range, session: session, now: now)
            let completions = try await OpenAIAPIUsageEndpoint.fetchCompletions(
                apiKey: trimmed, projectID: projectID, range: range, session: session, now: now)
            let cost = self.aggregate(costs: costs, completions: completions, historyDays: historyDays, now: now)
            return OpenAIAPIFetchResult(cost: cost, credits: nil)
        } catch {
            // Fallback legacy: solo per key senza scope progetto (Admin org reale).
            guard projectID == nil, let credits = try? await self.fetchCredits(
                apiKey: trimmed, session: session, now: now)
            else { throw error }
            return OpenAIAPIFetchResult(cost: nil, credits: credits)
        }
    }

    /// Hook di test: aggrega da JSON grezzi (costs + completions) senza rete.
    static func _aggregateForTesting(
        costsJSON: Data,
        completionsJSON: Data,
        historyDays: Int = 30,
        now: Date) throws -> ProviderCostUsage
    {
        let costs = try JSONDecoder().decode(OpenAICostsResponse.self, from: costsJSON)
        let completions = try JSONDecoder().decode(OpenAICompletionsUsageResponse.self, from: completionsJSON)
        return self.aggregate(costs: costs, completions: completions, historyDays: historyDays, now: now)
    }

    /// Hook di test: mappa il credit_grants legacy in `ProviderCredits`.
    static func _creditsForTesting(creditsJSON: Data) throws -> ProviderCredits {
        let decoded = try JSONDecoder().decode(OpenAICreditGrantsResponse.self, from: creditsJSON)
        return self.makeCredits(decoded)
    }

    private static func fetchCredits(
        apiKey: String,
        session: URLSession,
        now: Date) async throws -> ProviderCredits
    {
        let decoded = try await OpenAIAPIUsageEndpoint.fetchCreditGrants(apiKey: apiKey, session: session, now: now)
        return self.makeCredits(decoded)
    }

    private static func makeCredits(_ decoded: OpenAICreditGrantsResponse) -> ProviderCredits {
        ProviderCredits(
            remaining: max(0, decoded.totalAvailable),
            total: max(0, decoded.totalGranted),
            currency: "USD")
    }

    // MARK: - Aggregazione

    private struct DayTotals {
        var startTime: Date
        var costUSD: Double = 0
        var inputTokens: Int = 0
        var outputTokens: Int = 0
        var totalTokens: Int = 0
        var modelTotalTokens: [String: Int] = [:]
    }

    private static func aggregate(
        costs: OpenAICostsResponse,
        completions: OpenAICompletionsUsageResponse,
        historyDays: Int,
        now: Date) -> ProviderCostUsage
    {
        var days: [Int: DayTotals] = [:]

        for bucket in costs.data {
            var totals = days[bucket.startTime] ?? DayTotals(
                startTime: Date(timeIntervalSince1970: TimeInterval(bucket.startTime)))
            for result in bucket.results {
                totals.costUSD += result.amount?.value ?? 0
            }
            days[bucket.startTime] = totals
        }

        for bucket in completions.data {
            var totals = days[bucket.startTime] ?? DayTotals(
                startTime: Date(timeIntervalSince1970: TimeInterval(bucket.startTime)))
            for result in bucket.results {
                let input = (result.inputTokens ?? 0) + (result.inputAudioTokens ?? 0)
                let output = (result.outputTokens ?? 0) + (result.outputAudioTokens ?? 0)
                let total = input + output
                totals.inputTokens += input
                totals.outputTokens += output
                totals.totalTokens += total
                let model = Self.displayName(result.model, fallback: "OpenAI API")
                totals.modelTotalTokens[model, default: 0] += total
            }
            days[bucket.startTime] = totals
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

    private static func bucket(rangeDays: Int, days: [DayTotals]) -> ProviderCostBucket {
        let selected = days.suffix(max(1, rangeDays))
        return ProviderCostBucket(
            rangeDays: rangeDays,
            inputTokens: selected.reduce(0) { $0 + $1.inputTokens },
            outputTokens: selected.reduce(0) { $0 + $1.outputTokens },
            totalTokens: selected.reduce(0) { $0 + $1.totalTokens },
            costUSD: selected.reduce(0.0) { $0 + $1.costUSD },
            costEstimated: false)
    }

    private static func modelBreakdown(days: [DayTotals], rangeDays: Int) -> [ProviderModelCost] {
        let selected = days.suffix(max(1, min(OpenAIAPIUsageEndpoint.maxDailyBuckets, rangeDays)))
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
}

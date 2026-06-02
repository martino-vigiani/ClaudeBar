import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Endpoint Anthropic "Usage & Cost Admin API" per il provider "a consumo" (.anthropicAPI).
// Verificati sulla doc ufficiale (platform.claude.com/docs/en/api/usage-cost-api, giu 2026) e
// sull'upstream CodexBar (ClaudeAdminAPIUsageFetcher):
//   GET https://api.anthropic.com/v1/organizations/cost_report   → costo USD (group_by=description)
//   GET https://api.anthropic.com/v1/organizations/usage_report/messages → token (group_by=model)
//
// Auth: header `x-api-key: <ADMIN_KEY>` (chiave Admin org `sk-ant-admin...`, NON la normale API
// key) + `anthropic-version: 2023-06-01`. L'Admin API NON e' disponibile per account individuali:
// in quel caso il server risponde 401/403 → `ProviderError.unauthorized` (terminale, niente loop).
//
// SHAPE: nel cost_report `amount` e' una STRINGA decimale in UNITA' MINIME (centesimi) → USD = /100.

/// Risposta grezza del cost_report (solo i campi che usiamo).
struct AnthropicCostReportResponse: Decodable, Sendable {
    let data: [Bucket]
    let hasMore: Bool?
    let nextPage: String?

    struct Bucket: Decodable, Sendable {
        let startingAt: String
        let endingAt: String
        let results: [Result]

        enum CodingKeys: String, CodingKey {
            case startingAt = "starting_at"
            case endingAt = "ending_at"
            case results
        }
    }

    struct Result: Decodable, Sendable {
        let currency: String?
        /// Stringa decimale in centesimi (es. "1234" = 12.34 USD).
        let amount: String
        let description: String?
        let costType: String?

        enum CodingKeys: String, CodingKey {
            case currency
            case amount
            case description
            case costType = "cost_type"
        }
    }

    enum CodingKeys: String, CodingKey {
        case data
        case hasMore = "has_more"
        case nextPage = "next_page"
    }
}

/// Risposta grezza dell'usage_report/messages (solo i campi che usiamo).
struct AnthropicMessagesUsageResponse: Decodable, Sendable {
    let data: [Bucket]
    let hasMore: Bool?
    let nextPage: String?

    struct Bucket: Decodable, Sendable {
        let startingAt: String
        let endingAt: String
        let results: [Result]

        enum CodingKeys: String, CodingKey {
            case startingAt = "starting_at"
            case endingAt = "ending_at"
            case results
        }
    }

    struct Result: Decodable, Sendable {
        let uncachedInputTokens: Int?
        let cacheCreation: CacheCreation?
        let cacheReadInputTokens: Int?
        let outputTokens: Int?
        let model: String?

        enum CodingKeys: String, CodingKey {
            case uncachedInputTokens = "uncached_input_tokens"
            case cacheCreation = "cache_creation"
            case cacheReadInputTokens = "cache_read_input_tokens"
            case outputTokens = "output_tokens"
            case model
        }
    }

    struct CacheCreation: Decodable, Sendable {
        let ephemeral1HInputTokens: Int?
        let ephemeral5MInputTokens: Int?

        var totalInputTokens: Int {
            (self.ephemeral1HInputTokens ?? 0) + (self.ephemeral5MInputTokens ?? 0)
        }

        enum CodingKeys: String, CodingKey {
            case ephemeral1HInputTokens = "ephemeral_1h_input_tokens"
            case ephemeral5MInputTokens = "ephemeral_5m_input_tokens"
        }
    }

    enum CodingKeys: String, CodingKey {
        case data
        case hasMore = "has_more"
        case nextPage = "next_page"
    }
}

/// Esegue le due GET dell'Admin API e decodifica le risposte. La logica di aggregazione vive
/// in `AnthropicAPIUsageFetcher` (testabile separatamente con `_aggregateForTesting`).
enum AnthropicAPIUsageEndpoint {
    static let costReportURL = URL(string: "https://api.anthropic.com/v1/organizations/cost_report")!
    static let messagesUsageURL =
        URL(string: "https://api.anthropic.com/v1/organizations/usage_report/messages")!

    static let anthropicVersion = "2023-06-01"
    static let timeoutSeconds: TimeInterval = 20
    /// Max bucket per `bucket_width=1d` (limite API). 31 giorni coprono "ultimi 30g".
    static let maxDailyBuckets = 31

    /// Scarica il cost_report (USD per giorno, group_by=description).
    static func fetchCostReport(
        apiKey: String,
        range: AnthropicAPIDateRange,
        baseURL: URL = costReportURL,
        session: URLSession,
        now: Date = Date()) async throws -> AnthropicCostReportResponse
    {
        let url = self.url(
            baseURL: baseURL,
            range: range,
            extraItems: [URLQueryItem(name: "group_by[]", value: "description")])
        let data = try await self.fetchData(url: url, apiKey: apiKey, session: session, now: now)
        do {
            return try JSONDecoder().decode(AnthropicCostReportResponse.self, from: data)
        } catch {
            throw ProviderError.invalidResponse
        }
    }

    /// Scarica l'usage_report/messages (token per giorno, group_by=model).
    static func fetchMessagesUsage(
        apiKey: String,
        range: AnthropicAPIDateRange,
        baseURL: URL = messagesUsageURL,
        session: URLSession,
        now: Date = Date()) async throws -> AnthropicMessagesUsageResponse
    {
        let url = self.url(
            baseURL: baseURL,
            range: range,
            extraItems: [URLQueryItem(name: "group_by[]", value: "model")])
        let data = try await self.fetchData(url: url, apiKey: apiKey, session: session, now: now)
        do {
            return try JSONDecoder().decode(AnthropicMessagesUsageResponse.self, from: data)
        } catch {
            throw ProviderError.invalidResponse
        }
    }

    private static func fetchData(
        url: URL,
        apiKey: String,
        session: URLSession,
        now: Date) async throws -> Data
    {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = self.timeoutSeconds
        request.setValue(self.anthropicVersion, forHTTPHeaderField: "anthropic-version")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("ClaudeBar/1.0 (https://github.com/subralabs/claudebar)", forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ProviderError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw ProviderError.invalidResponse
        }
        switch http.statusCode {
        case 200:
            return data
        case 401, 403:
            // Admin API non disponibile / key non valida o senza permessi org → terminale.
            throw ProviderError.unauthorized(String(data: data, encoding: .utf8))
        case 429:
            throw ProviderError.rateLimited(retryAfter: Self.retryAfterDate(from: http, now: now))
        default:
            throw ProviderError.serverError(code: http.statusCode, body: String(data: data, encoding: .utf8))
        }
    }

    private static func url(baseURL: URL, range: AnthropicAPIDateRange, extraItems: [URLQueryItem]) -> URL {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "starting_at", value: AnthropicAPIDateRange.rfc3339(range.start)),
            URLQueryItem(name: "ending_at", value: AnthropicAPIDateRange.rfc3339(range.end)),
            URLQueryItem(name: "bucket_width", value: "1d"),
            URLQueryItem(name: "limit", value: String(self.maxDailyBuckets)),
        ] + extraItems
        return components.url!
    }

    static func retryAfterDate(from response: HTTPURLResponse, now: Date) -> Date? {
        guard let raw = response.value(forHTTPHeaderField: "Retry-After")?
            .trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty
        else { return nil }
        if let seconds = TimeInterval(raw), seconds >= 0 {
            return now.addingTimeInterval(seconds)
        }
        return nil
    }
}

/// Intervallo giornaliero in UTC per le query Admin (inclusivo sui giorni richiesti).
struct AnthropicAPIDateRange: Sendable, Equatable {
    let start: Date
    let end: Date

    /// Costruisce un range che copre gli ultimi `days` giorni (clamp 1...31) fino a `now`.
    static func lastDays(_ days: Int, now: Date) -> AnthropicAPIDateRange {
        let clamped = max(1, min(AnthropicAPIUsageEndpoint.maxDailyBuckets, days))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let today = calendar.startOfDay(for: now)
        let start = calendar.date(byAdding: .day, value: -(clamped - 1), to: today) ?? today
        let end = calendar.date(byAdding: .day, value: 1, to: today) ?? now
        return AnthropicAPIDateRange(start: start, end: end)
    }

    static func rfc3339(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }
}

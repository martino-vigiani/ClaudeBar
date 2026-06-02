import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Endpoint OpenAI "Organization Usage & Costs API" per il provider "a consumo" (.openaiAPI).
// Verificati sull'upstream CodexBar (OpenAIAPIUsageFetcher) e sulla doc OpenAI Administration:
//   GET https://api.openai.com/v1/organization/costs            → costo USD (group_by=line_item)
//   GET https://api.openai.com/v1/organization/usage/completions → token (group_by=model)
//   GET https://api.openai.com/v1/dashboard/billing/credit_grants → credito (LEGACY, fallback)
//
// Auth: header `Authorization: Bearer <ADMIN_KEY>` (chiave Admin `sk-admin-...`). 401/403 →
// `ProviderError.unauthorized` (terminale). `start_time`/`end_time` sono epoch seconds (Int).

/// Risposta grezza dei /costs (solo i campi usati).
struct OpenAICostsResponse: Decodable, Sendable {
    let data: [Bucket]

    struct Bucket: Decodable, Sendable {
        let startTime: Int
        let endTime: Int
        let results: [Result]

        enum CodingKeys: String, CodingKey {
            case startTime = "start_time"
            case endTime = "end_time"
            case results
        }
    }

    struct Result: Decodable, Sendable {
        let amount: Amount?
        let lineItem: String?

        enum CodingKeys: String, CodingKey {
            case amount
            case lineItem = "line_item"
        }
    }

    struct Amount: Decodable, Sendable {
        let value: Double?
    }
}

/// Risposta grezza delle /usage/completions (solo i campi usati).
struct OpenAICompletionsUsageResponse: Decodable, Sendable {
    let data: [Bucket]

    struct Bucket: Decodable, Sendable {
        let startTime: Int
        let endTime: Int
        let results: [Result]

        enum CodingKeys: String, CodingKey {
            case startTime = "start_time"
            case endTime = "end_time"
            case results
        }
    }

    struct Result: Decodable, Sendable {
        let inputTokens: Int?
        let inputCachedTokens: Int?
        let outputTokens: Int?
        let inputAudioTokens: Int?
        let outputAudioTokens: Int?
        let numModelRequests: Int?
        let model: String?

        enum CodingKeys: String, CodingKey {
            case inputTokens = "input_tokens"
            case inputCachedTokens = "input_cached_tokens"
            case outputTokens = "output_tokens"
            case inputAudioTokens = "input_audio_tokens"
            case outputAudioTokens = "output_audio_tokens"
            case numModelRequests = "num_model_requests"
            case model
        }
    }
}

/// Risposta grezza del credit_grants legacy.
struct OpenAICreditGrantsResponse: Decodable, Sendable {
    let totalGranted: Double
    let totalUsed: Double
    let totalAvailable: Double

    enum CodingKeys: String, CodingKey {
        case totalGranted = "total_granted"
        case totalUsed = "total_used"
        case totalAvailable = "total_available"
    }
}

enum OpenAIAPIUsageEndpoint {
    static let costsURL = URL(string: "https://api.openai.com/v1/organization/costs")!
    static let completionsURL = URL(string: "https://api.openai.com/v1/organization/usage/completions")!
    static let creditGrantsURL = URL(string: "https://api.openai.com/v1/dashboard/billing/credit_grants")!

    static let timeoutSeconds: TimeInterval = 20
    /// Max bucket per `bucket_width=1d` (limite API).
    static let maxDailyBuckets = 31

    static func fetchCosts(
        apiKey: String,
        projectID: String?,
        range: OpenAIAPIDateRange,
        baseURL: URL = costsURL,
        session: URLSession,
        now: Date = Date()) async throws -> OpenAICostsResponse
    {
        let url = self.url(
            baseURL: baseURL,
            range: range,
            extraItems: [URLQueryItem(name: "group_by", value: "line_item")] + Self.projectItems(projectID))
        let data = try await self.fetchData(url: url, apiKey: apiKey, session: session, now: now)
        do {
            return try JSONDecoder().decode(OpenAICostsResponse.self, from: data)
        } catch {
            throw ProviderError.invalidResponse
        }
    }

    static func fetchCompletions(
        apiKey: String,
        projectID: String?,
        range: OpenAIAPIDateRange,
        baseURL: URL = completionsURL,
        session: URLSession,
        now: Date = Date()) async throws -> OpenAICompletionsUsageResponse
    {
        let url = self.url(
            baseURL: baseURL,
            range: range,
            extraItems: [URLQueryItem(name: "group_by", value: "model")] + Self.projectItems(projectID))
        let data = try await self.fetchData(url: url, apiKey: apiKey, session: session, now: now)
        do {
            return try JSONDecoder().decode(OpenAICompletionsUsageResponse.self, from: data)
        } catch {
            throw ProviderError.invalidResponse
        }
    }

    /// Fallback legacy: credito residuo. Spesso 403 con project key → lasciamo emergere l'errore.
    static func fetchCreditGrants(
        apiKey: String,
        baseURL: URL = creditGrantsURL,
        session: URLSession,
        now: Date = Date()) async throws -> OpenAICreditGrantsResponse
    {
        var request = URLRequest(url: baseURL)
        request.httpMethod = "GET"
        request.timeoutInterval = self.timeoutSeconds
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ProviderError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw ProviderError.invalidResponse }
        switch http.statusCode {
        case 200:
            do {
                return try JSONDecoder().decode(OpenAICreditGrantsResponse.self, from: data)
            } catch {
                throw ProviderError.invalidResponse
            }
        case 401, 403:
            throw ProviderError.unauthorized(String(data: data, encoding: .utf8))
        case 429:
            throw ProviderError.rateLimited(retryAfter: Self.retryAfterDate(from: http, now: now))
        default:
            throw ProviderError.serverError(code: http.statusCode, body: String(data: data, encoding: .utf8))
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
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ProviderError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw ProviderError.invalidResponse }
        switch http.statusCode {
        case 200:
            return data
        case 401, 403:
            throw ProviderError.unauthorized(String(data: data, encoding: .utf8))
        case 429:
            throw ProviderError.rateLimited(retryAfter: Self.retryAfterDate(from: http, now: now))
        default:
            throw ProviderError.serverError(code: http.statusCode, body: String(data: data, encoding: .utf8))
        }
    }

    private static func projectItems(_ projectID: String?) -> [URLQueryItem] {
        guard let projectID, !projectID.isEmpty else { return [] }
        return [URLQueryItem(name: "project_ids", value: projectID)]
    }

    private static func url(baseURL: URL, range: OpenAIAPIDateRange, extraItems: [URLQueryItem]) -> URL {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "start_time", value: String(range.startTime)),
            URLQueryItem(name: "end_time", value: String(range.endTime)),
            URLQueryItem(name: "bucket_width", value: "1d"),
            URLQueryItem(name: "limit", value: String(range.limit)),
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

/// Intervallo giornaliero (epoch seconds) per le query OpenAI.
struct OpenAIAPIDateRange: Sendable, Equatable {
    let startTime: Int
    let endTime: Int
    let limit: Int

    /// Range che copre gli ultimi `days` giorni (clamp 1...31) fino a `now`, in UTC.
    static func lastDays(_ days: Int, now: Date) -> OpenAIAPIDateRange {
        let clamped = max(1, min(OpenAIAPIUsageEndpoint.maxDailyBuckets, days))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let today = calendar.startOfDay(for: now)
        let start = calendar.date(byAdding: .day, value: -(clamped - 1), to: today) ?? today
        let end = calendar.date(byAdding: .day, value: 1, to: today) ?? now
        return OpenAIAPIDateRange(
            startTime: Int(start.timeIntervalSince1970),
            endTime: Int(end.timeIntervalSince1970),
            limit: clamped)
    }
}

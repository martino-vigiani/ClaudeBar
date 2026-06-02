import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Endpoint usage ufficiale: GET https://api.anthropic.com/api/oauth/usage
// Header e shape verificati sull'upstream CodexBar (ClaudeOAuthUsageFetcher) e su DECISIONS.md.

/// Risposta grezza dell'endpoint usage. Chiavi reali: `five_hour`, `seven_day`,
/// `seven_day_opus`, `seven_day_sonnet`, `extra_usage`.
public struct OAuthUsageResponse: Decodable, Sendable {
    public let fiveHour: OAuthUsageWindow?
    public let sevenDay: OAuthUsageWindow?
    public let sevenDayOpus: OAuthUsageWindow?
    public let sevenDaySonnet: OAuthUsageWindow?
    public let extraUsage: OAuthExtraUsage?

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DynamicKey.self)
        self.fiveHour = Self.decode(in: c, key: "five_hour")
        self.sevenDay = Self.decode(in: c, key: "seven_day")
        self.sevenDayOpus = Self.decode(in: c, key: "seven_day_opus")
        self.sevenDaySonnet = Self.decode(in: c, key: "seven_day_sonnet")
        self.extraUsage = Self.decode(in: c, key: "extra_usage")
    }

    private static func decode<T: Decodable>(in c: KeyedDecodingContainer<DynamicKey>, key: String) -> T? {
        guard let k = DynamicKey(stringValue: key) else { return nil }
        return (try? c.decodeIfPresent(T.self, forKey: k)) ?? nil
    }

    private struct DynamicKey: CodingKey {
        let stringValue: String
        let intValue: Int? = nil
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }
}

/// Finestra grezza: `utilization` (0–100, % USATA) + `resets_at` (ISO8601).
public struct OAuthUsageWindow: Decodable, Sendable {
    public let utilization: Double?
    public let resetsAt: String?

    enum CodingKeys: String, CodingKey {
        case utilization
        case resetsAt = "resets_at"
    }
}

/// Crediti pay-as-you-go (`extra_usage`). Valori monetari in **centesimi** (→ /100 per USD).
public struct OAuthExtraUsage: Decodable, Sendable {
    public let isEnabled: Bool?
    public let monthlyLimit: Double?
    public let usedCredits: Double?
    public let utilization: Double?
    public let currency: String?

    enum CodingKeys: String, CodingKey {
        case isEnabled = "is_enabled"
        case monthlyLimit = "monthly_limit"
        case usedCredits = "used_credits"
        case utilization
        case currency
    }
}

public enum ClaudeUsageEndpoint {
    public static let url = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    public static let betaHeader = "oauth-2025-04-20"
    public static let fallbackVersion = "2.1.0"

    /// Esegue la GET e decodifica la risposta.
    /// - Throws: `ClaudeLimitsError` (unauthorized/rateLimited/serverError/network/invalidResponse).
    public static func fetch(
        accessToken: String,
        claudeCodeVersion: String?,
        session: URLSession,
        now: Date = Date()) async throws -> OAuthUsageResponse
    {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(betaHeader, forHTTPHeaderField: "anthropic-beta")
        request.setValue(userAgent(version: claudeCodeVersion), forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ClaudeLimitsError.network(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw ClaudeLimitsError.invalidResponse
        }

        switch http.statusCode {
        case 200:
            do {
                return try JSONDecoder().decode(OAuthUsageResponse.self, from: data)
            } catch {
                throw ClaudeLimitsError.invalidResponse
            }
        case 401:
            throw ClaudeLimitsError.unauthorized
        case 429:
            throw ClaudeLimitsError.rateLimited(retryAfter: retryAfterDate(from: http, now: now))
        default:
            let body = String(data: data, encoding: .utf8)
            throw ClaudeLimitsError.serverError(code: http.statusCode, body: body)
        }
    }

    /// Parsa una data ISO8601 (con o senza frazioni di secondo).
    public static func parseISO8601(_ string: String?) -> Date? {
        guard let string, !string.isEmpty else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: string) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: string)
    }

    /// Legge l'header `Retry-After` (secondi o data RFC1123).
    static func retryAfterDate(from response: HTTPURLResponse, now: Date) -> Date? {
        guard let raw = response.value(forHTTPHeaderField: "Retry-After")?
            .trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty
        else { return nil }

        if let seconds = TimeInterval(raw), seconds >= 0 {
            return now.addingTimeInterval(seconds)
        }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss zzz"
        return f.date(from: raw)
    }

    static func userAgent(version: String?) -> String {
        let v = version?
            .split(whereSeparator: \.isWhitespace).first.map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let resolved = (v?.isEmpty == false ? v! : fallbackVersion)
        return "claude-code/\(resolved)"
    }
}

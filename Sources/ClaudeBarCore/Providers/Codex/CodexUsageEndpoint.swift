import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Endpoint usage di Codex (abbonamento ChatGPT/Codex plan), verificato sull'upstream CodexBar:
//   GET https://chatgpt.com/backend-api/wham/usage         (base default)
//   GET <base>/api/codex/usage                             (base self-host senza /backend-api)
// La base URL può essere ridefinita da `chatgpt_base_url` in `~/.codex/config.toml`.
//
// Header: Authorization: Bearer <accessToken>, Accept: application/json, User-Agent: ClaudeBar,
//         ChatGPT-Account-Id: <accountId> (solo se presente, per workspace multi-account).
//
// Shape (decodifica DIFENSIVA — endpoint non documentato ufficialmente, può cambiare):
//   {
//     "plan_type": "pro",
//     "rate_limit": {
//       "primary_window":   { "used_percent": 42, "reset_at": 1717250000, "limit_window_seconds": 18000 },
//       "secondary_window": { "used_percent": 71, "reset_at": 1717700000, "limit_window_seconds": 604800 }
//     },
//     "credits": { "has_credits": true, "unlimited": false, "balance": 12.50 },
//     "additional_rate_limits": [ { "limit_name": "Codex Spark", "rate_limit": { … } } ]
//   }
// `used_percent` = % USATA (0–100, stessa semantica di Claude). `reset_at` = EPOCH SECONDS.

/// Risposta usage di Codex. Ogni campo è opzionale e decodificato con `try?`: un campo rotto
/// non fa fallire l'intera risposta (un singolo limite malformato non scarta i fratelli validi).
public struct CodexUsageResponse: Decodable, Sendable, Equatable {
    public let planType: String?
    public let rateLimit: RateLimit?
    public let credits: Credits?
    public let additionalRateLimits: [AdditionalRateLimit]

    enum CodingKeys: String, CodingKey {
        case planType = "plan_type"
        case rateLimit = "rate_limit"
        case credits
        case additionalRateLimits = "additional_rate_limits"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.planType = (try? container.decodeIfPresent(String.self, forKey: .planType)) ?? nil
        self.rateLimit = (try? container.decodeIfPresent(RateLimit.self, forKey: .rateLimit)) ?? nil
        self.credits = (try? container.decodeIfPresent(Credits.self, forKey: .credits)) ?? nil
        // Decodifica per-elemento lossy: una entry malformata diventa nil e viene scartata,
        // senza buttare via le sorelle valide.
        let lossy = (try? container.decodeIfPresent([LossyAdditionalRateLimit].self, forKey: .additionalRateLimits)) ?? nil
        self.additionalRateLimits = lossy?.compactMap(\.value) ?? []
    }

    /// Costruttore diretto (per i test / proiezioni).
    public init(
        planType: String?,
        rateLimit: RateLimit?,
        credits: Credits?,
        additionalRateLimits: [AdditionalRateLimit] = [])
    {
        self.planType = planType
        self.rateLimit = rateLimit
        self.credits = credits
        self.additionalRateLimits = additionalRateLimits
    }

    /// Coppia di finestre (sessione + settimanale).
    public struct RateLimit: Decodable, Sendable, Equatable {
        public let primaryWindow: Window?
        public let secondaryWindow: Window?

        enum CodingKeys: String, CodingKey {
            case primaryWindow = "primary_window"
            case secondaryWindow = "secondary_window"
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.primaryWindow = (try? container.decodeIfPresent(Window.self, forKey: .primaryWindow)) ?? nil
            self.secondaryWindow = (try? container.decodeIfPresent(Window.self, forKey: .secondaryWindow)) ?? nil
        }

        public init(primaryWindow: Window?, secondaryWindow: Window?) {
            self.primaryWindow = primaryWindow
            self.secondaryWindow = secondaryWindow
        }
    }

    /// Una singola finestra: % usata + reset (epoch) + durata della finestra in secondi.
    public struct Window: Decodable, Sendable, Equatable {
        public let usedPercent: Double
        public let resetAt: Int
        public let limitWindowSeconds: Int

        enum CodingKeys: String, CodingKey {
            case usedPercent = "used_percent"
            case resetAt = "reset_at"
            case limitWindowSeconds = "limit_window_seconds"
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            // `used_percent` può arrivare come Int o Double a seconda della build server.
            if let value = try? container.decode(Double.self, forKey: .usedPercent) {
                self.usedPercent = value
            } else {
                self.usedPercent = 0
            }
            self.resetAt = (try? container.decode(Int.self, forKey: .resetAt)) ?? 0
            self.limitWindowSeconds = (try? container.decode(Int.self, forKey: .limitWindowSeconds)) ?? 0
        }

        public init(usedPercent: Double, resetAt: Int, limitWindowSeconds: Int) {
            self.usedPercent = usedPercent
            self.resetAt = resetAt
            self.limitWindowSeconds = limitWindowSeconds
        }
    }

    /// Limite per-modello aggiuntivo (es. Codex Spark): stessa shape della coppia primary/secondary.
    public struct AdditionalRateLimit: Decodable, Sendable, Equatable {
        public let limitName: String?
        public let meteredFeature: String?
        public let rateLimit: RateLimit?

        enum CodingKeys: String, CodingKey {
            case limitName = "limit_name"
            case meteredFeature = "metered_feature"
            case rateLimit = "rate_limit"
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.limitName = (try? container.decodeIfPresent(String.self, forKey: .limitName)) ?? nil
            self.meteredFeature = (try? container.decodeIfPresent(String.self, forKey: .meteredFeature)) ?? nil
            self.rateLimit = (try? container.decodeIfPresent(RateLimit.self, forKey: .rateLimit)) ?? nil
        }

        public init(limitName: String?, meteredFeature: String?, rateLimit: RateLimit?) {
            self.limitName = limitName
            self.meteredFeature = meteredFeature
            self.rateLimit = rateLimit
        }
    }

    /// Crediti pay-as-you-go oltre il piano.
    public struct Credits: Decodable, Sendable, Equatable {
        public let hasCredits: Bool
        public let unlimited: Bool
        public let balance: Double?

        enum CodingKeys: String, CodingKey {
            case hasCredits = "has_credits"
            case unlimited
            case balance
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.hasCredits = (try? container.decode(Bool.self, forKey: .hasCredits)) ?? false
            self.unlimited = (try? container.decode(Bool.self, forKey: .unlimited)) ?? false
            // `balance` può essere numero o stringa numerica.
            if let value = try? container.decode(Double.self, forKey: .balance) {
                self.balance = value
            } else if let raw = try? container.decode(String.self, forKey: .balance), let value = Double(raw) {
                self.balance = value
            } else {
                self.balance = nil
            }
        }

        public init(hasCredits: Bool, unlimited: Bool, balance: Double?) {
            self.hasCredits = hasCredits
            self.unlimited = unlimited
            self.balance = balance
        }
    }

    /// Decodifica non-throwing di un singolo `additional_rate_limits` (lossy per-elemento).
    private struct LossyAdditionalRateLimit: Decodable {
        let value: AdditionalRateLimit?
        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            self.value = try? container.decode(AdditionalRateLimit.self)
        }
    }
}

/// Endpoint usage Codex: risoluzione URL + fetch + decode difensivo.
public enum CodexUsageEndpoint {
    public static let defaultBaseURL = "https://chatgpt.com/backend-api"
    static let chatGPTUsagePath = "/wham/usage"
    static let codexUsagePath = "/api/codex/usage"

    /// Esegue la GET usage e decodifica `CodexUsageResponse`.
    /// - Throws: `ProviderError` (unauthorized/rateLimited/serverError/network/invalidResponse).
    public static func fetch(
        accessToken: String,
        accountId: String?,
        session: URLSession,
        env: [String: String] = ProcessInfo.processInfo.environment,
        now: Date = Date()) async throws -> CodexUsageResponse
    {
        var request = URLRequest(url: self.resolveUsageURL(env: env))
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("ClaudeBar", forHTTPHeaderField: "User-Agent")
        if let accountId, !accountId.isEmpty {
            request.setValue(accountId, forHTTPHeaderField: "ChatGPT-Account-Id")
        }

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
                return try JSONDecoder().decode(CodexUsageResponse.self, from: data)
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

    // MARK: - Risoluzione URL

    /// URL usage completa, considerando l'eventuale override `chatgpt_base_url` in `config.toml`.
    public static func resolveUsageURL(
        env: [String: String] = ProcessInfo.processInfo.environment,
        configContents: String? = nil,
        fileManager: FileManager = .default) -> URL
    {
        let base = self.resolveBaseURL(env: env, configContents: configContents, fileManager: fileManager)
        let normalized = self.normalize(base)
        let path = normalized.contains("/backend-api") ? Self.chatGPTUsagePath : Self.codexUsagePath
        return URL(string: normalized + path)
            ?? URL(string: Self.defaultBaseURL + Self.chatGPTUsagePath)!
    }

    private static func resolveBaseURL(
        env: [String: String],
        configContents: String?,
        fileManager: FileManager) -> String
    {
        if let configContents, let parsed = self.parseBaseURL(from: configContents) {
            return parsed
        }
        if let contents = self.loadConfigContents(env: env, fileManager: fileManager),
           let parsed = self.parseBaseURL(from: contents)
        {
            return parsed
        }
        return Self.defaultBaseURL
    }

    private static func normalize(_ value: String) -> String {
        var trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { trimmed = Self.defaultBaseURL }
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        // chatgpt.com / chat.openai.com senza /backend-api → aggiungilo.
        if (trimmed.hasPrefix("https://chatgpt.com") || trimmed.hasPrefix("https://chat.openai.com")),
           !trimmed.contains("/backend-api")
        {
            trimmed += "/backend-api"
        }
        return trimmed
    }

    /// Estrae `chatgpt_base_url = "…"` da un contenuto TOML (ignora commenti `#`).
    static func parseBaseURL(from contents: String) -> String? {
        for rawLine in contents.split(whereSeparator: \.isNewline) {
            let line = rawLine.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: true).first
            let trimmed = line?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !trimmed.isEmpty else { continue }
            let parts = trimmed.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count == 2 else { continue }
            guard parts[0].trimmingCharacters(in: .whitespacesAndNewlines) == "chatgpt_base_url" else { continue }
            var value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            if (value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'")) {
                value = String(value.dropFirst().dropLast())
            }
            return value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    private static func loadConfigContents(env: [String: String], fileManager: FileManager) -> String? {
        let url = CodexHomeScope.homeURL(env: env, fileManager: fileManager)
            .appendingPathComponent("config.toml")
        return try? String(contentsOf: url, encoding: .utf8)
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

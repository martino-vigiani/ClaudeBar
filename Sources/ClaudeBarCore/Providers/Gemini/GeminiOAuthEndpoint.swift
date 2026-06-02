import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Endpoint Gemini via OAuth della Gemini CLI (Cloud Code Private API). Decisione utente
// (docs/plan/mp/DECISIONS.md §Addendum): Gemini = OAuth CLI → snapshot a LIMITI (quote giornaliere
// per-modello), NON API key. Le credenziali sono quelle che la Gemini CLI salva su disco:
//   ~/.gemini/oauth_creds.json  (access_token, refresh_token, id_token, expiry_date in ms)
//   ~/.gemini/settings.json     (security.auth.selectedType)
//
// Endpoint (verificati su CodexBar GeminiStatusProbe + studio §1.3):
//   POST https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota  (Bearer, {"project":…})
//   POST https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist     (project id + tier)
//   POST https://oauth2.googleapis.com/token                               (refresh, se scaduto)
//
// Auth type bloccati: `api-key`, `vertex-ai` (non supportati in v1; serve OAuth personale).
// Niente CLI installata / nessuna cred → `geminiNotInstalled`/`notLoggedIn` (degrada con grazia).

/// Trasporto HTTP iniettabile (per i test: niente rete). Allineato a `GeminiDataLoader`.
public typealias GeminiOAuthDataLoader = @Sendable (URLRequest) async throws -> (Data, URLResponse)

/// Tipo di auth selezionato nella Gemini CLI (`settings.json`).
public enum GeminiAuthType: String, Sendable, Equatable {
    case oauthPersonal = "oauth-personal"
    case apiKey = "api-key"
    case vertexAI = "vertex-ai"
    case unknown
}

/// Quota grezza per-modello (dopo il parsing dei buckets).
struct GeminiModelQuota: Sendable, Equatable {
    let modelId: String
    /// 0...100, % RIMANENTE (da `remainingFraction * 100`).
    let percentLeft: Double
    let resetTime: Date?
}

/// Esito del fetch OAuth: quote per-modello + identità (email/plan).
struct GeminiOAuthResult: Sendable, Equatable {
    let quotas: [GeminiModelQuota]
    let accountEmail: String?
    let accountPlan: String?
}

enum GeminiOAuthEndpoint {
    static let quotaEndpoint = URL(string: "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota")!
    static let loadCodeAssistEndpoint = URL(string: "https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist")!
    static let tokenRefreshEndpoint = URL(string: "https://oauth2.googleapis.com/token")!
    static let credentialsRelPath = "/.gemini/oauth_creds.json"
    static let settingsRelPath = "/.gemini/settings.json"
    static let timeoutSeconds: TimeInterval = 12

    static func defaultLoader(_ session: URLSession) -> GeminiOAuthDataLoader {
        { request in try await session.data(for: request) }
    }

    // MARK: - Disponibilità (no rete)

    /// true se esistono credenziali OAuth della Gemini CLI utilizzabili (auth personale/sconosciuta).
    /// Non fa rete: solo lettura file. Auth `api-key`/`vertex-ai` → non disponibile in v1.
    static func hasUsableCredentials(homeDirectory: String) -> Bool {
        switch self.currentAuthType(homeDirectory: homeDirectory) {
        case .apiKey, .vertexAI:
            return false
        case .oauthPersonal, .unknown:
            return (try? self.loadCredentials(homeDirectory: homeDirectory)) != nil
        }
    }

    /// Legge il tipo di auth da `settings.json` (`security.auth.selectedType`).
    static func currentAuthType(homeDirectory: String) -> GeminiAuthType {
        let url = URL(fileURLWithPath: homeDirectory + self.settingsRelPath)
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let security = json["security"] as? [String: Any],
              let auth = security["auth"] as? [String: Any],
              let selected = auth["selectedType"] as? String
        else {
            return .unknown
        }
        return GeminiAuthType(rawValue: selected) ?? .unknown
    }

    // MARK: - Fetch quote

    /// Recupera le quote per-modello via OAuth. Rinnova l'access token se scaduto (best-effort).
    static func fetchQuotas(
        homeDirectory: String,
        loader: GeminiOAuthDataLoader,
        now: Date = Date()) async throws -> GeminiOAuthResult
    {
        switch self.currentAuthType(homeDirectory: homeDirectory) {
        case .apiKey:
            throw ProviderError.unauthorized("Gemini è in modalità API key. In v1 serve l'accesso Google (OAuth) della Gemini CLI.")
        case .vertexAI:
            throw ProviderError.unauthorized("Gemini è in modalità Vertex AI, non supportata in v1.")
        case .oauthPersonal, .unknown:
            break
        }

        var creds = try self.loadCredentials(homeDirectory: homeDirectory)
        if self.isExpired(creds, now: now) {
            creds = try await self.refreshIfPossible(creds, homeDirectory: homeDirectory, loader: loader, now: now)
        }
        guard let accessToken = creds.accessToken, !accessToken.isEmpty else {
            throw ProviderError.unauthorized("Token Gemini scaduto. Riapri la Gemini CLI per rinnovare l'accesso.")
        }

        let claims = self.claims(fromIDToken: creds.idToken)
        let assist = await self.loadCodeAssist(accessToken: accessToken, loader: loader, now: now)

        let quotaData = try await self.requestQuota(
            accessToken: accessToken,
            projectID: assist.projectID,
            loader: loader,
            now: now)
        let quotas = try self.parseQuotas(quotaData)

        return GeminiOAuthResult(
            quotas: quotas,
            accountEmail: claims.email,
            accountPlan: self.planLabel(tier: assist.tier, hostedDomain: claims.hostedDomain))
    }

    // MARK: - HTTP

    private static func requestQuota(
        accessToken: String,
        projectID: String?,
        loader: GeminiOAuthDataLoader,
        now: Date) async throws -> Data
    {
        var request = URLRequest(url: self.quotaEndpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = self.timeoutSeconds
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let projectID {
            request.httpBody = Data(#"{"project":"\#(projectID)"}"#.utf8)
        } else {
            request.httpBody = Data("{}".utf8)
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await loader(request)
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
            throw ProviderError.rateLimited(retryAfter: self.retryAfterDate(from: http, now: now))
        default:
            throw ProviderError.serverError(code: http.statusCode, body: String(data: data, encoding: .utf8))
        }
    }

    private struct CodeAssistStatus { var tier: String?; var projectID: String? }

    /// loadCodeAssist: ricava project id e tier. Best-effort: su errore ritorna vuoto (la quota
    /// si recupera comunque con `{}`).
    private static func loadCodeAssist(
        accessToken: String,
        loader: GeminiOAuthDataLoader,
        now: Date) async -> CodeAssistStatus
    {
        var request = URLRequest(url: self.loadCodeAssistEndpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = self.timeoutSeconds
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(#"{"metadata":{"ideType":"GEMINI_CLI","pluginType":"GEMINI"}}"#.utf8)

        guard let (data, response) = try? await loader(request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return CodeAssistStatus(tier: nil, projectID: nil)
        }
        let projectID = self.extractProjectID(json)
        let tier = (json["currentTier"] as? [String: Any])?["id"] as? String
        return CodeAssistStatus(tier: tier, projectID: projectID)
    }

    private static func extractProjectID(_ json: [String: Any]) -> String? {
        if let p = json["cloudaicompanionProject"] as? String {
            let t = p.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }
        if let p = json["cloudaicompanionProject"] as? [String: Any] {
            return (p["id"] as? String) ?? (p["projectId"] as? String)
        }
        return nil
    }

    // MARK: - Parsing quote

    private struct QuotaResponse: Decodable {
        struct Bucket: Decodable {
            let remainingFraction: Double?
            let resetTime: String?
            let modelId: String?
        }
        let buckets: [Bucket]?
    }

    /// Parsa i buckets in quote per-modello. Per ogni model id tiene il bucket peggiore
    /// (frazione rimanente minima). `usedPercent = 100 - percentLeft` lo calcola il fetcher.
    static func parseQuotas(_ data: Data) throws -> [GeminiModelQuota] {
        let decoded: QuotaResponse
        do {
            decoded = try JSONDecoder().decode(QuotaResponse.self, from: data)
        } catch {
            throw ProviderError.invalidResponse
        }
        guard let buckets = decoded.buckets, !buckets.isEmpty else {
            throw ProviderError.invalidResponse
        }

        var byModel: [String: (fraction: Double, reset: String?)] = [:]
        for bucket in buckets {
            guard let modelId = bucket.modelId, let fraction = bucket.remainingFraction else { continue }
            if let existing = byModel[modelId] {
                if fraction < existing.fraction { byModel[modelId] = (fraction, bucket.resetTime) }
            } else {
                byModel[modelId] = (fraction, bucket.resetTime)
            }
        }

        return byModel
            .sorted { $0.key < $1.key }
            .map { modelId, info in
                GeminiModelQuota(
                    modelId: modelId,
                    percentLeft: min(100, max(0, info.fraction * 100)),
                    resetTime: info.reset.flatMap(Self.parseResetTime))
            }
    }

    // MARK: - Credenziali OAuth

    struct OAuthCredentials: Equatable {
        var accessToken: String?
        var idToken: String?
        var refreshToken: String?
        var expiryDate: Date?
    }

    static func loadCredentials(homeDirectory: String) throws -> OAuthCredentials {
        let url = URL(fileURLWithPath: homeDirectory + self.credentialsRelPath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ProviderError.noCredentials
        }
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw ProviderError.invalidResponse
        }
        var expiry: Date?
        if let ms = json["expiry_date"] as? Double { expiry = Date(timeIntervalSince1970: ms / 1000) }
        return OAuthCredentials(
            accessToken: json["access_token"] as? String,
            idToken: json["id_token"] as? String,
            refreshToken: json["refresh_token"] as? String,
            expiryDate: expiry)
    }

    private static func isExpired(_ creds: OAuthCredentials, now: Date) -> Bool {
        if creds.accessToken?.isEmpty != false { return true }
        if let expiry = creds.expiryDate { return expiry <= now }
        return false
    }

    /// Refresh dell'access token (best-effort). Richiede client_id/secret dell'app OAuth della CLI,
    /// che NON abbiamo: in v1 NON estraiamo i segreti dal JS della CLI (fragile/invasivo). Se serve
    /// refresh e non possiamo, lanciamo un errore azionabile ("riapri la Gemini CLI"). Hook lasciato
    /// per un'eventuale evoluzione, ma senza estrazione segreti.
    private static func refreshIfPossible(
        _ creds: OAuthCredentials,
        homeDirectory _: String,
        loader _: GeminiOAuthDataLoader,
        now _: Date) async throws -> OAuthCredentials
    {
        // v1: nessun refresh "magico". L'access token è scaduto → l'utente riapre la CLI.
        throw ProviderError.unauthorized("Token Gemini scaduto. Riapri la Gemini CLI per rinnovare l'accesso.")
    }

    // MARK: - JWT claims / plan label

    private struct TokenClaims { var email: String?; var hostedDomain: String? }

    private static func claims(fromIDToken idToken: String?) -> TokenClaims {
        guard let token = idToken else { return TokenClaims(email: nil, hostedDomain: nil) }
        let parts = token.components(separatedBy: ".")
        guard parts.count >= 2 else { return TokenClaims(email: nil, hostedDomain: nil) }
        var payload = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let pad = payload.count % 4
        if pad > 0 { payload += String(repeating: "=", count: 4 - pad) }
        guard let data = Data(base64Encoded: payload, options: .ignoreUnknownCharacters),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return TokenClaims(email: nil, hostedDomain: nil)
        }
        return TokenClaims(email: json["email"] as? String, hostedDomain: json["hd"] as? String)
    }

    /// Etichetta piano dal tier (loadCodeAssist) + hosted domain (Workspace).
    private static func planLabel(tier: String?, hostedDomain: String?) -> String? {
        switch (tier, hostedDomain) {
        case ("standard-tier", _): return "Paid"
        case ("free-tier", .some): return "Workspace"
        case ("free-tier", .none): return "Free"
        case ("legacy-tier", _): return "Legacy"
        default: return nil
        }
    }

    // MARK: - Date

    static func parseResetTime(_ iso: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withFraction.date(from: iso) { return d }
        return ISO8601DateFormatter().date(from: iso)
    }

    static func retryAfterDate(from response: HTTPURLResponse, now: Date) -> Date? {
        guard let raw = response.value(forHTTPHeaderField: "Retry-After")?
            .trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty
        else { return nil }
        if let seconds = TimeInterval(raw), seconds >= 0 { return now.addingTimeInterval(seconds) }
        return nil
    }
}

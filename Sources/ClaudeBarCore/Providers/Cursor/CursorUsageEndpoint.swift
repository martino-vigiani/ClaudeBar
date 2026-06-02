import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Endpoint Cursor (web API non documentata, base https://cursor.com) per il provider `.cursor`.
// Shape e percorsi verificati sull'upstream CodexBar (CursorStatusProbe) e dallo studio in
// docs/plan/mp/prov-gemini-cursor.md §2.
//
//   GET /api/usage-summary  → CursorUsageSummary (percentuali del ciclo + on-demand in CENTESIMI)
//   GET /api/auth/me        → email/name (best-effort, per l'identità)
//
// AUTH: Cursor NON ha API key né OAuth pubblico. L'unica auth reale è il COOKIE di sessione del
// browser (cursor.com). Per rispettare il vincolo "zero dipendenze" + "segreti in Keychain" non
// leggiamo i cookie dal browser (come fa CodexBar con SweetCookieKit): l'utente incolla il proprio
// cookie header dalle DevTools e lo salviamo in Keychain. Il cookie header va nell'header `Cookie:`.
//
// 401/403 → `ProviderError.unauthorized` (terminale: cookie scaduto/assente). 429 → rateLimited.

/// Trasporto HTTP iniettabile (per i test: niente rete).
public typealias CursorDataLoader = @Sendable (URLRequest) async throws -> (Data, URLResponse)

// MARK: - Modelli risposta (sottoinsieme di CodexBar, solo i campi usati)

/// `/api/usage-summary`. I valori monetari sono in CENTESIMI (es. 2000 = $20.00).
struct CursorUsageSummary: Decodable, Sendable {
    let billingCycleEnd: String?
    let membershipType: String?
    let individualUsage: IndividualUsage?
    let teamUsage: TeamUsage?

    struct IndividualUsage: Decodable, Sendable {
        let plan: PlanUsage?
        let onDemand: AmountUsage?
        /// Cap personale per membri team/enterprise (cents).
        let overall: AmountUsage?
    }

    struct PlanUsage: Decodable, Sendable {
        /// Cents.
        let used: Int?
        let limit: Int?
        let autoPercentUsed: Double?
        let apiPercentUsed: Double?
        let totalPercentUsed: Double?
    }

    /// Blocco generico used/limit (cents). Usato da onDemand/overall/pooled.
    struct AmountUsage: Decodable, Sendable {
        let used: Int?
        let limit: Int?
    }

    struct TeamUsage: Decodable, Sendable {
        let onDemand: AmountUsage?
        /// Pool condiviso team/enterprise (cents).
        let pooled: AmountUsage?
    }
}

/// `/api/auth/me`.
struct CursorUserInfo: Decodable, Sendable {
    let email: String?
    let name: String?
}

enum CursorUsageEndpoint {
    static let baseURL = URL(string: "https://cursor.com")!
    static let timeoutSeconds: TimeInterval = 15

    static func defaultLoader(_ session: URLSession) -> CursorDataLoader {
        { request in try await session.data(for: request) }
    }

    /// Scarica il riepilogo usage del piano. `cookieHeader` è il valore raw dell'header `Cookie`.
    static func fetchUsageSummary(
        cookieHeader: String,
        baseURL: URL = baseURL,
        loader: CursorDataLoader,
        now: Date = Date()) async throws -> CursorUsageSummary
    {
        let url = baseURL.appendingPathComponent("/api/usage-summary")
        let data = try await self.fetchData(url: url, cookieHeader: cookieHeader, loader: loader, now: now)
        do {
            return try JSONDecoder().decode(CursorUsageSummary.self, from: data)
        } catch {
            throw ProviderError.invalidResponse
        }
    }

    /// Identità account (best-effort: l'identità non deve far fallire il fetch principale).
    static func fetchUserInfo(
        cookieHeader: String,
        baseURL: URL = baseURL,
        loader: CursorDataLoader,
        now: Date = Date()) async throws -> CursorUserInfo
    {
        let url = baseURL.appendingPathComponent("/api/auth/me")
        let data = try await self.fetchData(url: url, cookieHeader: cookieHeader, loader: loader, now: now)
        do {
            return try JSONDecoder().decode(CursorUserInfo.self, from: data)
        } catch {
            throw ProviderError.invalidResponse
        }
    }

    private static func fetchData(
        url: URL,
        cookieHeader: String,
        loader: CursorDataLoader,
        now: Date) async throws -> Data
    {
        let trimmedCookie = cookieHeader.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCookie.isEmpty else { throw ProviderError.noCredentials }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = self.timeoutSeconds
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(trimmedCookie, forHTTPHeaderField: "Cookie")

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
            throw ProviderError.rateLimited(retryAfter: Self.retryAfterDate(from: http, now: now))
        default:
            throw ProviderError.serverError(code: http.statusCode, body: String(data: data, encoding: .utf8))
        }
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

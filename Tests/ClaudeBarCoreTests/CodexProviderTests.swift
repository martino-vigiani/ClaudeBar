import Foundation
import Testing
@testable import ClaudeBarCore

// Test del provider Codex (#12): parse auth.json, decode difensivo dell'usage, risoluzione URL,
// mapping snapshot, claims JWT, refresh error, e la strategia OAuth end-to-end con rete mockata.
// Tutto deterministico e offline (URLProtocol mock per la rete).

// MARK: - Parse auth.json

@Suite("Codex — parse auth.json")
struct CodexCredentialsParseTests {
    @Test("tokens in snake_case")
    func snakeCase() throws {
        let json = """
        { "tokens": { "access_token": "AT", "refresh_token": "RT", "id_token": "ID", "account_id": "ACC" },
          "last_refresh": "2026-05-01T10:00:00Z" }
        """
        let creds = try CodexOAuthCredentialsStore.parse(data: Data(json.utf8))
        #expect(creds.accessToken == "AT")
        #expect(creds.refreshToken == "RT")
        #expect(creds.idToken == "ID")
        #expect(creds.accountId == "ACC")
        #expect(creds.lastRefresh != nil)
    }

    @Test("tokens in camelCase")
    func camelCase() throws {
        let json = """
        { "tokens": { "accessToken": "AT2", "refreshToken": "RT2" } }
        """
        let creds = try CodexOAuthCredentialsStore.parse(data: Data(json.utf8))
        #expect(creds.accessToken == "AT2")
        #expect(creds.refreshToken == "RT2")
        #expect(creds.idToken == nil)
    }

    @Test("API key mode: OPENAI_API_KEY come accessToken, niente refresh")
    func apiKeyMode() throws {
        let json = #"{ "OPENAI_API_KEY": "sk-abc" }"#
        let creds = try CodexOAuthCredentialsStore.parse(data: Data(json.utf8))
        #expect(creds.accessToken == "sk-abc")
        #expect(creds.refreshToken.isEmpty)
    }

    @Test("last_refresh con frazioni di secondo")
    func lastRefreshFractional() throws {
        let json = """
        { "tokens": { "access_token": "AT" }, "last_refresh": "2026-05-01T10:00:00.123Z" }
        """
        let creds = try CodexOAuthCredentialsStore.parse(data: Data(json.utf8))
        #expect(creds.lastRefresh != nil)
    }

    @Test("JSON senza tokens → missingTokens")
    func missingTokens() {
        let json = #"{ "last_refresh": "2026-05-01T10:00:00Z" }"#
        #expect(throws: CodexOAuthCredentialsError.missingTokens) {
            try CodexOAuthCredentialsStore.parse(data: Data(json.utf8))
        }
    }

    @Test("JSON non valido → decodeFailed")
    func decodeFailed() {
        #expect(throws: CodexOAuthCredentialsError.decodeFailed) {
            try CodexOAuthCredentialsStore.parse(data: Data("non-json".utf8))
        }
    }

    @Test("needsRefresh: nil last_refresh → true; recente → false; oltre 8 giorni → true")
    func needsRefresh() {
        let never = CodexOAuthCredentials(
            accessToken: "AT", refreshToken: "RT", idToken: nil, accountId: nil, lastRefresh: nil)
        #expect(never.needsRefresh)

        let fresh = CodexOAuthCredentials(
            accessToken: "AT", refreshToken: "RT", idToken: nil, accountId: nil,
            lastRefresh: Date().addingTimeInterval(-60))
        #expect(!fresh.needsRefresh)

        let old = CodexOAuthCredentials(
            accessToken: "AT", refreshToken: "RT", idToken: nil, accountId: nil,
            lastRefresh: Date().addingTimeInterval(-9 * 24 * 60 * 60))
        #expect(old.needsRefresh)
    }
}

// MARK: - Decode usage response (difensivo)

@Suite("Codex — decode CodexUsageResponse")
struct CodexUsageDecodeTests {
    private func decode(_ json: String) throws -> CodexUsageResponse {
        try JSONDecoder().decode(CodexUsageResponse.self, from: Data(json.utf8))
    }

    @Test("primary + secondary window + plan + credits")
    func full() throws {
        let json = """
        {
          "plan_type": "pro",
          "rate_limit": {
            "primary_window":   { "used_percent": 42, "reset_at": 1717250000, "limit_window_seconds": 18000 },
            "secondary_window": { "used_percent": 71, "reset_at": 1717700000, "limit_window_seconds": 604800 }
          },
          "credits": { "has_credits": true, "unlimited": false, "balance": 12.5 }
        }
        """
        let response = try decode(json)
        #expect(response.planType == "pro")
        #expect(response.rateLimit?.primaryWindow?.usedPercent == 42)
        #expect(response.rateLimit?.primaryWindow?.limitWindowSeconds == 18000)
        #expect(response.rateLimit?.secondaryWindow?.usedPercent == 71)
        #expect(response.credits?.balance == 12.5)
    }

    @Test("additional_rate_limits con una entry malformata: le valide sopravvivono")
    func lossyAdditional() throws {
        let json = """
        {
          "rate_limit": { "primary_window": { "used_percent": 10, "reset_at": 1, "limit_window_seconds": 18000 } },
          "additional_rate_limits": [
            { "limit_name": "Codex Spark", "rate_limit": { "primary_window": { "used_percent": 5, "reset_at": 2, "limit_window_seconds": 18000 } } },
            12345
          ]
        }
        """
        let response = try decode(json)
        #expect(response.additionalRateLimits.count == 1)
        #expect(response.additionalRateLimits.first?.limitName == "Codex Spark")
    }

    @Test("balance come stringa numerica")
    func balanceString() throws {
        let json = #"{ "credits": { "balance": "7.25" } }"#
        let response = try decode(json)
        #expect(response.credits?.balance == 7.25)
    }

    @Test("rate_limit assente → niente finestre, nessun crash")
    func emptyRateLimit() throws {
        let response = try decode("{}")
        #expect(response.rateLimit == nil)
        #expect(response.additionalRateLimits.isEmpty)
    }
}

// MARK: - Risoluzione URL usage

@Suite("Codex — risoluzione URL usage")
struct CodexUsageURLTests {
    @Test("base default → chatgpt.com/backend-api/wham/usage")
    func defaultURL() {
        let url = CodexUsageEndpoint.resolveUsageURL(env: [:], configContents: nil)
        #expect(url.absoluteString == "https://chatgpt.com/backend-api/wham/usage")
    }

    @Test("override chatgpt_base_url self-host → /api/codex/usage")
    func selfHostURL() {
        let config = #"chatgpt_base_url = "https://codex.internal.example.com""#
        let url = CodexUsageEndpoint.resolveUsageURL(env: [:], configContents: config)
        #expect(url.absoluteString == "https://codex.internal.example.com/api/codex/usage")
    }

    @Test("override chatgpt.com senza /backend-api → normalizzato a wham/usage")
    func normalizedChatGPT() {
        let config = #"chatgpt_base_url = "https://chatgpt.com""#
        let url = CodexUsageEndpoint.resolveUsageURL(env: [:], configContents: config)
        #expect(url.absoluteString == "https://chatgpt.com/backend-api/wham/usage")
    }

    @Test("parseBaseURL ignora i commenti e gli apici")
    func parseIgnoresComments() throws {
        let config = """
        # commento
        chatgpt_base_url = "https://example.com"  # inline
        """
        let parsed = try #require(CodexUsageEndpoint.parseBaseURL(from: config))
        #expect(parsed == "https://example.com")
    }
}

// MARK: - Mapping snapshot

@Suite("Codex — mapping CodexUsageResponse → ProviderSnapshot")
struct CodexSnapshotMapperTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let emptyCreds = CodexOAuthCredentials(
        accessToken: "AT", refreshToken: "RT", idToken: nil, accountId: nil, lastRefresh: nil)

    private func window(_ used: Double, _ windowSeconds: Int, reset: Int = 1_700_010_000) -> CodexUsageResponse.Window {
        CodexUsageResponse.Window(usedPercent: used, resetAt: reset, limitWindowSeconds: windowSeconds)
    }

    @Test("primary→sessione (.fiveHour), secondary→settimana (.sevenDay)")
    func mapsWindows() {
        let response = CodexUsageResponse(
            planType: "pro",
            rateLimit: .init(primaryWindow: window(40, 18000), secondaryWindow: window(80, 604800)),
            credits: nil)
        let snapshot = CodexSnapshotMapper.makeSnapshot(
            from: response, credentials: emptyCreds, accountLabel: nil, now: now)

        #expect(snapshot.providerID == .codex)
        #expect(snapshot.window(.fiveHour)?.utilization == 40)
        #expect(snapshot.window(.sevenDay)?.utilization == 80)
        #expect(snapshot.cost == nil)
    }

    @Test("finestre invertite vengono riallineate dalla durata")
    func normalizesInverted() {
        // primary ha durata settimanale, secondary durata sessione → vanno scambiate.
        let response = CodexUsageResponse(
            planType: nil,
            rateLimit: .init(primaryWindow: window(80, 604800), secondaryWindow: window(40, 18000)),
            credits: nil)
        let snapshot = CodexSnapshotMapper.makeSnapshot(
            from: response, credentials: emptyCreds, accountLabel: nil, now: now)
        #expect(snapshot.window(.fiveHour)?.utilization == 40)
        #expect(snapshot.window(.sevenDay)?.utilization == 80)
    }

    @Test("utilization clampato 0...100")
    func clampsUtilization() {
        let response = CodexUsageResponse(
            planType: nil,
            rateLimit: .init(primaryWindow: window(150, 18000), secondaryWindow: nil),
            credits: nil)
        let snapshot = CodexSnapshotMapper.makeSnapshot(
            from: response, credentials: emptyCreds, accountLabel: nil, now: now)
        #expect(snapshot.window(.fiveHour)?.utilization == 100)
    }

    @Test("reset_at epoch → resetsAt; pace presente quando il reset è noto")
    func mapsResetAndPace() {
        let response = CodexUsageResponse(
            planType: nil,
            rateLimit: .init(primaryWindow: window(50, 18000, reset: 1_700_010_000), secondaryWindow: nil),
            credits: nil)
        let snapshot = CodexSnapshotMapper.makeSnapshot(
            from: response, credentials: emptyCreds, accountLabel: nil, now: now)
        let session = snapshot.window(.fiveHour)
        #expect(session?.resetsAt == Date(timeIntervalSince1970: 1_700_010_000))
        #expect(session?.pace != nil)
    }

    @Test("credits.balance → ProviderCredits; assente → nil")
    func mapsCredits() {
        let withBalance = CodexUsageResponse(
            planType: nil, rateLimit: nil,
            credits: .init(hasCredits: true, unlimited: false, balance: 9.0))
        let snapshot = CodexSnapshotMapper.makeSnapshot(
            from: withBalance, credentials: emptyCreds, accountLabel: nil, now: now)
        #expect(snapshot.credits?.remaining == 9.0)

        let noBalance = CodexUsageResponse(
            planType: nil, rateLimit: nil,
            credits: .init(hasCredits: false, unlimited: false, balance: nil))
        let snapshot2 = CodexSnapshotMapper.makeSnapshot(
            from: noBalance, credentials: emptyCreds, accountLabel: nil, now: now)
        #expect(snapshot2.credits == nil)
    }

    @Test("additional_rate_limits (Spark) finiscono nelle corsie per-modello settimanali")
    func mapsAdditionalLimits() {
        let extra = CodexUsageResponse.AdditionalRateLimit(
            limitName: "Codex Spark",
            meteredFeature: nil,
            rateLimit: .init(primaryWindow: window(33, 18000), secondaryWindow: nil))
        let response = CodexUsageResponse(
            planType: nil,
            rateLimit: .init(primaryWindow: window(10, 18000), secondaryWindow: window(20, 604800)),
            credits: nil,
            additionalRateLimits: [extra])
        let snapshot = CodexSnapshotMapper.makeSnapshot(
            from: response, credentials: emptyCreds, accountLabel: nil, now: now)
        // 2 principali + 1 extra sulla prima corsia per-modello libera.
        #expect(snapshot.windows.count == 3)
        #expect(snapshot.window(.sevenDayOpus)?.utilization == 33)
    }

    @Test("plan_type valorizza identity.plan")
    func mapsPlan() {
        let response = CodexUsageResponse(
            planType: "team",
            rateLimit: .init(primaryWindow: window(1, 18000), secondaryWindow: nil),
            credits: nil)
        let snapshot = CodexSnapshotMapper.makeSnapshot(
            from: response, credentials: emptyCreds, accountLabel: nil, now: now)
        #expect(snapshot.identity.plan == "team")
    }
}

// MARK: - JWT claims

@Suite("Codex — decode claims JWT")
struct CodexJWTTests {
    /// Costruisce un JWT fittizio con il payload indicato (header e firma fasulli, non verificati).
    private func makeJWT(payload: [String: Any]) -> String {
        func b64url(_ data: Data) -> String {
            data.base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        let header = b64url(Data(#"{"alg":"none"}"#.utf8))
        let body = b64url(try! JSONSerialization.data(withJSONObject: payload))
        return "\(header).\(body).sig"
    }

    @Test("estrae email e plan dai claims OpenAI")
    func extractsClaims() throws {
        let jwt = makeJWT(payload: [
            "email": "user@example.com",
            "https://api.openai.com/auth": ["chatgpt_plan_type": "pro"],
        ])
        let claims = try #require(CodexSnapshotMapper.decodeJWTClaims(jwt))
        #expect(claims["email"] as? String == "user@example.com")

        let creds = CodexOAuthCredentials(
            accessToken: "AT", refreshToken: "RT", idToken: jwt, accountId: nil, lastRefresh: nil)
        let response = CodexUsageResponse(planType: nil, rateLimit: nil, credits: nil)
        let identity = CodexSnapshotMapper.identity(from: response, credentials: creds, accountLabel: nil)
        #expect(identity.email == "user@example.com")
        // plan_type assente nella risposta → fallback sul JWT.
        #expect(identity.plan == "pro")
    }

    @Test("JWT malformato → nil senza crash")
    func malformedJWT() {
        #expect(CodexSnapshotMapper.decodeJWTClaims("not-a-jwt") == nil)
    }
}

// MARK: - Refresh error mapping

@Suite("Codex — refresh error", .tags(.networking))
struct CodexRefreshTests {
    @Test("refresh senza refresh token → unauthorized")
    func noRefreshToken() async {
        let creds = CodexOAuthCredentials(
            accessToken: "AT", refreshToken: "", idToken: nil, accountId: nil, lastRefresh: nil)
        await #expect(throws: ProviderError.self) {
            _ = try await CodexTokenRefresher.refresh(creds, session: .shared)
        }
    }

    @Test("errorMessage estrae il codice OAuth dal body")
    func errorMessage() {
        let body = Data(#"{ "error": { "code": "refresh_token_expired" } }"#.utf8)
        #expect(CodexTokenRefresher.errorMessage(from: body) == "Codex refresh: refresh_token_expired")
    }
}

// MARK: - Strategia OAuth end-to-end (rete mockata)

// `.serialized`: i test di rete condividono lo stato statico del `MockURLProtocol` (handler),
// quindi NON devono girare in parallelo tra loro o si sovrascriverebbero la risposta a vicenda.
@Suite("Codex — strategia OAuth (rete mockata)", .tags(.networking), .serialized)
struct CodexOAuthStrategyTests {
    private func makeSession(handler: @escaping @Sendable (URLRequest) -> (Int, Data)) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        MockURLProtocol.handler = handler
        return URLSession(configuration: config)
    }

    @Test("env token + usage 200 → snapshot con finestre")
    func envTokenHappyPath() async throws {
        let usageJSON = """
        { "plan_type": "pro", "rate_limit": {
            "primary_window": { "used_percent": 55, "reset_at": 1717250000, "limit_window_seconds": 18000 },
            "secondary_window": { "used_percent": 30, "reset_at": 1717700000, "limit_window_seconds": 604800 } } }
        """
        let session = makeSession { _ in (200, Data(usageJSON.utf8)) }
        let provider = CodexProvider(session: session)
        let context = ProviderFetchContext(
            userInitiated: false,
            environment: [CodexProvider.tokenEnvironmentKey: "test-token"])

        let snapshot = try await provider.snapshot(context: context)
        #expect(snapshot.providerID == .codex)
        #expect(snapshot.window(.fiveHour)?.utilization == 55)
        #expect(snapshot.window(.sevenDay)?.utilization == 30)
    }

    @Test("usage 401 con env token (no refresh token) → unauthorized")
    func unauthorizedEnvToken() async {
        let session = makeSession { _ in (401, Data("nope".utf8)) }
        let provider = CodexProvider(session: session)
        let context = ProviderFetchContext(
            userInitiated: false,
            environment: [CodexProvider.tokenEnvironmentKey: "test-token"])

        await #expect(throws: ProviderError.self) {
            _ = try await provider.snapshot(context: context)
        }
    }

    @Test("nessuna credenziale (env vuoto, no auth.json) → noAvailableStrategy")
    func noCredentials() async {
        let session = makeSession { _ in (200, Data("{}".utf8)) }
        // CODEX_HOME inesistente per garantire l'assenza di auth.json reale.
        let provider = CodexProvider(session: session)
        let context = ProviderFetchContext(
            userInitiated: false,
            environment: ["CODEX_HOME": "/nonexistent-\(UUID().uuidString)"])

        await #expect(throws: ProviderError.noAvailableStrategy(.codex)) {
            _ = try await provider.snapshot(context: context)
        }
    }

    @Test("descriptor: codex, primario, oauth+apiKey, v1 = limiti+credits (no costo)")
    func descriptor() {
        let descriptor = CodexProvider().descriptor
        #expect(descriptor.id == .codex)
        #expect(descriptor.isPrimaryCandidate)
        #expect(descriptor.capabilities.hasUsageLimits)
        // v1: il costo a consumo è il provider .openaiAPI → Codex NON espone costo (no sezione vuota).
        #expect(!descriptor.capabilities.hasCostUsage)
        #expect(descriptor.capabilities.hasCredits)
        #expect(descriptor.authKinds.contains(.oauthManaged))
    }
}

// MARK: - Mock URLProtocol

/// Intercetta le richieste HTTP a livello di URLSession per i test, senza rete reale.
final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) -> (Int, Data))?

    override class func canInit(with _: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            self.client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let (status, data) = handler(self.request)
        let response = HTTPURLResponse(
            url: self.request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"])!
        self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        self.client?.urlProtocol(self, didLoad: data)
        self.client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

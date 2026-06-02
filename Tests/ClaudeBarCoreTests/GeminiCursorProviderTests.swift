import Foundation
import Testing
@testable import ClaudeBarCore

// Test dei provider Gemini e Cursor (#13/#17). Nessun I/O di rete: loader iniettabile che risponde
// con fixture JSON + status code, o funzioni di mapping PURE. Gemini = OAuth della Gemini CLI →
// limiti (home temporanea con oauth_creds.json/settings.json finti). Cursor = cookie → limiti
// (cookie header finto in Keychain in memoria). Si verificano: parsing, mapping al modello
// unificato, headline/precedenza, gestione errori (401/429/no-cred), auto-detect senza rete.

// MARK: - Loader fittizio

/// Costruisce un loader che ritorna sempre lo stesso (status, body) ignorando la request.
private func fixedLoader(status: Int, body: String) -> @Sendable (URLRequest) async throws -> (Data, URLResponse) {
    { request in
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "https://example.com")!,
            statusCode: status,
            httpVersion: nil,
            headerFields: nil)!
        return (Data(body.utf8), response)
    }
}

/// Loader che instrada la risposta in base al path della URL (per simulare più endpoint Cursor).
private func routedLoader(_ routes: [String: (status: Int, body: String)])
    -> @Sendable (URLRequest) async throws -> (Data, URLResponse)
{
    { request in
        let path = request.url?.path ?? ""
        let route = routes[path] ?? (status: 404, body: "{}")
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: route.status,
            httpVersion: nil,
            headerFields: nil)!
        return (Data(route.body.utf8), response)
    }
}

private let ctx = ProviderFetchContext(
    userInitiated: true,
    environment: [:],
    now: { Date(timeIntervalSince1970: 1_000_000) })

/// Esegue `body` e ritorna il `ProviderError` lanciato (o `nil` se non lancia / lancia altro).
private func capturedProviderError(
    _ body: () async throws -> ProviderSnapshot) async -> ProviderError?
{
    do {
        _ = try await body()
        return nil
    } catch let error as ProviderError {
        return error
    } catch {
        return nil
    }
}

// MARK: - Gemini (OAuth della Gemini CLI → limiti)

/// Crea una home temporanea con `~/.gemini/oauth_creds.json` (+ opzionale `settings.json`).
/// Ritorna il path della home; pulizia a carico del chiamante (è in /tmp, non critica).
private func makeGeminiHome(
    authType: String? = nil,
    accessToken: String? = "ya29.valid",
    expiryDate: Date? = Date(timeIntervalSince1970: 9_999_999_999), // lontano nel futuro (non scaduto)
    refreshToken: String? = "1//refresh",
    idToken: String? = nil) -> String
{
    let fm = FileManager.default
    let home = fm.temporaryDirectory.appendingPathComponent("clbar-gemini-\(UUID().uuidString)", isDirectory: true)
    let geminiDir = home.appendingPathComponent(".gemini", isDirectory: true)
    try? fm.createDirectory(at: geminiDir, withIntermediateDirectories: true)

    var creds: [String: Any] = [:]
    if let accessToken { creds["access_token"] = accessToken }
    if let refreshToken { creds["refresh_token"] = refreshToken }
    if let idToken { creds["id_token"] = idToken }
    if let expiryDate {
        creds["expiry_date"] = expiryDate.timeIntervalSince1970 * 1000
    }
    let credsData = try! JSONSerialization.data(withJSONObject: creds)
    try! credsData.write(to: geminiDir.appendingPathComponent("oauth_creds.json"))

    if let authType {
        let settings: [String: Any] = ["security": ["auth": ["selectedType": authType]]]
        let settingsData = try! JSONSerialization.data(withJSONObject: settings)
        try! settingsData.write(to: geminiDir.appendingPathComponent("settings.json"))
    }
    return home.path
}

/// Body di `:retrieveUserQuota` con buckets per-modello (remainingFraction ∈ [0,1]).
private func geminiQuotaBody(_ models: [(id: String, remaining: Double)]) -> String {
    let buckets = models.map { #"{"modelId":"\#($0.id)","remainingFraction":\#($0.remaining)}"# }
    return #"{"buckets":[\#(buckets.joined(separator: ","))]}"#
}

@Suite("Provider — Gemini (OAuth CLI → limiti)")
struct GeminiProviderTests {
    private static let quotaPath = "/v1internal:retrieveUserQuota"
    private static let assistPath = "/v1internal:loadCodeAssist"

    @Test("Descriptor: limiti, OAuth managed, id .gemini")
    func descriptor() {
        let provider = GeminiProvider(homeDirectory: "/nope", loader: fixedLoader(status: 200, body: "{}"))
        let d = provider.descriptor
        #expect(d.id == .gemini)
        #expect(d.capabilities.hasUsageLimits)
        #expect(!d.capabilities.hasCostUsage)
        #expect(d.authKinds == [.oauthManaged])
    }

    @Test("Senza credenziali CLI: detectAvailability unavailable e fetch lancia errore terminale")
    func noCredentials() async throws {
        // Home inesistente → nessun oauth_creds.json.
        let provider = GeminiProvider(homeDirectory: "/var/empty/clbar-nope", loader: fixedLoader(status: 200, body: "{}"))
        #expect(await provider.detectAvailability(ctx) == .unavailable)
        let error = await capturedProviderError { try await provider.snapshot(context: ctx) }
        let providerError = try #require(error)
        #expect(providerError.isTerminal)
        #expect(providerError == .noCredentials || providerError == .noAvailableStrategy(.gemini))
    }

    @Test("Auth api-key/vertex-ai: provider non disponibile (in v1 serve OAuth personale)")
    func unsupportedAuthTypeUnavailable() async {
        let home = makeGeminiHome(authType: "api-key")
        let provider = GeminiProvider(homeDirectory: home, loader: fixedLoader(status: 200, body: "{}"))
        #expect(await provider.detectAvailability(ctx) == .unavailable)
    }

    @Test("Quote per-modello → finestre Pro/Flash/Flash-Lite (utilization = 100 - remaining)")
    func quotaMappingToWindows() async throws {
        let home = makeGeminiHome(authType: "oauth-personal")
        let quota = geminiQuotaBody([
            ("gemini-2.5-pro", 0.20),         // 80% usato
            ("gemini-2.5-flash", 0.90),       // 10% usato
            ("gemini-2.5-flash-lite", 0.55),  // 45% usato
        ])
        let loader = routedLoader([
            Self.quotaPath: (200, quota),
            Self.assistPath: (200, #"{"currentTier":{"id":"standard-tier"}}"#),
        ])
        let provider = GeminiProvider(homeDirectory: home, loader: loader)

        #expect(await provider.detectAvailability(ctx).detectedAuth == .oauthManaged)

        let snapshot = try await provider.snapshot(context: ctx)
        #expect(snapshot.providerID == .gemini)
        #expect(snapshot.hasLimits)
        #expect(snapshot.cost == nil)
        // 3 finestre con label descrittive + durata giornaliera (customDurationMinutes 1440).
        #expect(snapshot.windows.count == 3)
        #expect(snapshot.windows.map(\.label) == ["Pro", "Flash", "Flash Lite"])
        let allDaily = snapshot.windows.allSatisfy { $0.customDurationMinutes == 1440 }
        #expect(allDaily)
        #expect(snapshot.windows.first?.effectiveDuration == TimeInterval(1440 * 60))
        #expect(snapshot.windows.first { $0.label == "Pro" }?.utilization == 80)
        #expect(snapshot.windows.first { $0.label == "Flash" }?.utilization == 10)
        let lite = try #require(snapshot.windows.first { $0.label == "Flash Lite" }?.utilization)
        #expect(abs(lite - 45) < 0.001)
        #expect(snapshot.mostCriticalWindow?.utilization == 80)   // Pro 80% è la più critica
        #expect(snapshot.identity.plan == "Paid")
    }

    @Test("Tiene la quota peggiore per-modello e ignora i modelli sconosciuti")
    func worstQuotaPerModel() throws {
        let data = Data(geminiQuotaBody([
            ("gemini-2.5-pro", 0.60),
            ("gemini-2.5-pro", 0.30),   // peggiore → vince
            ("text-embedding", 0.05),   // non Pro/Flash/Flash-Lite → ignorato dalle finestre
        ]).utf8)
        let quotas = try GeminiOAuthEndpoint.parseQuotas(data)
        let windows = GeminiUsageFetcher.makeWindows(quotas: quotas)
        // Solo Pro mappa su una finestra; usa la frazione peggiore (0.30 → 70% usato).
        #expect(windows.count == 1)
        #expect(windows.first?.utilization == 70)
    }

    @Test("retrieveUserQuota 401 → unauthorized (terminale)")
    func quota401Unauthorized() async throws {
        let home = makeGeminiHome(authType: "oauth-personal")
        let loader = routedLoader([
            Self.quotaPath: (401, "{}"),
            Self.assistPath: (200, "{}"),
        ])
        let provider = GeminiProvider(homeDirectory: home, loader: loader)
        let error = await capturedProviderError { try await provider.snapshot(context: ctx) }
        #expect(error?.isTerminal == true)
    }

    @Test("Access token scaduto senza refresh → unauthorized azionabile")
    func expiredTokenUnauthorized() async throws {
        // expiry (500_000) < ctx.now (1_000_000) → scaduto. In v1 non rinnoviamo → terminale.
        let home = makeGeminiHome(authType: "oauth-personal", expiryDate: Date(timeIntervalSince1970: 500_000))
        let loader = routedLoader([Self.quotaPath: (200, "{}"), Self.assistPath: (200, "{}")])
        let provider = GeminiProvider(homeDirectory: home, loader: loader)
        let error = await capturedProviderError { try await provider.snapshot(context: ctx) }
        if case .unauthorized = error { } else { Issue.record("atteso .unauthorized, ottenuto \(String(describing: error))") }
    }
}

// MARK: - Cursor

@Suite("Provider — Cursor (cookie → limiti del piano)")
struct CursorProviderTests {
    private static let usageSummaryPath = "/api/usage-summary"
    private static let authMePath = "/api/auth/me"

    @Test("Descriptor: limiti + credits, auth browserCookie, id .cursor")
    func descriptor() {
        let provider = CursorProvider(secretStore: InMemorySecretStore(), loader: fixedLoader(status: 200, body: "{}"))
        let d = provider.descriptor
        #expect(d.id == .cursor)
        #expect(d.capabilities.hasUsageLimits)
        #expect(d.capabilities.hasCredits)
        #expect(!d.capabilities.hasCostUsage)
        #expect(d.authKinds == [.browserCookie])
    }

    @Test("Senza cookie: detectAvailability unavailable e fetch lancia un errore terminale")
    func noCredentials() async throws {
        let provider = CursorProvider(secretStore: InMemorySecretStore(), loader: fixedLoader(status: 200, body: "{}"))
        #expect(await provider.detectAvailability(ctx) == .unavailable)
        // Senza cookie lo snapshot fallisce con un errore TERMINALE (la UI mostra "configura").
        let error = await capturedProviderError { try await provider.snapshot(context: ctx) }
        let providerError = try #require(error)
        #expect(providerError.isTerminal)
        #expect(providerError == .noCredentials || providerError == .noAvailableStrategy(.cursor))
    }

    @Test("Piano Pro: Total da totalPercentUsed, lane Auto/API, on-demand → credits USD")
    func proPlanMapping() async throws {
        let store = InMemorySecretStore()
        try store.setSecret("WorkosCursorSessionToken=abc", provider: .cursor, account: "default")
        let summary = """
        {
          "billingCycleEnd": "2026-07-01T00:00:00Z",
          "membershipType": "pro",
          "individualUsage": {
            "plan": { "used": 1500, "limit": 2000, "autoPercentUsed": 60, "apiPercentUsed": 30, "totalPercentUsed": 48 },
            "onDemand": { "used": 250, "limit": 1000 }
          }
        }
        """
        let loader = routedLoader([
            Self.usageSummaryPath: (200, summary),
            Self.authMePath: (200, #"{"email":"u@x.com","name":"Tester"}"#),
        ])
        let provider = CursorProvider(secretStore: store, loader: loader)

        let availability = await provider.detectAvailability(ctx)
        #expect(availability.isAvailable)
        #expect(availability.detectedAuth == .browserCookie)

        let snapshot = try await provider.snapshot(context: ctx)
        #expect(snapshot.providerID == .cursor)
        #expect(snapshot.hasLimits)
        // 3 finestre con label Total/Auto/API + durata ciclo mensile (43200 min).
        #expect(snapshot.windows.count == 3)
        #expect(snapshot.windows.map(\.label) == ["Total", "Auto", "API"])
        let allMonthly = snapshot.windows.allSatisfy { $0.customDurationMinutes == 30 * 24 * 60 }
        #expect(allMonthly)
        let total = snapshot.window(.sevenDay)
        #expect(total?.utilization == 48)
        #expect(snapshot.window(.fiveHour)?.utilization == 60)
        #expect(snapshot.window(.sevenDayOpus)?.utilization == 30)
        // mostCritical = Auto (60% usato) > Total (48) > API (30)
        #expect(snapshot.mostCriticalWindow?.utilization == 60)
        // resetsAt = billingCycleEnd
        #expect(total?.resetsAt != nil)
        // on-demand: used 250c, limit 1000c → remaining $7.50, total $10
        #expect(snapshot.credits?.total == 10.0)
        #expect(snapshot.credits?.remaining == 7.5)
        #expect(snapshot.credits?.currency == "USD")
        // identità
        #expect(snapshot.identity.email == "u@x.com")
        #expect(snapshot.identity.label == "Tester")
        #expect(snapshot.identity.plan == "Cursor Pro")
    }

    @Test("Headline: senza totalPercentUsed usa la media di auto+api")
    func headlineAverage() {
        let summary = CursorUsageSummaryFixture.make(autoPercent: 40, apiPercent: 80, totalPercent: nil)
        let snap = CursorUsageFetcher.makeSnapshot(summary: summary, userInfo: nil, now: Date(timeIntervalSince1970: 1))
        // media (40+80)/2 = 60
        #expect(snap.window(.sevenDay)?.utilization == 60)
    }

    @Test("Headline: fallback su ratio plan.used/limit quando mancano i percent")
    func headlineRatioFallback() {
        let summary = CursorUsageSummaryFixture.make(used: 750, limit: 1000)
        let snap = CursorUsageFetcher.makeSnapshot(summary: summary, userInfo: nil, now: Date(timeIntervalSince1970: 1))
        #expect(snap.window(.sevenDay)?.utilization == 75)
        // niente lane → solo la finestra Total
        #expect(snap.windows.count == 1)
    }

    @Test("Percent < 1.0 resta in unità % (0.36 = 0.36%, non 36%)")
    func subUnitPercent() {
        let summary = CursorUsageSummaryFixture.make(autoPercent: 0.36, apiPercent: nil, totalPercent: 0.36)
        let snap = CursorUsageFetcher.makeSnapshot(summary: summary, userInfo: nil, now: Date(timeIntervalSince1970: 1))
        #expect(snap.window(.sevenDay)?.utilization == 0.36)
    }

    @Test("billingCycleEnd assente → finestre senza resetsAt, niente crash")
    func noBillingDate() {
        let summary = CursorUsageSummaryFixture.make(autoPercent: 10, apiPercent: 20, totalPercent: 15, billingEnd: nil)
        let snap = CursorUsageFetcher.makeSnapshot(summary: summary, userInfo: nil, now: Date(timeIntervalSince1970: 1))
        #expect(snap.window(.sevenDay)?.resetsAt == nil)
        #expect(snap.window(.sevenDay)?.utilization == 15)
    }

    @Test("On-demand con limite assente/illimitato → niente credits (evita budget falso)")
    func onDemandUnlimitedNoCredits() {
        let summary = CursorUsageSummaryFixture.make(autoPercent: 10, onDemandUsed: 500, onDemandLimit: nil)
        let snap = CursorUsageFetcher.makeSnapshot(summary: summary, userInfo: nil, now: Date(timeIntervalSince1970: 1))
        #expect(snap.credits == nil)
    }

    @Test("Cap personale enterprise (overall) usato come headline quando manca il plan")
    func overallFallback() throws {
        let summary = CursorUsageSummaryFixture.makeOverall(used: 7384, limit: 10000)
        let snap = CursorUsageFetcher.makeSnapshot(summary: summary, userInfo: nil, now: Date(timeIntervalSince1970: 1))
        let util = try #require(snap.window(.sevenDay)?.utilization)
        #expect(abs(util - 73.84) < 0.001)   // 7384/10000*100, tolleranza floating point
    }

    @Test("Cookie scaduto (401): unauthorized (terminale)")
    func expiredCookieUnauthorized() async throws {
        let store = InMemorySecretStore()
        try store.setSecret("stale=1", provider: .cursor, account: "default")
        let loader = routedLoader([Self.usageSummaryPath: (401, "{}")])
        let provider = CursorProvider(secretStore: store, loader: loader)
        await #expect(throws: ProviderError.self) {
            _ = try await provider.snapshot(context: ctx)
        }
    }

    @Test("Identità best-effort: se /auth/me fallisce, lo snapshot riesce comunque")
    func identityBestEffort() async throws {
        let store = InMemorySecretStore()
        try store.setSecret("c=1", provider: .cursor, account: "default")
        let summary = CursorUsageSummaryFixture.makeJSON(totalPercent: 20)
        let loader = routedLoader([
            Self.usageSummaryPath: (200, summary),
            Self.authMePath: (500, "{}"),
        ])
        let provider = CursorProvider(secretStore: store, loader: loader)
        let snapshot = try await provider.snapshot(context: ctx)
        #expect(snapshot.window(.sevenDay)?.utilization == 20)
        #expect(snapshot.identity.email == nil)
    }
}

// MARK: - Fixture builder per CursorUsageSummary (decodifica da JSON per restare fedele alla shape)

private enum CursorUsageSummaryFixture {
    /// Costruisce un `CursorUsageSummary` da una shape `individualUsage.plan`.
    static func make(
        autoPercent: Double? = nil,
        apiPercent: Double? = nil,
        totalPercent: Double? = nil,
        used: Int? = nil,
        limit: Int? = nil,
        onDemandUsed: Int? = nil,
        onDemandLimit: Int? = nil,
        billingEnd: String? = "2026-07-01T00:00:00Z") -> CursorUsageSummary
    {
        try! JSONDecoder().decode(
            CursorUsageSummary.self,
            from: Data(makeJSON(
                autoPercent: autoPercent, apiPercent: apiPercent, totalPercent: totalPercent,
                used: used, limit: limit, onDemandUsed: onDemandUsed, onDemandLimit: onDemandLimit,
                billingEnd: billingEnd).utf8))
    }

    static func makeOverall(used: Int, limit: Int) -> CursorUsageSummary {
        let json = """
        { "membershipType": "enterprise",
          "individualUsage": { "overall": { "used": \(used), "limit": \(limit) } } }
        """
        return try! JSONDecoder().decode(CursorUsageSummary.self, from: Data(json.utf8))
    }

    static func makeJSON(
        autoPercent: Double? = nil,
        apiPercent: Double? = nil,
        totalPercent: Double? = nil,
        used: Int? = nil,
        limit: Int? = nil,
        onDemandUsed: Int? = nil,
        onDemandLimit: Int? = nil,
        billingEnd: String? = "2026-07-01T00:00:00Z") -> String
    {
        var planFields: [String] = []
        if let used { planFields.append("\"used\": \(used)") }
        if let limit { planFields.append("\"limit\": \(limit)") }
        if let autoPercent { planFields.append("\"autoPercentUsed\": \(autoPercent)") }
        if let apiPercent { planFields.append("\"apiPercentUsed\": \(apiPercent)") }
        if let totalPercent { planFields.append("\"totalPercentUsed\": \(totalPercent)") }
        let plan = planFields.isEmpty ? "" : "\"plan\": { \(planFields.joined(separator: ", ")) }"

        var onDemandFields: [String] = []
        if let onDemandUsed { onDemandFields.append("\"used\": \(onDemandUsed)") }
        if let onDemandLimit { onDemandFields.append("\"limit\": \(onDemandLimit)") }
        let onDemand = onDemandFields.isEmpty ? "" : "\"onDemand\": { \(onDemandFields.joined(separator: ", ")) }"

        let individualInner = [plan, onDemand].filter { !$0.isEmpty }.joined(separator: ", ")
        let billing = billingEnd.map { "\"billingCycleEnd\": \"\($0)\", " } ?? ""

        return """
        { \(billing)"membershipType": "pro", "individualUsage": { \(individualInner) } }
        """
    }
}

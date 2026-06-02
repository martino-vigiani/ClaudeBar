import Foundation
import Testing
@testable import ClaudeBarCore

// Test dei provider "API a consumo" (Anthropic API / OpenAI API):
//  - parsing + aggregazione delle risposte REALI (fixture JSON con la shape ufficiale);
//  - mappatura nel modello unificato: windows VUOTE + cost valorizzato (vista "usage+costo");
//  - fallback credito OpenAI (credit_grants legacy);
//  - risoluzione credenziali Keychain (store) > env;
//  - end-to-end del provider via URLSession stub (nessuna rete reale).

// MARK: - Fixture & helper di rete

/// `URLProtocol` che restituisce una risposta canned per host/path, per testare i fetch senza rete.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    /// Mappa "path della richiesta" → (status, body JSON). Impostata prima di ogni test.
    nonisolated(unsafe) static var routes: [String: (status: Int, body: Data)] = [:]
    /// Path effettivamente richiesti (per asserire query/endpoint).
    nonisolated(unsafe) static var requestedURLs: [URL] = []

    static func reset() {
        self.routes = [:]
        self.requestedURLs = []
    }

    override class func canInit(with _: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        if let url = request.url { Self.requestedURLs.append(url) }
        let path = request.url?.path ?? ""
        let route = Self.routes[path] ?? (status: 404, body: Data("{}".utf8))
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: route.status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: route.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private func stubbedSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [StubURLProtocol.self]
    return URLSession(configuration: config)
}

private let referenceNow = Date(timeIntervalSince1970: 1_700_000_000) // 2023-11-14T...

// MARK: - Anthropic: aggregazione

@Suite("Anthropic API — aggregazione usage+costo")
struct AnthropicAPIAggregationTests {
    // Due giorni; amount in CENTESIMI → USD = /100. Token con cache.
    private let costsJSON = Data("""
    {"data":[
      {"starting_at":"2023-11-13T00:00:00Z","ending_at":"2023-11-14T00:00:00Z",
       "results":[{"currency":"USD","amount":"1250","description":"Claude API"}]},
      {"starting_at":"2023-11-14T00:00:00Z","ending_at":"2023-11-15T00:00:00Z",
       "results":[{"currency":"USD","amount":"500","description":"Claude API"},
                  {"currency":"USD","amount":"250","description":"Web search"}]}
    ],"has_more":false}
    """.utf8)

    private let messagesJSON = Data("""
    {"data":[
      {"starting_at":"2023-11-13T00:00:00Z","ending_at":"2023-11-14T00:00:00Z",
       "results":[{"uncached_input_tokens":1000,"cache_read_input_tokens":200,
                   "cache_creation":{"ephemeral_5m_input_tokens":100,"ephemeral_1h_input_tokens":0},
                   "output_tokens":300,"model":"claude-opus-4-8"}]},
      {"starting_at":"2023-11-14T00:00:00Z","ending_at":"2023-11-15T00:00:00Z",
       "results":[{"uncached_input_tokens":2000,"cache_read_input_tokens":0,
                   "output_tokens":500,"model":"claude-sonnet-4-6"}]}
    ],"has_more":false}
    """.utf8)

    @Test("amount in centesimi → USD/100, somma su 30g e Oggi")
    func costAggregation() throws {
        let cost = try AnthropicAPIUsageFetcher._aggregateForTesting(
            costsJSON: costsJSON, messagesJSON: messagesJSON, historyDays: 30, now: referenceNow)
        // 30g = (1250 + 500 + 250)/100 = 20.0 USD
        let bucket30 = try #require(cost.buckets.first(where: { $0.rangeDays == 30 }))
        #expect(abs((bucket30.costUSD ?? 0) - 20.0) < 1e-9)
        // Oggi (ultimo giorno) = (500+250)/100 = 7.5 USD
        let bucket1 = try #require(cost.buckets.first(where: { $0.rangeDays == 1 }))
        #expect(abs((bucket1.costUSD ?? 0) - 7.5) < 1e-9)
    }

    @Test("token totali e breakdown per modello")
    func tokenAggregation() throws {
        let cost = try AnthropicAPIUsageFetcher._aggregateForTesting(
            costsJSON: costsJSON, messagesJSON: messagesJSON, historyDays: 30, now: referenceNow)
        let bucket30 = try #require(cost.buckets.first(where: { $0.rangeDays == 30 }))
        // Giorno1: input+cacheRead+cacheCreate = 1000+200+100=1300, output 300, tot 1600
        // Giorno2: input 2000, output 500, tot 2500 → tot 4100
        #expect(bucket30.totalTokens == 4100)
        #expect(bucket30.inputTokens == 1300 + 2000)
        #expect(bucket30.outputTokens == 300 + 500)
        // Breakdown: due modelli, ordinati per token desc (sonnet 2500 > opus 1600).
        #expect(cost.byModel.count == 2)
        #expect(cost.byModel.first?.model == "claude-sonnet-4-6")
        #expect(cost.byModel.first?.totalTokens == 2500)
    }

    @Test("range 'Oggi' (1g) somma solo l'ultimo giorno di token")
    func todayRange() throws {
        let cost = try AnthropicAPIUsageFetcher._aggregateForTesting(
            costsJSON: costsJSON, messagesJSON: messagesJSON, historyDays: 30, now: referenceNow)
        let bucket1 = try #require(cost.buckets.first(where: { $0.rangeDays == 1 }))
        #expect(bucket1.totalTokens == 2500)
    }
}

// MARK: - OpenAI: aggregazione + credito

@Suite("OpenAI API — aggregazione usage+costo e credito")
struct OpenAIAPIAggregationTests {
    private let day1 = 1_699_833_600 // 2023-11-13T00:00:00Z
    private let day2 = 1_699_920_000 // 2023-11-14T00:00:00Z

    private func costsJSON() -> Data {
        Data("""
        {"data":[
          {"start_time":\(day1),"end_time":\(day2),
           "results":[{"amount":{"value":3.0},"line_item":"gpt-4o input"}]},
          {"start_time":\(day2),"end_time":\(day2 + 86400),
           "results":[{"amount":{"value":1.5},"line_item":"gpt-4o input"},
                      {"amount":{"value":0.5},"line_item":"gpt-4o output"}]}
        ]}
        """.utf8)
    }

    private func completionsJSON() -> Data {
        Data("""
        {"data":[
          {"start_time":\(day1),"end_time":\(day2),
           "results":[{"input_tokens":1000,"input_cached_tokens":100,"output_tokens":200,
                       "num_model_requests":5,"model":"gpt-4o"}]},
          {"start_time":\(day2),"end_time":\(day2 + 86400),
           "results":[{"input_tokens":3000,"output_tokens":700,"num_model_requests":9,"model":"gpt-4o-mini"}]}
        ]}
        """.utf8)
    }

    @Test("costo USD sommato su 30g e Oggi")
    func costAggregation() throws {
        let cost = try OpenAIAPIUsageFetcher._aggregateForTesting(
            costsJSON: costsJSON(), completionsJSON: completionsJSON(), historyDays: 30, now: referenceNow)
        let bucket30 = try #require(cost.buckets.first(where: { $0.rangeDays == 30 }))
        #expect(abs((bucket30.costUSD ?? 0) - 5.0) < 1e-9) // 3.0 + 1.5 + 0.5
        let bucket1 = try #require(cost.buckets.first(where: { $0.rangeDays == 1 }))
        #expect(abs((bucket1.costUSD ?? 0) - 2.0) < 1e-9) // 1.5 + 0.5
    }

    @Test("token totali e breakdown per modello (audio escluso qui)")
    func tokenAggregation() throws {
        let cost = try OpenAIAPIUsageFetcher._aggregateForTesting(
            costsJSON: costsJSON(), completionsJSON: completionsJSON(), historyDays: 30, now: referenceNow)
        let bucket30 = try #require(cost.buckets.first(where: { $0.rangeDays == 30 }))
        // Giorno1: 1000+200=1200, Giorno2: 3000+700=3700 → 4900
        #expect(bucket30.totalTokens == 4900)
        // mini 3700 > 4o 1200
        #expect(cost.byModel.first?.model == "gpt-4o-mini")
        #expect(cost.byModel.first?.totalTokens == 3700)
    }

    @Test("credit_grants legacy → ProviderCredits con remaining/total")
    func creditMapping() throws {
        let json = Data("""
        {"total_granted":100.0,"total_used":40.0,"total_available":60.0}
        """.utf8)
        let credits = try OpenAIAPIUsageFetcher._creditsForTesting(creditsJSON: json)
        #expect(credits.remaining == 60.0)
        #expect(credits.total == 100.0)
        #expect(credits.usedFraction == 0.4)
    }
}

// MARK: - Risoluzione credenziali (Keychain store > env)

@Suite("API key — risoluzione credenziali")
struct APIKeyCredentialResolutionTests {
    @Test("Anthropic: Keychain ha priorità sull'env")
    func anthropicKeychainWins() throws {
        let store = InMemorySecretStore()
        try store.setSecret("sk-ant-admin-FROMKEYCHAIN", provider: .anthropicAPI, account: "default")
        let resolved = AnthropicAPICredential.resolve(
            store: store, environment: ["ANTHROPIC_ADMIN_KEY": "sk-ant-admin-FROMENV"])
        #expect(resolved == "sk-ant-admin-FROMKEYCHAIN")
    }

    @Test("Anthropic: senza Keychain usa l'env")
    func anthropicEnvFallback() {
        let store = InMemorySecretStore()
        let resolved = AnthropicAPICredential.resolve(
            store: store, environment: ["ANTHROPIC_ADMIN_API_KEY": "  sk-ant-admin-ENV  "])
        #expect(resolved == "sk-ant-admin-ENV") // trim applicato
    }

    @Test("Anthropic: niente credenziali → nil + isAvailable false")
    func anthropicNone() {
        let store = InMemorySecretStore()
        #expect(AnthropicAPICredential.resolve(store: store, environment: [:]) == nil)
        #expect(!AnthropicAPICredential.isAvailable(store: store, environment: [:]))
    }

    @Test("OpenAI: Keychain ha priorità e projectID viene da env")
    func openaiKeychainAndProject() throws {
        let store = InMemorySecretStore()
        try store.setSecret("sk-admin-KC", provider: .openaiAPI, account: "default")
        let resolved = OpenAIAPICredential.resolve(
            store: store,
            environment: ["OPENAI_API_KEY": "sk-ENV", "OPENAI_PROJECT_ID": "proj_123"])
        #expect(resolved?.apiKey == "sk-admin-KC")
        #expect(resolved?.projectID == "proj_123")
    }

    @Test("OpenAI: env Admin key preferita su API key")
    func openaiAdminPreferred() {
        let store = InMemorySecretStore()
        let resolved = OpenAIAPICredential.resolve(
            store: store,
            environment: ["OPENAI_ADMIN_KEY": "sk-admin-X", "OPENAI_API_KEY": "sk-Y"])
        #expect(resolved?.apiKey == "sk-admin-X")
    }
}

// MARK: - End-to-end provider (URLSession stub)

// `.serialized`: lo stub usa route statiche condivise; serializziamo per evitare che i test
// paralleli si sovrascrivano le route a vicenda.
@Suite("API key — provider end-to-end (stub di rete)", .serialized)
struct APIKeyProviderEndToEndTests {
    private func context(now: Date) -> ProviderFetchContext {
        ProviderFetchContext(userInitiated: true, environment: [:], now: { now })
    }

    @Test("AnthropicAPIProvider produce snapshot SENZA finestre e con cost valorizzato")
    func anthropicSnapshot() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.routes["/v1/organizations/cost_report"] = (200, Data("""
        {"data":[{"starting_at":"2023-11-14T00:00:00Z","ending_at":"2023-11-15T00:00:00Z",
          "results":[{"amount":"999","description":"Claude API"}]}]}
        """.utf8))
        StubURLProtocol.routes["/v1/organizations/usage_report/messages"] = (200, Data("""
        {"data":[{"starting_at":"2023-11-14T00:00:00Z","ending_at":"2023-11-15T00:00:00Z",
          "results":[{"uncached_input_tokens":10,"output_tokens":5,"model":"claude-opus-4-8"}]}]}
        """.utf8))

        let store = InMemorySecretStore()
        try store.setSecret("sk-ant-admin-test", provider: .anthropicAPI, account: "default")
        let provider = AnthropicAPIProvider(secretStore: store, session: stubbedSession())

        let snapshot = try await provider.snapshot(context: context(now: referenceNow))
        #expect(snapshot.providerID == .anthropicAPI)
        #expect(snapshot.windows.isEmpty)      // niente limiti
        #expect(!snapshot.hasLimits)
        #expect(snapshot.cost != nil)          // usage+costo presente
        #expect(abs((snapshot.cost?.buckets.first(where: { $0.rangeDays == 1 })?.costUSD ?? 0) - 9.99) < 1e-9)
        #expect(snapshot.glance == .ok)        // a consumo → niente falso rosso
        #expect(snapshot.identity.plan == "pay-as-you-go")
        #expect(snapshot.source == .live)
    }

    @Test("OpenAIAPIProvider end-to-end con costs+completions")
    func openaiSnapshot() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.routes["/v1/organization/costs"] = (200, Data("""
        {"data":[{"start_time":1699920000,"end_time":1700006400,
          "results":[{"amount":{"value":4.2},"line_item":"gpt-4o"}]}]}
        """.utf8))
        StubURLProtocol.routes["/v1/organization/usage/completions"] = (200, Data("""
        {"data":[{"start_time":1699920000,"end_time":1700006400,
          "results":[{"input_tokens":100,"output_tokens":50,"num_model_requests":2,"model":"gpt-4o"}]}]}
        """.utf8))

        let store = InMemorySecretStore()
        try store.setSecret("sk-admin-test", provider: .openaiAPI, account: "default")
        let provider = OpenAIAPIProvider(secretStore: store, session: stubbedSession())

        let snapshot = try await provider.snapshot(context: context(now: referenceNow))
        #expect(snapshot.providerID == .openaiAPI)
        #expect(snapshot.windows.isEmpty)
        #expect(snapshot.cost?.byModel.first?.model == "gpt-4o")
        #expect(abs((snapshot.cost?.buckets.first(where: { $0.rangeDays == 30 })?.costUSD ?? 0) - 4.2) < 1e-9)
    }

    @Test("OpenAI: Admin usage in 403 → fallback al credito legacy")
    func openaiCreditFallback() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.routes["/v1/organization/costs"] = (403, Data("{\"error\":\"forbidden\"}".utf8))
        StubURLProtocol.routes["/v1/organization/usage/completions"] = (403, Data("{}".utf8))
        StubURLProtocol.routes["/v1/dashboard/billing/credit_grants"] = (200, Data("""
        {"total_granted":50.0,"total_used":20.0,"total_available":30.0}
        """.utf8))

        let store = InMemorySecretStore()
        try store.setSecret("sk-legacy-test", provider: .openaiAPI, account: "default")
        // Nessun OPENAI_PROJECT_ID → projectID nil → fallback consentito.
        let provider = OpenAIAPIProvider(secretStore: store, session: stubbedSession())

        let snapshot = try await provider.snapshot(context: context(now: referenceNow))
        #expect(snapshot.cost == nil)
        #expect(snapshot.credits?.remaining == 30.0)
        #expect(snapshot.credits?.total == 50.0)
    }

    @Test("Senza credenziali → noCredentials (terminale, niente rete)")
    func anthropicNoCredentials() async {
        StubURLProtocol.reset()
        let provider = AnthropicAPIProvider(secretStore: InMemorySecretStore(), session: stubbedSession())
        await #expect(throws: ProviderError.noAvailableStrategy(.anthropicAPI)) {
            _ = try await provider.snapshot(context: context(now: referenceNow))
        }
    }

    @Test("401 sull'Admin Anthropic → unauthorized con avviso 'Admin key org' (provider visibile)")
    func anthropicUnauthorized() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.routes["/v1/organizations/cost_report"] = (401, Data("{\"error\":\"invalid key\"}".utf8))
        StubURLProtocol.routes["/v1/organizations/usage_report/messages"] = (401, Data("{}".utf8))

        let store = InMemorySecretStore()
        try store.setSecret("sk-ant-admin-bad", provider: .anthropicAPI, account: "default")
        let provider = AnthropicAPIProvider(secretStore: store, session: stubbedSession())

        // DECISIONS §5: l'errore porta il messaggio d'avviso (la UI lo mostra senza nascondere il
        // provider). È terminale → niente loop di retry automatici.
        await #expect(throws: ProviderError.unauthorized(AnthropicAPICredential.adminKeyRequiredMessage)) {
            _ = try await provider.snapshot(context: context(now: referenceNow))
        }
        #expect(ProviderError.unauthorized(AnthropicAPICredential.adminKeyRequiredMessage).isTerminal)
    }

    @Test("OpenAI: niente credenziali e niente fallback → strategia non disponibile (no crash)")
    func openaiNoCredentials() async {
        StubURLProtocol.reset()
        let provider = OpenAIAPIProvider(secretStore: InMemorySecretStore(), session: stubbedSession())
        // isAvailable == false → la pipeline non invoca fetch → noAvailableStrategy (terminale, niente rete).
        await #expect(throws: ProviderError.noAvailableStrategy(.openaiAPI)) {
            _ = try await provider.snapshot(context: context(now: referenceNow))
        }
    }

    @Test("detectAvailability è true con una chiave nel Keychain, false senza")
    func detectAvailability() async throws {
        let store = InMemorySecretStore()
        let provider = OpenAIAPIProvider(secretStore: store, session: stubbedSession())
        #expect(await provider.detectAvailability(context(now: referenceNow)).isAvailable == false)

        try store.setSecret("sk-admin", provider: .openaiAPI, account: "default")
        let availability = await provider.detectAvailability(context(now: referenceNow))
        #expect(availability.isAvailable)
        #expect(availability.detectedAuth == .apiKey)
    }
}

// MARK: - Keychain reale (round-trip)

// Round-trip sul VERO KeychainSecretStore (non l'in-memory): set/read/list/remove con un service
// prefix di test isolato, ripulito al termine. `.serialized` e guardato macOS: in ambienti CI senza
// Keychain accessibile il `setSecret` puo' fallire; in tal caso il test viene saltato pulito.
@Suite("API key — Keychain reale (round-trip)", .serialized)
struct KeychainSecretStoreRoundTripTests {
    #if os(macOS)
    @Test("set/read/list/remove su Keychain reale, niente residui")
    func realKeychainRoundTrip() throws {
        let prefix = "com.subralabs.claudebar.test.\(UUID().uuidString)"
        let store = KeychainSecretStore(servicePrefix: prefix)
        let account = KeychainSecretStore.defaultAccount

        // Se il Keychain non e' disponibile nell'ambiente di test, salta senza fallire.
        do {
            try store.setSecret("sk-ant-admin-roundtrip", provider: .anthropicAPI, account: account)
        } catch {
            return // ambiente senza accesso Keychain (CI headless): non e' una regressione.
        }
        defer { try? store.removeSecret(provider: .anthropicAPI, account: account) }

        #expect(try store.secret(provider: .anthropicAPI, account: account) == "sk-ant-admin-roundtrip")
        #expect(try store.accounts(provider: .anthropicAPI) == [account])
        // Upsert idempotente: riscrivere aggiorna senza duplicare.
        try store.setSecret("sk-ant-admin-updated", provider: .anthropicAPI, account: account)
        #expect(try store.secret(provider: .anthropicAPI, account: account) == "sk-ant-admin-updated")
        #expect(try store.accounts(provider: .anthropicAPI).count == 1)

        try store.removeSecret(provider: .anthropicAPI, account: account)
        #expect(try store.secret(provider: .anthropicAPI, account: account) == nil)
        #expect(try store.accounts(provider: .anthropicAPI).isEmpty)
    }
    #endif
}

import Foundation
import Testing
@testable import ClaudeBarCore

// Test di ClaudeLimitsService: read-through cache delle credenziali CLI (no prompt ripetuti),
// thread di `allowUI` nel reread su token scaduto, e regressione del gate 429.
// La rete è mockata con un URLProtocol DEDICATO (handler statico proprio): non condividiamo lo
// stato con il MockURLProtocol di CodexProviderTests, così le due suite non si pestano l'handler
// quando girano in parallelo nel run completo. Il seam `credentialReader` sostituisce la lettura
// reale del Keychain. Tutto deterministico e offline.

/// URLProtocol mock dedicato a questa suite (handler statico separato da CodexProviderTests).
final class ClaudeLimitsMockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) -> (Int, Data))?

    override class func canInit(with _: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let (status, data) = handler(request)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

// MARK: - Helper

/// Spia thread-safe del seam `credentialReader`: conta gli accessi e registra i flag `allowUI`,
/// restituendo una coda di risultati (uno per chiamata; l'ultimo si ripete).
private final class CredentialReaderSpy: @unchecked Sendable {
    private let lock = NSLock()
    private var results: [KeychainReader.ReadResult?]
    private var index = 0
    private(set) var calls = 0
    private(set) var allowUIFlags: [Bool] = []

    init(returning results: [KeychainReader.ReadResult?]) {
        self.results = results
    }

    /// Convenienza: sempre lo stesso risultato.
    convenience init(always result: KeychainReader.ReadResult?) {
        self.init(returning: [result])
    }

    func read(allowUI: Bool) throws -> KeychainReader.ReadResult? {
        lock.lock()
        defer { lock.unlock() }
        calls += 1
        allowUIFlags.append(allowUI)
        let result = index < results.count ? results[index] : results.last ?? nil
        if index < results.count - 1 { index += 1 }
        return result
    }

    /// Adatta la spia al tipo `CredentialReader` atteso dall'init del service.
    var reader: ClaudeLimitsService.CredentialReader {
        { [self] allowUI in try self.read(allowUI: allowUI) }
    }
}

/// Costruisce un `ReadResult` con un JSON `claudeAiOauth` valido.
/// - Parameter expiresAt: scadenza assoluta (default = 1h nel futuro reale → token valido).
private func keychainResult(
    token: String = "AT",
    refreshToken: String? = nil,
    expiresAt: Date = Date().addingTimeInterval(3600),
    account: String = "tester") -> KeychainReader.ReadResult
{
    let ms = Int(expiresAt.timeIntervalSince1970 * 1000)
    var fields = #""accessToken": "\#(token)", "expiresAt": \#(ms), "subscriptionType": "max""#
    if let refreshToken {
        fields += #", "refreshToken": "\#(refreshToken)""#
    }
    let json = "{ \"claudeAiOauth\": { \(fields) } }"
    return KeychainReader.ReadResult(data: Data(json.utf8), account: account)
}

/// URLSession con l'URLProtocol mock dedicato: il primo elemento di `responses` serve la prima
/// GET, il secondo la seconda, ecc. (l'ultimo si ripete).
private func makeSession(responses: [(Int, Data)]) -> URLSession {
    let box = ResponseBox(responses)
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [ClaudeLimitsMockURLProtocol.self]
    ClaudeLimitsMockURLProtocol.handler = { _ in box.next() }
    return URLSession(configuration: config)
}

/// Coda thread-safe di risposte HTTP per il mock (l'ultima si ripete).
private final class ResponseBox: @unchecked Sendable {
    private let lock = NSLock()
    private let responses: [(Int, Data)]
    private var index = 0
    init(_ responses: [(Int, Data)]) { self.responses = responses }
    func next() -> (Int, Data) {
        lock.lock()
        defer { lock.unlock() }
        let r = index < responses.count ? responses[index] : (responses.last ?? (200, Data()))
        if index < responses.count - 1 { index += 1 }
        return r
    }
}

/// JSON usage 200 minimale (five_hour + seven_day) per una risposta valida.
private let usageOK = Data("""
{ "five_hour": { "utilization": 10, "resets_at": "2030-01-01T00:00:00Z" },
  "seven_day": { "utilization": 20, "resets_at": "2030-01-01T00:00:00Z" } }
""".utf8)

// Suite radice serializzata: le sotto-suite condividono lo statico `MockURLProtocol.handler`,
// quindi NON devono girare in parallelo tra loro (si sovrascriverebbero la risposta). Annidandole
// dentro una suite `.serialized` Swift Testing serializza l'intero albero.
@Suite("ClaudeLimits", .tags(.networking), .serialized)
struct ClaudeLimitsServiceTests {

// MARK: - Cache read-through (no prompt ripetuti)

@Suite("cache credenziali")
struct ClaudeLimitsCacheTests {
    @Test("due fetch con token valido → Keychain letto UNA sola volta (cache hit)")
    func cachesCLICredentials() async throws {
        let spy = CredentialReaderSpy(always: keychainResult())
        let session = makeSession(responses: [(200, usageOK), (200, usageOK)])
        let service = ClaudeLimitsService(
            session: session,
            environment: [:],
            credentialReader: spy.reader)

        _ = try await service.fetchUsage(userInitiated: true)
        _ = try await service.fetchUsage(userInitiated: true)

        // Il secondo fetch serve dalla cache in memoria: nessun secondo accesso al Keychain.
        #expect(spy.calls == 1)
    }
}

// MARK: - Token scaduto + reread

@Suite("token scaduto (owner CLI)")
struct ClaudeLimitsExpiryTests {
    @Test("scaduto + reread ancora scaduto → refreshDelegatedToCLI")
    func delegatesWhenStillExpired() async {
        let expired = keychainResult(expiresAt: Date().addingTimeInterval(-3600))
        let spy = CredentialReaderSpy(always: expired)
        let session = makeSession(responses: [(200, usageOK)])
        let service = ClaudeLimitsService(
            session: session,
            environment: [:],
            credentialReader: spy.reader)

        await #expect(throws: ClaudeLimitsError.refreshDelegatedToCLI) {
            _ = try await service.fetchUsage(userInitiated: true)
        }
    }

    @Test("scaduto + reread con creds fresche → fetch riesce")
    func recoversWhenRereadFresh() async throws {
        let expired = keychainResult(token: "OLD", expiresAt: Date().addingTimeInterval(-3600))
        let fresh = keychainResult(token: "NEW", expiresAt: Date().addingTimeInterval(3600))
        // 1ª lettura (loadRecord) = scaduta; 2ª lettura (reread) = fresca.
        let spy = CredentialReaderSpy(returning: [expired, fresh])
        let session = makeSession(responses: [(200, usageOK)])
        let service = ClaudeLimitsService(
            session: session,
            environment: [:],
            credentialReader: spy.reader)

        let snapshot = try await service.fetchUsage(userInitiated: true)
        #expect(snapshot.source == .live)
        #expect(spy.calls == 2)
    }

    @Test("reread riceve allowUI = userInitiated")
    func rereadThreadsAllowUI() async throws {
        // userInitiated:true → entrambe le letture (loadRecord + reread) con allowUI:true.
        let expired = keychainResult(token: "OLD", expiresAt: Date().addingTimeInterval(-3600))
        let fresh = keychainResult(token: "NEW", expiresAt: Date().addingTimeInterval(3600))
        let spyUI = CredentialReaderSpy(returning: [expired, fresh])
        let service = ClaudeLimitsService(
            session: makeSession(responses: [(200, usageOK)]),
            environment: [:],
            credentialReader: spyUI.reader)
        _ = try await service.fetchUsage(userInitiated: true)
        #expect(spyUI.allowUIFlags == [true, true])

        // userInitiated:false (timer/background) → entrambe le letture no-UI.
        let spyNoUI = CredentialReaderSpy(returning: [expired, fresh])
        let serviceBG = ClaudeLimitsService(
            session: makeSession(responses: [(200, usageOK)]),
            environment: [:],
            credentialReader: spyNoUI.reader)
        _ = try await serviceBG.fetchUsage(userInitiated: false)
        #expect(spyNoUI.allowUIFlags == [false, false])
    }
}

// MARK: - Gate 429 (regressione)

@Suite("gate 429")
struct ClaudeLimitsRateLimitTests {
    @Test("429 con cache → secondo fetch dentro la finestra ritorna cache stale senza rete")
    func returnsStaleCacheWhileBlocked() async throws {
        let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)
        let spy = CredentialReaderSpy(always: keychainResult())
        // 1ª GET = 200 (popola la cache snapshot); 2ª GET = 429 (arma il gate).
        let session = makeSession(responses: [(200, usageOK), (429, Data("rate".utf8))])
        let service = ClaudeLimitsService(
            session: session,
            environment: [:],
            now: { fixedNow },
            credentialReader: spy.reader)

        let live = try await service.fetchUsage(userInitiated: true)
        #expect(live.source == .live)

        // Questo fetch becca il 429 e arma blockedUntil; ritorna la cache marcata stale.
        let stale = try await service.fetchUsage(userInitiated: true)
        #expect(stale.source == .stale)

        // Terzo fetch DENTRO la finestra di blocco: deve servire la cache stale
        // SENZA rifare la GET. Se rifacesse rete colpirebbe ancora il 429 della coda.
        let blocked = try await service.fetchUsage(userInitiated: true)
        #expect(blocked.source == .stale)
    }
}

} // fine suite radice ClaudeLimitsServiceTests

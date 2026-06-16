import Foundation
import Testing
@testable import ClaudeBarCore

// Test del self-refresh OAuth per il token CLI (claudeCLI owner) + patch JSON grezzo.
//
// Contesto: ClaudeBar ora può auto-rinnovare il token scaduto della CLI e RISCRIVERE
// l'item Keychain condiviso (write-back), invece di delegare sempre alla CLI.
// Questa suite verifica:
//   1. `ClaudeOAuthCredentials.patchedRawJSON` — pure, zero rete, zero Keychain.
//   2. Self-refresh happy path: token scaduto con refreshToken → rinnova + write-back.
//   3. Pre-check guard: se il write idempotente iniziale fallisce, il refresh_token NON
//      viene consumato (garanzia di sicurezza fondamentale).
//   4. Background path (userInitiated: false): il self-refresh non viene mai tentato.
//
// URLProtocol stub separato da ClaudeLimitsServiceTests: handler statico proprio, così
// le due suite non si pestano l'handler quando girano in parallelo nel run completo.
// Serializzato a livello di suite radice per la stessa ragione.

// MARK: - URLProtocol mock dedicato

final class SelfRefreshMockURLProtocol: URLProtocol, @unchecked Sendable {
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

// MARK: - Helpers

/// Coda di risposte HTTP thread-safe per il mock (l'ultima si ripete).
private final class SelfRefreshResponseBox: @unchecked Sendable {
    private let lock = NSLock()
    private let responses: [(Int, Data)]
    private var index = 0
    /// Tutte le URL richieste al mock, in ordine di chiamata.
    private(set) var requestedURLs: [URL] = []

    init(_ responses: [(Int, Data)]) { self.responses = responses }

    func next(for url: URL?) -> (Int, Data) {
        lock.lock()
        defer { lock.unlock() }
        if let url { requestedURLs.append(url) }
        let r = index < responses.count ? responses[index] : (responses.last ?? (200, Data()))
        if index < responses.count - 1 { index += 1 }
        return r
    }
}

/// Costruisce un URLSession con `SelfRefreshMockURLProtocol`.
/// `box` è l'accumulatore: consente di ispezionare le URL richieste dopo il fetch.
private func makeSelfRefreshSession(
    box: SelfRefreshResponseBox
) -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [SelfRefreshMockURLProtocol.self]
    SelfRefreshMockURLProtocol.handler = { req in box.next(for: req.url) }
    return URLSession(configuration: config)
}

/// Spia thread-safe del seam `credentialWriter`: conta le chiamate e registra l'ultima data.
private final class CredentialWriterSpy: @unchecked Sendable {
    private let lock = NSLock()
    private let returnValue: Bool
    private(set) var callCount = 0
    private(set) var writtenPayloads: [Data] = []

    init(returns: Bool = true) { returnValue = returns }

    func write(data: Data, persistentRef _: Data) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        callCount += 1
        writtenPayloads.append(data)
        return returnValue
    }

    var writer: ClaudeLimitsService.CredentialWriter {
        { [self] data, ref in self.write(data: data, persistentRef: ref) }
    }
}

/// Spia thread-safe del seam `credentialReader`.
private final class CredentialReaderSpy: @unchecked Sendable {
    private let lock = NSLock()
    private var results: [KeychainReader.ReadResult?]
    private var index = 0

    init(returning results: [KeychainReader.ReadResult?]) { self.results = results }
    convenience init(always result: KeychainReader.ReadResult?) { self.init(returning: [result]) }

    func read(allowUI _: Bool) throws -> KeychainReader.ReadResult? {
        lock.lock()
        defer { lock.unlock() }
        let r = index < results.count ? results[index] : results.last ?? nil
        if index < results.count - 1 { index += 1 }
        return r
    }

    var reader: ClaudeLimitsService.CredentialReader {
        { [self] allowUI in try self.read(allowUI: allowUI) }
    }
}

// MARK: - Fixture factories

private let fakeRef = Data("fake-persistent-ref".utf8)

/// `ReadResult` con token SCADUTO e un refreshToken, idoneo per il self-refresh.
/// `persistentRef` non-nil segnala al service che l'item è tracciabile per il write-back.
private func expiredCLIResult(
    accessToken: String = "OLD_AT",
    refreshToken: String = "REFRESH_TOKEN_123",
    persistentRef: Data? = fakeRef
) -> KeychainReader.ReadResult {
    let expiredMs = Int((Date().addingTimeInterval(-3600)).timeIntervalSince1970 * 1000)
    let json = """
    {
      "claudeAiOauth": {
        "accessToken": "\(accessToken)",
        "refreshToken": "\(refreshToken)",
        "expiresAt": \(expiredMs),
        "subscriptionType": "max",
        "scopes": ["user:inference"],
        "rateLimitTier": "tier1"
      }
    }
    """
    return KeychainReader.ReadResult(
        data: Data(json.utf8),
        account: "testuser",
        persistentRef: persistentRef)
}

/// Risposta JSON `200` per l'endpoint `/v1/oauth/token` (rinnovo token).
/// `expiresIn` = 3600s → il token rinnovato sarà non-scaduto.
private func tokenRefreshResponseData(
    newAccessToken: String = "NEW_AT",
    newRefreshToken: String = "NEW_REFRESH_456"
) -> Data {
    Data("""
    {
      "access_token": "\(newAccessToken)",
      "refresh_token": "\(newRefreshToken)",
      "expires_in": 3600,
      "token_type": "Bearer"
    }
    """.utf8)
}

/// Risposta JSON `200` per l'endpoint `/api/oauth/usage`.
private let usageResponseData = Data("""
{
  "five_hour": { "utilization": 15, "resets_at": "2030-01-01T00:00:00Z" },
  "seven_day": { "utilization": 30, "resets_at": "2030-01-01T00:00:00Z" }
}
""".utf8)

// MARK: - Suite

// Serializzata: condivide il static handler di SelfRefreshMockURLProtocol tra le sotto-suite.
@Suite("ClaudeOAuthSelfRefresh", .tags(.networking), .serialized)
struct ClaudeOAuthSelfRefreshTests {

// MARK: - 1. patchedRawJSON (pure — zero rete, zero Keychain)

@Suite("patchedRawJSON")
struct PatchedRawJSONTests {

    @Test("preserva campi sconosciuti + aggiorna token + expiresAt in millisecondi")
    func preservesUnknownKeysAndUpdatesTokenFields() throws {
        // Arrange: JSON con un campo sconosciuto "isMax" a livello claudeAiOauth,
        // che la CLI potrebbe scrivere ma noi non modelliamo.
        let originalJSON = """
        {
          "claudeAiOauth": {
            "accessToken": "OLD_ACCESS",
            "refreshToken": "OLD_REFRESH",
            "expiresAt": 1700000000000,
            "subscriptionType": "max",
            "scopes": ["user:inference"],
            "rateLimitTier": "tier1",
            "isMax": true
          }
        }
        """
        let original = Data(originalJSON.utf8)

        let futureDate = Date(timeIntervalSince1970: 1_800_000_000)
        let refreshed = ClaudeOAuthCredentials(
            accessToken: "BRAND_NEW_ACCESS",
            refreshToken: "BRAND_NEW_REFRESH",
            expiresAt: futureDate,
            scopes: ["user:inference"],
            rateLimitTier: "tier1",
            subscriptionType: "max")

        // Act
        let patched = try #require(ClaudeOAuthCredentials.patchedRawJSON(original: original, refreshed: refreshed),
            "patchedRawJSON deve restituire dati non-nil per un JSON claudeAiOauth valido")

        let root = try #require(
            try? JSONSerialization.jsonObject(with: patched) as? [String: Any],
            "Output deve essere JSON valido")
        let oauth = try #require(root["claudeAiOauth"] as? [String: Any],
            "Root deve contenere la chiave claudeAiOauth")

        // Assert — campi rinnovati
        #expect(oauth["accessToken"] as? String == "BRAND_NEW_ACCESS",
            "accessToken deve essere aggiornato al valore rinnovato")
        #expect(oauth["refreshToken"] as? String == "BRAND_NEW_REFRESH",
            "refreshToken deve essere aggiornato al valore rinnovato")

        // expiresAt deve essere in millisecondi (valore atteso ≈ epoch_s * 1000)
        let expectedMs = Int((futureDate.timeIntervalSince1970 * 1000).rounded())
        let actualMs = try #require(oauth["expiresAt"] as? Int,
            "expiresAt deve essere un Int (millisecondi epoch)")
        #expect(actualMs == expectedMs,
            "expiresAt deve essere in millisecondi epoch, non secondi — atteso \(expectedMs), trovato \(actualMs)")

        // Assert — campi sibling preservati
        #expect(oauth["subscriptionType"] as? String == "max",
            "subscriptionType non deve essere toccato dal patch")
        #expect(oauth["rateLimitTier"] as? String == "tier1",
            "rateLimitTier non deve essere toccato dal patch")
        let scopes = oauth["scopes"] as? [String]
        #expect(scopes == ["user:inference"],
            "scopes non deve essere toccato dal patch")

        // Assert — campo sconosciuto preservato
        #expect(oauth["isMax"] as? Bool == true,
            "Il campo sconosciuto 'isMax' deve sopravvivere al patch intatto")
    }

    @Test("sostituisce refreshToken nel patch quando non-nil")
    func replacesRefreshTokenWhenNonNil() throws {
        let originalJSON = """
        {
          "claudeAiOauth": {
            "accessToken": "OLD_AT",
            "refreshToken": "OLD_RT",
            "expiresAt": 1700000000000
          }
        }
        """
        let refreshed = ClaudeOAuthCredentials(
            accessToken: "NEW_AT",
            refreshToken: "NEW_RT",
            expiresAt: Date().addingTimeInterval(3600),
            scopes: [],
            rateLimitTier: nil)

        let patched = try #require(ClaudeOAuthCredentials.patchedRawJSON(
            original: Data(originalJSON.utf8),
            refreshed: refreshed))

        let root = try JSONSerialization.jsonObject(with: patched) as? [String: Any]
        let oauth = try #require(root?["claudeAiOauth"] as? [String: Any])
        #expect(oauth["refreshToken"] as? String == "NEW_RT",
            "refreshToken rinnovato deve rimpiazzare quello precedente")
    }

    @Test("restituisce nil per JSON privo di claudeAiOauth")
    func returnsNilForMalformedJSON() {
        // JSON valido ma senza la chiave attesa: `patchedRawJSON` deve tornare nil.
        let wrongJSON = Data("{ \"someOtherKey\": { \"accessToken\": \"X\" } }".utf8)
        let refreshed = ClaudeOAuthCredentials(
            accessToken: "X", refreshToken: nil, expiresAt: nil,
            scopes: [], rateLimitTier: nil)

        let result = ClaudeOAuthCredentials.patchedRawJSON(original: wrongJSON, refreshed: refreshed)
        #expect(result == nil,
            "patchedRawJSON deve tornare nil quando claudeAiOauth è assente — non riscrivere dati parziali")
    }

    @Test("restituisce nil per dati non-JSON")
    func returnsNilForNonJSONData() {
        let garbage = Data("questo non è JSON!!!".utf8)
        let refreshed = ClaudeOAuthCredentials(
            accessToken: "X", refreshToken: nil, expiresAt: nil,
            scopes: [], rateLimitTier: nil)

        let result = ClaudeOAuthCredentials.patchedRawJSON(original: garbage, refreshed: refreshed)
        #expect(result == nil,
            "patchedRawJSON deve tornare nil per dati non-JSON")
    }

    @Test("restituisce nil se la credenziale rinnovata non ha expiresAt")
    func returnsNilWhenRefreshedHasNoExpiry() {
        // Senza scadenza nuova, riscrivere un accessToken fresco accanto all'expiresAt vecchio (già
        // passato) farebbe vedere il token come scaduto sia a noi sia alla CLI → loop. patchedRawJSON
        // deve rifiutare di scrivere dati incoerenti.
        let original = Data("""
        { "claudeAiOauth": { "accessToken": "OLD", "refreshToken": "RT", "expiresAt": 1700000000000 } }
        """.utf8)
        let refreshed = ClaudeOAuthCredentials(
            accessToken: "NEW", refreshToken: "RT2", expiresAt: nil,
            scopes: [], rateLimitTier: nil)

        let result = ClaudeOAuthCredentials.patchedRawJSON(original: original, refreshed: refreshed)
        #expect(result == nil,
            "patchedRawJSON deve tornare nil quando manca expiresAt — non riscrivere accessToken fresco + expiry stale")
    }
}

// MARK: - 2. Self-refresh happy path

@Suite("self-refresh — happy path")
struct SelfRefreshHappyPathTests {

    @Test("token CLI scaduto con refreshToken → rinnova, scrive, fetchUsage ha successo")
    func selfRefreshSucceedsAndWritesBack() async throws {
        // Arrange
        let writerSpy = CredentialWriterSpy(returns: true)
        // credentialReader ritorna sempre il token scaduto (il self-refresh gestisce il rinnovo,
        // non un reread del Keychain — quindi va bene un risultato singolo fisso).
        let readerSpy = CredentialReaderSpy(always: expiredCLIResult())

        // Le risposte HTTP in ordine di arrivo:
        //   1ª chiamata → POST platform.claude.com/v1/oauth/token (token refresh)
        //   2ª chiamata → GET api.anthropic.com/api/oauth/usage
        let box = SelfRefreshResponseBox([
            (200, tokenRefreshResponseData()),
            (200, usageResponseData),
        ])
        let session = makeSelfRefreshSession(box: box)

        let service = ClaudeLimitsService(
            session: session,
            environment: [:],
            credentialReader: readerSpy.reader,
            credentialWriter: writerSpy.writer)

        // Act
        let snapshot = try await service.fetchUsage(userInitiated: true)

        // Assert — fetch riuscito
        #expect(snapshot.source == .live,
            "fetchUsage deve restituire uno snapshot .live dopo il self-refresh riuscito")

        // Assert — write-back eseguito (pre-check + write-back = almeno 2 chiamate)
        #expect(writerSpy.callCount >= 2,
            "credentialWriter deve essere chiamato almeno 2 volte: pre-check + write-back finale")

        // Assert — l'ultimo payload scritto contiene il token rinnovato non-scaduto
        let lastWritten = try #require(writerSpy.writtenPayloads.last,
            "Deve esistere almeno un payload scritto nel write-back finale")
        let parsedBack = try ClaudeOAuthCredentials.parse(data: lastWritten)
        #expect(!parsedBack.isExpired,
            "Il token scritto nel write-back deve essere non-scaduto (il rinnovo ha funzionato)")
        #expect(parsedBack.accessToken == "NEW_AT",
            "Il write-back deve contenere il nuovo accessToken ricevuto dall'endpoint OAuth")
    }
}

// MARK: - 3. Pre-check failure guard (safety property)

@Suite("self-refresh — pre-check failure guard")
struct PreCheckFailureGuardTests {

    @Test("write pre-check fallisce → refreshDelegatedToCLI senza consumare il refresh_token")
    func noOAuthCallWhenPreCheckFails() async {
        // Arrange — writer ritorna false: il keychain nega la scrittura (es. ACL)
        let writerSpy = CredentialWriterSpy(returns: false)
        let readerSpy = CredentialReaderSpy(always: expiredCLIResult())

        // Il box registra le URL; se il mock viene chiamato per il token refresh,
        // il test fallisce. Configuriamo il mock a rispondere 500 a qualsiasi richiesta
        // (serve a distinguere "nessuna chiamata" da "chiamata avvenuta").
        let box = SelfRefreshResponseBox([(500, Data("should not be called".utf8))])
        let session = makeSelfRefreshSession(box: box)

        let service = ClaudeLimitsService(
            session: session,
            environment: [:],
            credentialReader: readerSpy.reader,
            credentialWriter: writerSpy.writer)

        // Act + Assert — deve lanciare (delega alla CLI)
        await #expect(throws: ClaudeLimitsError.refreshDelegatedToCLI) {
            _ = try await service.fetchUsage(userInitiated: true)
        }

        // Assert — il pre-check è fallito (esattamente 1 chiamata al writer), ma
        // l'endpoint OAuth di rinnovo token NON deve mai essere raggiunto.
        #expect(writerSpy.callCount == 1,
            "Solo il pre-check deve essere eseguito (1 chiamata al writer): il refresh_token non viene consumato")

        let oauthTokenURLHost = ClaudeTokenRefresher.endpoint.host ?? ""
        let hitOAuth = box.requestedURLs.contains { $0.host == oauthTokenURLHost }
        #expect(!hitOAuth,
            "L'endpoint OAuth /v1/oauth/token NON deve essere raggiunto quando il pre-check write fallisce — il refresh_token è prezioso e non va consumato senza garanzia di write-back")
    }
}

// MARK: - 4. Background path (userInitiated: false)

@Suite("self-refresh — background path")
struct BackgroundPathTests {

    @Test("background fetch con token CLI scaduto → refreshDelegatedToCLI, zero write, zero OAuth")
    func backgroundDoesNotAttemptSelfRefresh() async {
        // Arrange — writer non deve mai essere chiamato in background
        let writerSpy = CredentialWriterSpy(returns: true)
        let readerSpy = CredentialReaderSpy(always: expiredCLIResult())

        let box = SelfRefreshResponseBox([(500, Data("background must not reach oauth".utf8))])
        let session = makeSelfRefreshSession(box: box)

        let service = ClaudeLimitsService(
            session: session,
            environment: [:],
            credentialReader: readerSpy.reader,
            credentialWriter: writerSpy.writer)

        // Act + Assert
        await #expect(throws: ClaudeLimitsError.refreshDelegatedToCLI) {
            _ = try await service.fetchUsage(userInitiated: false)
        }

        // Assert — nessuna scrittura: il self-refresh è gated su `allowUI` = userInitiated
        #expect(writerSpy.callCount == 0,
            "In background (userInitiated: false) credentialWriter non deve mai essere chiamato")

        // Assert — l'endpoint OAuth non deve essere raggiunto in background
        let oauthTokenURLHost = ClaudeTokenRefresher.endpoint.host ?? ""
        let hitOAuth = box.requestedURLs.contains { $0.host == oauthTokenURLHost }
        #expect(!hitOAuth,
            "In background il self-refresh è disabilitato: l'endpoint OAuth /v1/oauth/token non deve essere raggiunto")
    }
}

} // fine suite radice ClaudeOAuthSelfRefreshTests

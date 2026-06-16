import Foundation

// Modello delle credenziali OAuth di Claude Code + parsing del JSON `claudeAiOauth`.
// Struttura verificata sul sistema reale (Keychain `Claude Code-credentials`):
//   { "claudeAiOauth": { "accessToken", "refreshToken", "expiresAt" (ms epoch),
//     "scopes": [...], "subscriptionType": "max", "rateLimitTier": "..." } }

/// Credenziali OAuth lette dal Keychain / file / env.
public struct ClaudeOAuthCredentials: Sendable, Equatable {
    public let accessToken: String
    public let refreshToken: String?
    /// Da `expiresAt` (ms epoch) / 1000.
    public let expiresAt: Date?
    public let scopes: [String]
    public let rateLimitTier: String?
    public let subscriptionType: String?

    public init(
        accessToken: String,
        refreshToken: String?,
        expiresAt: Date?,
        scopes: [String],
        rateLimitTier: String?,
        subscriptionType: String? = nil)
    {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.scopes = scopes
        self.rateLimitTier = rateLimitTier
        self.subscriptionType = subscriptionType
    }

    /// true se scaduto (o senza scadenza nota).
    public var isExpired: Bool {
        guard let expiresAt else { return true }
        return Date() >= expiresAt
    }

    public var expiresIn: TimeInterval? {
        expiresAt?.timeIntervalSinceNow
    }

    /// Parsa il JSON `claudeAiOauth`.
    public static func parse(data: Data) throws -> ClaudeOAuthCredentials {
        guard let root = try? JSONDecoder().decode(Root.self, from: data) else {
            throw ClaudeLimitsError.invalidResponse
        }
        guard let oauth = root.claudeAiOauth else {
            throw ClaudeLimitsError.noCredentials
        }
        let token = oauth.accessToken?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !token.isEmpty else {
            throw ClaudeLimitsError.noCredentials
        }
        let expiresAt = oauth.expiresAt.map { Date(timeIntervalSince1970: $0 / 1000.0) }
        return ClaudeOAuthCredentials(
            accessToken: token,
            refreshToken: oauth.refreshToken,
            expiresAt: expiresAt,
            scopes: oauth.scopes ?? [],
            rateLimitTier: oauth.rateLimitTier,
            subscriptionType: oauth.subscriptionType)
    }

    /// Riscrive il JSON GREZZO del Keychain patchando SOLO i campi rinnovati dell'oggetto
    /// `claudeAiOauth` (accessToken/refreshToken/expiresAt) e PRESERVANDO tutto il resto
    /// (scopes, subscriptionType, rateLimitTier e qualsiasi campo sconosciuto scritto dalla CLI).
    ///
    /// Serve al write-back del self-refresh: la CLI deve ritrovare un item INTEGRO, non i soli 3
    /// campi che parsiamo noi. Lavoriamo sul dizionario originale, non su `ClaudeOAuthCredentials`,
    /// proprio per non perdere i campi non modellati. `expiresAt` torna in ms-epoch come all'origine.
    /// - Returns: i nuovi byte JSON, o `nil` se l'originale non è il JSON atteso (write-back saltato).
    public static func patchedRawJSON(original: Data, refreshed: ClaudeOAuthCredentials) -> Data? {
        guard var root = (try? JSONSerialization.jsonObject(with: original)) as? [String: Any],
              var oauth = root["claudeAiOauth"] as? [String: Any]
        else { return nil }
        // Senza una scadenza nuova NON riscriviamo: un accessToken fresco accanto all'`expiresAt`
        // vecchio (già passato) farebbe vedere il token come scaduto sia a noi sia alla CLI → loop di
        // refresh. Oggi `refresh()` setta sempre un expiresAt futuro, ma il guard rende l'invariante esplicita.
        guard let exp = refreshed.expiresAt else { return nil }
        oauth["accessToken"] = refreshed.accessToken
        if let rt = refreshed.refreshToken { oauth["refreshToken"] = rt }
        oauth["expiresAt"] = Int((exp.timeIntervalSince1970 * 1000).rounded())
        root["claudeAiOauth"] = oauth
        return try? JSONSerialization.data(withJSONObject: root)
    }

    private struct Root: Decodable {
        let claudeAiOauth: OAuth?
    }

    private struct OAuth: Decodable {
        let accessToken: String?
        let refreshToken: String?
        let expiresAt: Double?
        let scopes: [String]?
        let rateLimitTier: String?
        let subscriptionType: String?
    }
}

/// Chi possiede le credenziali correnti (determina la regola di refresh).
public enum CredentialOwner: String, Sendable, Equatable {
    /// Lette dal Keychain/file di Claude Code CLI → NON refreshiamo noi (Claude ruota il refresh).
    case claudeCLI
    /// Salvate da noi (cache nostra) → possiamo refreshare direttamente.
    case claudeBar
    /// Da variabile d'ambiente (debug/test).
    case environment
}

/// Da dove arrivano le credenziali (per diagnostica / catena di lettura).
public enum CredentialSource: String, Sendable, Equatable {
    case environment
    case memoryCache
    case cacheKeychain
    case credentialsFile
    case claudeKeychain
}

/// Record completo: credenziali + proprietario + sorgente + account Keychain.
public struct CredentialRecord: Sendable, Equatable {
    public let credentials: ClaudeOAuthCredentials
    public let owner: CredentialOwner
    public let source: CredentialSource
    /// Account del Keychain (es. "martinovigiani"), se noto.
    public let accountLabel: String?

    public init(
        credentials: ClaudeOAuthCredentials,
        owner: CredentialOwner,
        source: CredentialSource,
        accountLabel: String? = nil)
    {
        self.credentials = credentials
        self.owner = owner
        self.source = source
        self.accountLabel = accountLabel
    }
}

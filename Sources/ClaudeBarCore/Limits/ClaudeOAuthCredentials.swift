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

import Foundation

// Credenziali OAuth di Codex / ChatGPT, lette dal file `~/.codex/auth.json` (o `$CODEX_HOME/auth.json`).
//
// A DIFFERENZA di Claude (token nel Keychain `Claude Code-credentials`), la CLI `codex` salva i
// token in un FILE in chiaro. Noi NON scriviamo segreti nostri su quel file: lo leggiamo soltanto.
// Se un giorno rinnoviamo un token, andrà nel NOSTRO Keychain (vincolo BRIEF), non qui.
//
// Shape verificata sull'upstream CodexBar (CodexOAuthCredentialsStore):
//   {
//     "OPENAI_API_KEY": "sk-…",            // "API key mode": se presente, usato come accessToken
//     "tokens": { "access_token", "refresh_token", "id_token", "account_id" },  // snake o camel
//     "last_refresh": "2026-05-01T10:00:00.000Z"   // ISO8601 (con o senza frazioni di secondo)
//   }

/// Credenziali OAuth Codex/ChatGPT lette da `auth.json`.
public struct CodexOAuthCredentials: Sendable, Equatable {
    public let accessToken: String
    public let refreshToken: String
    /// JWT con email/plan (`https://api.openai.com/auth.chatgpt_plan_type`, `…/profile.email`).
    public let idToken: String?
    /// Identificativo workspace ChatGPT → header `ChatGPT-Account-Id` (multi-account).
    public let accountId: String?
    /// Ultimo refresh noto (per la regola `needsRefresh`).
    public let lastRefresh: Date?

    public init(
        accessToken: String,
        refreshToken: String,
        idToken: String?,
        accountId: String?,
        lastRefresh: Date?)
    {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.idToken = idToken
        self.accountId = accountId
        self.lastRefresh = lastRefresh
    }

    /// true se è opportuno rinnovare: nessun `last_refresh` noto o più vecchio di 8 giorni
    /// (stessa soglia di CodexBar). Senza refresh token, il chiamante non rinnova comunque.
    public var needsRefresh: Bool {
        guard let lastRefresh else { return true }
        let eightDays: TimeInterval = 8 * 24 * 60 * 60
        return Date().timeIntervalSince(lastRefresh) > eightDays
    }
}

/// Errori della lettura/parse di `auth.json`.
public enum CodexOAuthCredentialsError: Error, Sendable, Equatable {
    case notFound
    case decodeFailed
    case missingTokens
}

extension CodexOAuthCredentialsError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notFound:
            "auth.json di Codex non trovato. Esegui `codex` per autenticarti."
        case .decodeFailed:
            "Impossibile decodificare le credenziali Codex (auth.json)."
        case .missingTokens:
            "auth.json di Codex presente ma senza token."
        }
    }
}

/// Lettore di `~/.codex/auth.json` (sola lettura: non scriviamo sul file della CLI).
public enum CodexOAuthCredentialsStore {
    /// Percorso del file credenziali: `$CODEX_HOME/auth.json` o `~/.codex/auth.json`.
    public static func authFileURL(
        env: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default) -> URL
    {
        CodexHomeScope.homeURL(env: env, fileManager: fileManager)
            .appendingPathComponent("auth.json")
    }

    /// Carica e fa il parse delle credenziali da `auth.json`. Lancia `CodexOAuthCredentialsError`.
    public static func load(
        env: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default) throws -> CodexOAuthCredentials
    {
        let url = self.authFileURL(env: env, fileManager: fileManager)
        guard fileManager.fileExists(atPath: url.path) else {
            throw CodexOAuthCredentialsError.notFound
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw CodexOAuthCredentialsError.notFound
        }
        return try self.parse(data: data)
    }

    /// Parsa i byte JSON di `auth.json` in `CodexOAuthCredentials`.
    public static func parse(data: Data) throws -> CodexOAuthCredentials {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw CodexOAuthCredentialsError.decodeFailed
        }

        // "API key mode": il file può contenere direttamente una OPENAI_API_KEY (niente tokens).
        if let apiKey = json["OPENAI_API_KEY"] as? String,
           !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return CodexOAuthCredentials(
                accessToken: apiKey.trimmingCharacters(in: .whitespacesAndNewlines),
                refreshToken: "",
                idToken: nil,
                accountId: nil,
                lastRefresh: nil)
        }

        guard let tokens = json["tokens"] as? [String: Any] else {
            throw CodexOAuthCredentialsError.missingTokens
        }
        guard let accessToken = Self.stringValue(in: tokens, "access_token", "accessToken"),
              !accessToken.isEmpty
        else {
            throw CodexOAuthCredentialsError.missingTokens
        }
        let refreshToken = Self.stringValue(in: tokens, "refresh_token", "refreshToken") ?? ""
        let idToken = Self.stringValue(in: tokens, "id_token", "idToken")
        let accountId = Self.stringValue(in: tokens, "account_id", "accountId")
        let lastRefresh = Self.parseLastRefresh(json["last_refresh"])

        return CodexOAuthCredentials(
            accessToken: accessToken,
            refreshToken: refreshToken,
            idToken: idToken,
            accountId: accountId,
            lastRefresh: lastRefresh)
    }

    // MARK: - Helpers

    private static func stringValue(in dict: [String: Any], _ snakeKey: String, _ camelKey: String) -> String? {
        if let value = dict[snakeKey] as? String, !value.isEmpty { return value }
        if let value = dict[camelKey] as? String, !value.isEmpty { return value }
        return nil
    }

    private static func parseLastRefresh(_ raw: Any?) -> Date? {
        guard let value = raw as? String, !value.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
}

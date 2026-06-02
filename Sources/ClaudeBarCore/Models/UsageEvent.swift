import Foundation

// Evento di consumo normalizzato, estratto da una riga `assistant` di un transcript `.jsonl`.
// Verificato sul sistema reale dell'utente: chiavi top-level `cwd, gitBranch, isSidechain,
// message, requestId, sessionId, timestamp, type, uuid, version`; `message.usage` con
// `input_tokens, cache_creation_input_tokens, cache_read_input_tokens, output_tokens,
// cache_creation { ephemeral_1h_input_tokens, ephemeral_5m_input_tokens }, service_tier`.

/// Un evento di consumo (una risposta assistant) normalizzato e deduplicabile.
///
/// `Codable` perché viene persistito nell'indice incrementale per-file su disco.
public struct UsageEvent: Sendable, Equatable, Codable {
    /// Timestamp della riga (da `timestamp` ISO8601).
    public var timestamp: Date
    /// Chiave giorno "yyyy-MM-dd" in TZ locale (per il rollup giornaliero).
    public var dayKey: String
    /// Model id **normalizzato** (vedi `ModelNormalizer`).
    public var model: String
    /// Model id originale (per debug / mapping pricing alternativo).
    public var rawModel: String
    /// Percorso progetto (da `cwd`).
    public var projectPath: String
    public var sessionId: String?
    public var messageId: String?
    public var requestId: String?
    public var gitBranch: String?
    public var isSidechain: Bool
    /// Indica se la riga proviene da una sessione subagent (path contiene `/subagents/`).
    public var isSubagent: Bool

    // Token (sempre >= 0).
    public var input: Int
    public var cacheRead: Int
    /// Cache-write 1h (da `cache_creation.ephemeral_1h_input_tokens`) — più preciso di CodexBar.
    public var cacheCreate1h: Int
    /// Cache-write 5m (da `cache_creation.ephemeral_5m_input_tokens`).
    public var cacheCreate5m: Int
    public var output: Int

    public init(
        timestamp: Date,
        dayKey: String,
        model: String,
        rawModel: String,
        projectPath: String,
        sessionId: String?,
        messageId: String?,
        requestId: String?,
        gitBranch: String?,
        isSidechain: Bool,
        isSubagent: Bool,
        input: Int,
        cacheRead: Int,
        cacheCreate1h: Int,
        cacheCreate5m: Int,
        output: Int)
    {
        self.timestamp = timestamp
        self.dayKey = dayKey
        self.model = model
        self.rawModel = rawModel
        self.projectPath = projectPath
        self.sessionId = sessionId
        self.messageId = messageId
        self.requestId = requestId
        self.gitBranch = gitBranch
        self.isSidechain = isSidechain
        self.isSubagent = isSubagent
        self.input = input
        self.cacheRead = cacheRead
        self.cacheCreate1h = cacheCreate1h
        self.cacheCreate5m = cacheCreate5m
        self.output = output
    }

    /// Chiave di dedup in-file: `"messageId:requestId"` se entrambi presenti, altrimenti `nil`.
    /// Le righe senza ID sono trattate come distinte (mai scartate).
    public var dedupKey: String? {
        guard let messageId, let requestId else { return nil }
        return "\(messageId):\(requestId)"
    }

    /// Totale cache-write (1h + 5m).
    public var cacheCreateTotal: Int { cacheCreate1h + cacheCreate5m }

    /// Totale token contati per questo evento.
    public var totalTokens: Int { input + cacheRead + cacheCreate1h + cacheCreate5m + output }
}

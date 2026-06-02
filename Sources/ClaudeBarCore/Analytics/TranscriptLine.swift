import Foundation

// Decodifica di una riga `assistant` di transcript in `UsageEvent`.
// Usa JSONSerialization (come CodexBar) per tollerare campi extra/variabili.
// Chiavi verificate sul sistema reale dell'utente.

enum TranscriptLine {
    /// Formatter per il `dayKey` "yyyy-MM-dd" in TZ locale.
    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// Decodifica una riga (già filtrata `assistant`+`usage`) in `UsageEvent`.
    /// Ritorna `nil` se la riga non è un assistant valido con token > 0.
    static func decode(_ bytes: Data) -> UsageEvent? {
        guard
            let obj = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any],
            (obj["type"] as? String) == "assistant"
        else { return nil }

        guard let tsText = obj["timestamp"] as? String,
              let timestamp = ClaudeUsageEndpoint.parseISO8601(tsText)
        else { return nil }

        guard let message = obj["message"] as? [String: Any],
              let rawModel = message["model"] as? String,
              let usage = message["usage"] as? [String: Any]
        else { return nil }

        let input = intValue(usage["input_tokens"])
        let cacheRead = intValue(usage["cache_read_input_tokens"])
        let cacheCreateLegacy = intValue(usage["cache_creation_input_tokens"])
        let output = intValue(usage["output_tokens"])

        // Split 1h/5m da `cache_creation`; se assente (log vecchi) → tutto su 5m (prezzo conservativo).
        var cache1h = 0
        var cache5m = 0
        if let cc = usage["cache_creation"] as? [String: Any] {
            cache1h = intValue(cc["ephemeral_1h_input_tokens"])
            cache5m = intValue(cc["ephemeral_5m_input_tokens"])
        } else {
            cache5m = cacheCreateLegacy
        }

        if input == 0, cacheRead == 0, cache1h == 0, cache5m == 0, output == 0 { return nil }

        let model = ModelNormalizer.normalize(rawModel)
        let cwd = obj["cwd"] as? String ?? ""
        let sessionId = (obj["sessionId"] as? String) ?? (obj["session_id"] as? String)
        let messageId = message["id"] as? String
        let requestId = obj["requestId"] as? String
        let gitBranch = obj["gitBranch"] as? String
        let isSidechain = boolValue(obj["isSidechain"])

        return UsageEvent(
            timestamp: timestamp,
            dayKey: dayFormatter.string(from: timestamp),
            model: model,
            rawModel: rawModel,
            projectPath: cwd,
            sessionId: sessionId,
            messageId: messageId,
            requestId: requestId,
            gitBranch: gitBranch,
            isSidechain: isSidechain,
            isSubagent: false, // impostato dal chiamante in base al path file.
            input: max(0, input),
            cacheRead: max(0, cacheRead),
            cacheCreate1h: max(0, cache1h),
            cacheCreate5m: max(0, cache5m),
            output: max(0, output))
    }

    private static func intValue(_ any: Any?) -> Int {
        switch any {
        case let n as Int: n
        case let n as Double: Int(n)
        case let n as NSNumber: n.intValue
        case let s as String: Int(s) ?? 0
        default: 0
        }
    }

    private static func boolValue(_ any: Any?) -> Bool {
        switch any {
        case let b as Bool: b
        case let n as NSNumber: n.boolValue
        default: false
        }
    }
}

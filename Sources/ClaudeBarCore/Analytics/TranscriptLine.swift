import Foundation

// Decodifica di una riga `assistant` di transcript in `UsageEvent`.
// Usa Codable tipizzato (JSONDecoder) sui soli campi necessari: niente boxing
// Foundation `[String: Any]` per riga — è il punto caldo del full-index a freddo.
// La decodifica per-campo resta lenient come il vecchio JSONSerialization+cast:
// un campo opzionale con tipo inatteso non scarta la riga.
// Chiavi verificate sul sistema reale dell'utente.

enum TranscriptLine {
    private static let decoder = JSONDecoder()

    /// Decodifica una riga (già filtrata `assistant`+`usage`) in `UsageEvent`.
    /// Ritorna `nil` se la riga non è un assistant valido con token > 0.
    static func decode(_ bytes: Data) -> UsageEvent? {
        guard
            let line = try? decoder.decode(RawLine.self, from: bytes),
            line.type == "assistant",
            let tsText = line.timestamp,
            let timestamp = parseTimestamp(tsText),
            let message = line.message,
            let rawModel = message.model,
            let usage = message.usage
        else { return nil }

        let input = usage.inputTokens
        let cacheRead = usage.cacheReadInputTokens
        let output = usage.outputTokens

        // Split 1h/5m da `cache_creation`; se assente (log vecchi) → tutto su 5m (prezzo conservativo).
        var cache1h = 0
        var cache5m = 0
        if let cc = usage.cacheCreation {
            cache1h = cc.ephemeral1hInputTokens
            cache5m = cc.ephemeral5mInputTokens
        } else {
            cache5m = usage.cacheCreationInputTokens
        }

        if input == 0, cacheRead == 0, cache1h == 0, cache5m == 0, output == 0 { return nil }

        return UsageEvent(
            timestamp: timestamp,
            dayKey: dayKey(for: timestamp),
            model: ModelNormalizer.normalize(rawModel),
            rawModel: rawModel,
            projectPath: line.cwd ?? "",
            sessionId: line.sessionId ?? line.sessionIdSnake,
            messageId: message.id,
            requestId: line.requestId,
            gitBranch: line.gitBranch,
            isSidechain: line.isSidechain,
            isSubagent: false, // impostato dal chiamante in base al path file.
            input: max(0, input),
            cacheRead: max(0, cacheRead),
            cacheCreate1h: max(0, cache1h),
            cacheCreate5m: max(0, cache5m),
            output: max(0, output))
    }

    // MARK: - Date senza ICU

    // I formatter Foundation/ICU costano troppo per-riga sul full-index (creazione
    // `ISO8601DateFormatter` + format ICU dominavano il profilo). I timestamp dei
    // transcript sono macchina-generati `yyyy-MM-ddTHH:mm:ss[.fff](Z|±hh:mm)`:
    // parse aritmetico diretto, fallback al formatter condiviso per shape inattese.

    /// Parsa il timestamp ISO8601 della riga (fast-path manuale, fallback formatter).
    static func parseTimestamp(_ s: String) -> Date? {
        fastParseISO8601(s) ?? ClaudeUsageEndpoint.parseISO8601(s)
    }

    /// Chiave giorno "yyyy-MM-dd" in TZ locale, equivalente al vecchio DateFormatter
    /// (en_US_POSIX, calendario gregoriano).
    static func dayKey(for date: Date) -> String {
        let offset = TimeZone.current.secondsFromGMT(for: date)
        let secs = Int(date.timeIntervalSince1970.rounded(.down)) + offset
        let days = secs >= 0 ? secs / 86400 : (secs - 86399) / 86400
        let (y, m, d) = civilFromDays(days)

        var out = [UInt8](repeating: 0x30, count: 10)
        var year = y
        for i in stride(from: 3, through: 0, by: -1) {
            out[i] = 0x30 + UInt8(year % 10)
            year /= 10
        }
        out[4] = 0x2D // -
        out[5] = 0x30 + UInt8(m / 10)
        out[6] = 0x30 + UInt8(m % 10)
        out[7] = 0x2D
        out[8] = 0x30 + UInt8(d / 10)
        out[9] = 0x30 + UInt8(d % 10)
        return String(decoding: out, as: UTF8.self)
    }

    /// Parse manuale di `yyyy-MM-ddTHH:mm:ss[.frazione](Z|±hh:mm)`.
    /// Ritorna `nil` (→ fallback formatter) per qualunque deviazione dal formato.
    private static func fastParseISO8601(_ s: String) -> Date? {
        let b = Array(s.utf8)
        guard b.count >= 20 else { return nil }

        func digit(_ i: Int) -> Int? {
            let c = b[i]
            guard c >= 0x30, c <= 0x39 else { return nil }
            return Int(c - 0x30)
        }
        func num2(_ i: Int) -> Int? {
            guard let a = digit(i), let c = digit(i + 1) else { return nil }
            return a * 10 + c
        }

        guard
            let y1 = num2(0), let y2 = num2(2),
            b[4] == 0x2D, let month = num2(5),
            b[7] == 0x2D, let day = num2(8),
            b[10] == 0x54, // T
            let hour = num2(11), b[13] == 0x3A,
            let minute = num2(14), b[16] == 0x3A,
            let second = num2(17)
        else { return nil }
        let year = y1 * 100 + y2
        guard (1...12).contains(month), (1...31).contains(day),
              hour < 24, minute < 60, second < 60 else { return nil }

        var i = 19
        var fraction = 0.0
        if i < b.count, b[i] == 0x2E { // .
            i += 1
            var scale = 0.1
            var digits = 0
            while i < b.count, let d = digit(i) {
                fraction += Double(d) * scale
                scale /= 10
                digits += 1
                i += 1
            }
            guard digits > 0 else { return nil }
        }

        var tzOffset = 0
        if i < b.count, b[i] == 0x5A { // Z
            i += 1
        } else if i + 5 < b.count, b[i] == 0x2B || b[i] == 0x2D { // +/-
            let sign = b[i] == 0x2B ? 1 : -1
            guard let oh = num2(i + 1), b[i + 3] == 0x3A, let om = num2(i + 4),
                  oh < 24, om < 60 else { return nil }
            tzOffset = sign * (oh * 3600 + om * 60)
            i += 6
        } else {
            return nil
        }
        guard i == b.count else { return nil }

        let days = daysFromCivil(year: year, month: month, day: day)
        let unix = Double(days * 86400 + hour * 3600 + minute * 60 + second - tzOffset)
        return Date(timeIntervalSince1970: unix + fraction)
    }

    /// Giorni dal 1970-01-01 per una data civile gregoriana (algoritmo Hinnant).
    private static func daysFromCivil(year: Int, month: Int, day: Int) -> Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let doy = (153 * (month > 2 ? month - 3 : month + 9) + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146097 + doe - 719468
    }

    /// Inversa di `daysFromCivil` (algoritmo Hinnant).
    private static func civilFromDays(_ days: Int) -> (year: Int, month: Int, day: Int) {
        let z = days + 719468
        let era = (z >= 0 ? z : z - 146096) / 146097
        let doe = z - era * 146097
        let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let day = doy - (153 * mp + 2) / 5 + 1
        let month = mp < 10 ? mp + 3 : mp - 9
        return (yoe + era * 400 + (month <= 2 ? 1 : 0), month, day)
    }

    // MARK: - Shape tipizzata (solo i campi estratti)

    private struct RawLine: Decodable {
        let type: String?
        let timestamp: String?
        let cwd: String?
        let sessionId: String?
        let sessionIdSnake: String?
        let requestId: String?
        let gitBranch: String?
        let isSidechain: Bool
        let message: RawMessage?

        enum CodingKeys: String, CodingKey {
            case type, timestamp, cwd, sessionId, requestId, gitBranch, isSidechain, message
            case sessionIdSnake = "session_id"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.type = try? c.decode(String.self, forKey: .type)
            self.timestamp = try? c.decode(String.self, forKey: .timestamp)
            self.cwd = try? c.decode(String.self, forKey: .cwd)
            self.sessionId = try? c.decode(String.self, forKey: .sessionId)
            self.sessionIdSnake = try? c.decode(String.self, forKey: .sessionIdSnake)
            self.requestId = try? c.decode(String.self, forKey: .requestId)
            self.gitBranch = try? c.decode(String.self, forKey: .gitBranch)
            self.isSidechain = lenientBool(c, .isSidechain)
            self.message = try? c.decode(RawMessage.self, forKey: .message)
        }
    }

    private struct RawMessage: Decodable {
        let id: String?
        let model: String?
        let usage: RawUsage?

        enum CodingKeys: String, CodingKey { case id, model, usage }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.id = try? c.decode(String.self, forKey: .id)
            self.model = try? c.decode(String.self, forKey: .model)
            self.usage = try? c.decode(RawUsage.self, forKey: .usage)
        }
    }

    private struct RawUsage: Decodable {
        let inputTokens: Int
        let cacheReadInputTokens: Int
        let cacheCreationInputTokens: Int
        let outputTokens: Int
        let cacheCreation: RawCacheCreation?

        enum CodingKeys: String, CodingKey {
            case inputTokens = "input_tokens"
            case cacheReadInputTokens = "cache_read_input_tokens"
            case cacheCreationInputTokens = "cache_creation_input_tokens"
            case outputTokens = "output_tokens"
            case cacheCreation = "cache_creation"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.inputTokens = lenientInt(c, .inputTokens)
            self.cacheReadInputTokens = lenientInt(c, .cacheReadInputTokens)
            self.cacheCreationInputTokens = lenientInt(c, .cacheCreationInputTokens)
            self.outputTokens = lenientInt(c, .outputTokens)
            self.cacheCreation = try? c.decode(RawCacheCreation.self, forKey: .cacheCreation)
        }
    }

    private struct RawCacheCreation: Decodable {
        let ephemeral1hInputTokens: Int
        let ephemeral5mInputTokens: Int

        enum CodingKeys: String, CodingKey {
            case ephemeral1hInputTokens = "ephemeral_1h_input_tokens"
            case ephemeral5mInputTokens = "ephemeral_5m_input_tokens"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.ephemeral1hInputTokens = lenientInt(c, .ephemeral1hInputTokens)
            self.ephemeral5mInputTokens = lenientInt(c, .ephemeral5mInputTokens)
        }
    }
}

// Decodifica lenient per-campo, semantica identica ai vecchi helper `intValue`/`boolValue`
// su JSONSerialization: tipo inatteso o chiave assente → default, mai errore propagato.

private func lenientInt<K: CodingKey>(_ c: KeyedDecodingContainer<K>, _ key: K) -> Int {
    if let n = try? c.decode(Int.self, forKey: key) { return n }
    if let n = try? c.decode(Double.self, forKey: key) { return Int(n) }
    if let s = try? c.decode(String.self, forKey: key) { return Int(s) ?? 0 }
    return 0
}

private func lenientBool<K: CodingKey>(_ c: KeyedDecodingContainer<K>, _ key: K) -> Bool {
    if let b = try? c.decode(Bool.self, forKey: key) { return b }
    if let n = try? c.decode(Int.self, forKey: key) { return n != 0 }
    if let n = try? c.decode(Double.self, forKey: key) { return n != 0 }
    return false
}

import Foundation
import Testing
@testable import ClaudeBarCore

// Parsing riga assistant + dedup in-file/cross-file + decode OAuth usage.

@Suite("Analytics parsing & dedup")
struct AnalyticsParsingTests {
    /// Riga reale (semplificata) con cache_creation split 1h/5m.
    private let assistantLine = #"""
    {"type":"assistant","timestamp":"2026-05-30T10:00:00.000Z","cwd":"/Users/x/proj","gitBranch":"main","isSidechain":false,"requestId":"req_1","sessionId":"sess_1","message":{"id":"msg_1","model":"claude-opus-4-7","usage":{"input_tokens":6,"cache_creation_input_tokens":42400,"cache_read_input_tokens":0,"output_tokens":1554,"cache_creation":{"ephemeral_1h_input_tokens":42400,"ephemeral_5m_input_tokens":0},"service_tier":"standard"}}}
    """#

    @Test("Decodifica una riga assistant con split cache 1h/5m")
    func decodeAssistant() throws {
        let event = try #require(TranscriptLine.decode(Data(assistantLine.utf8)))
        #expect(event.model == "claude-opus-4-7")
        #expect(event.input == 6)
        #expect(event.output == 1554)
        #expect(event.cacheCreate1h == 42400)
        #expect(event.cacheCreate5m == 0)
        #expect(event.dedupKey == "msg_1:req_1")
        #expect(event.projectPath == "/Users/x/proj")
    }

    @Test("Riga senza usage utile (tutti zero) → scartata")
    func zeroUsageRejected() {
        let line = #"{"type":"assistant","timestamp":"2026-05-30T10:00:00Z","message":{"model":"claude-opus-4-7","usage":{"input_tokens":0,"output_tokens":0,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}"#
        #expect(TranscriptLine.decode(Data(line.utf8)) == nil)
    }

    @Test("cache_creation assente → tutto su 5m (fallback conservativo)")
    func legacyCacheFallback() throws {
        let line = #"{"type":"assistant","timestamp":"2026-05-30T10:00:00Z","cwd":"/p","message":{"model":"claude-opus-4-7","usage":{"input_tokens":1,"output_tokens":1,"cache_read_input_tokens":0,"cache_creation_input_tokens":1000}}}"#
        let event = try #require(TranscriptLine.decode(Data(line.utf8)))
        #expect(event.cacheCreate5m == 1000)
        #expect(event.cacheCreate1h == 0)
    }

    @Test("Dedup cross-file: vince il record subagent")
    func crossFileWinnerSubagent() {
        func event(subagent: Bool) -> UsageEvent {
            UsageEvent(
                timestamp: Date(), dayKey: "2026-05-30", model: "claude-opus-4-7", rawModel: "claude-opus-4-7",
                projectPath: "/p", sessionId: "s", messageId: "msg_1", requestId: "req_1",
                gitBranch: nil, isSidechain: false, isSubagent: subagent,
                input: 10, cacheRead: 0, cacheCreate1h: 0, cacheCreate5m: 0, output: 5)
        }
        let states = [
            FileState(path: "/a/parent.jsonl", size: 1, mtimeMs: 1, inode: 1, parsedBytes: 1, events: [event(subagent: false)]),
            FileState(path: "/a/subagents/sub.jsonl", size: 1, mtimeMs: 1, inode: 2, parsedBytes: 1, events: [event(subagent: true)]),
        ]
        let deduped = TranscriptIndexer.dedupCrossFile(states: states)
        #expect(deduped.count == 1)            // stesso dedupKey → un solo vincitore.
        #expect(deduped.first?.isSubagent == true)
    }

    @Test("Eventi senza dedupKey sono tutti distinti")
    func unkeyedAreDistinct() {
        func event() -> UsageEvent {
            UsageEvent(
                timestamp: Date(), dayKey: "2026-05-30", model: "claude-opus-4-7", rawModel: "claude-opus-4-7",
                projectPath: "/p", sessionId: nil, messageId: nil, requestId: nil,
                gitBranch: nil, isSidechain: false, isSubagent: false,
                input: 1, cacheRead: 0, cacheCreate1h: 0, cacheCreate5m: 0, output: 1)
        }
        let states = [FileState(path: "/a.jsonl", size: 1, mtimeMs: 1, inode: 1, parsedBytes: 1, events: [event(), event()])]
        #expect(TranscriptIndexer.dedupCrossFile(states: states).count == 2)
    }

    @Test("Aggregazione: synthetic conta i token ma non il costo")
    func syntheticNoCost() {
        let synthetic = UsageEvent(
            timestamp: Date(), dayKey: "2026-05-30", model: "<synthetic>", rawModel: "<synthetic>",
            projectPath: "/p", sessionId: "s", messageId: nil, requestId: nil,
            gitBranch: nil, isSidechain: false, isSubagent: false,
            input: 100, cacheRead: 0, cacheCreate1h: 0, cacheCreate5m: 0, output: 0)
        let report = CostCalculator.build(events: [synthetic])
        #expect(report.totals.input == 100)
        #expect(report.totals.costUSD == nil) // nessun costo: solo synthetic.
    }

    @Test("Delta costo: ultimi 7g vs 7 precedenti → +100% se il corrente è il doppio")
    func costDeltaLast7vsPrev7() throws {
        let cal = Calendar.current
        let now = Date()
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX"); fmt.timeZone = .current; fmt.dateFormat = "yyyy-MM-dd"
        func dayKey(_ daysAgo: Int) -> String {
            fmt.string(from: cal.date(byAdding: .day, value: -daysAgo, to: cal.startOfDay(for: now))!)
        }
        func event(daysAgo: Int, input: Int) -> UsageEvent {
            UsageEvent(
                timestamp: cal.date(byAdding: .day, value: -daysAgo, to: now)!,
                dayKey: dayKey(daysAgo), model: "claude-opus-4-7", rawModel: "claude-opus-4-7",
                projectPath: "/p", sessionId: "s", messageId: "m\(daysAgo)", requestId: "r\(daysAgo)",
                gitBranch: nil, isSidechain: false, isSubagent: false,
                input: input, cacheRead: 0, cacheCreate1h: 0, cacheCreate5m: 0, output: 0)
        }
        // corrente (giorno 1): 2M input; precedente (giorno 10): 1M input. Costo ∝ input.
        let report = CostCalculator.build(
            events: [event(daysAgo: 1, input: 2_000_000), event(daysAgo: 10, input: 1_000_000)], now: now)
        #expect(report.previousPeriodCostUSD != nil)
        let delta = try #require(report.costDeltaPercent)
        #expect(abs(delta - 1.0) < 1e-6) // (2-1)/1 = +100%.
    }

    @Test("Delta costo: senza periodo precedente → nil")
    func costDeltaNoPrevious() {
        let cal = Calendar.current
        let now = Date()
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX"); fmt.timeZone = .current; fmt.dateFormat = "yyyy-MM-dd"
        let key = fmt.string(from: cal.startOfDay(for: now))
        let e = UsageEvent(
            timestamp: now, dayKey: key, model: "claude-opus-4-7", rawModel: "claude-opus-4-7",
            projectPath: "/p", sessionId: "s", messageId: "m", requestId: "r",
            gitBranch: nil, isSidechain: false, isSubagent: false,
            input: 1000, cacheRead: 0, cacheCreate1h: 0, cacheCreate5m: 0, output: 0)
        let report = CostCalculator.build(events: [e], now: now)
        #expect(report.previousPeriodCostUSD == nil)
        #expect(report.costDeltaPercent == nil)
    }
}

@Suite("OAuth usage decode")
struct OAuthUsageDecodeTests {
    @Test("Decodifica la shape reale dell'endpoint usage")
    func decodeUsage() throws {
        let json = #"""
        {"five_hour":{"utilization":17.0,"resets_at":"2026-06-01T22:30:00Z"},
         "seven_day":{"utilization":3.0,"resets_at":"2026-06-03T09:00:00Z"},
         "seven_day_opus":{"utilization":5.0,"resets_at":"2026-06-03T09:00:00Z"},
         "extra_usage":{"is_enabled":false,"utilization":0.0}}
        """#
        let r = try JSONDecoder().decode(OAuthUsageResponse.self, from: Data(json.utf8))
        #expect(r.fiveHour?.utilization == 17.0)
        #expect(r.sevenDay?.utilization == 3.0)
        #expect(r.sevenDayOpus?.utilization == 5.0)
        #expect(r.sevenDaySonnet == nil)
        #expect(r.extraUsage?.isEnabled == false)
        #expect(ClaudeUsageEndpoint.parseISO8601(r.fiveHour?.resetsAt) != nil)
    }

    @Test("Credenziali: parse del JSON claudeAiOauth")
    func parseCredentials() throws {
        let json = #"{"claudeAiOauth":{"accessToken":"tok","refreshToken":"rt","expiresAt":1730000000000,"scopes":["user:inference"],"subscriptionType":"max"}}"#
        let creds = try ClaudeOAuthCredentials.parse(data: Data(json.utf8))
        #expect(creds.accessToken == "tok")
        #expect(creds.refreshToken == "rt")
        #expect(creds.subscriptionType == "max")
        #expect(creds.expiresAt == Date(timeIntervalSince1970: 1_730_000_000))
    }
}

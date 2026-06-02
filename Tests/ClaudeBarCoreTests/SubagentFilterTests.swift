import Foundation
import Testing
@testable import ClaudeBarCore

// Effetto reale del flag "Includi le sessioni subagent" (Impostazioni → Analytics, SET-3):
// `CostCalculator.build(events:includeSubagents:)` esclude gli eventi `isSubagent` quando il
// flag è `false`. Default `true` = comportamento storico (nessuna regressione).

@Suite("CostCalculator — filtro subagent")
struct SubagentFilterTests {
    /// Evento di test con token noti e flag subagent parametrico (no dedupKey → tutti distinti).
    private func event(subagent: Bool, output: Int) -> UsageEvent {
        UsageEvent(
            timestamp: Date(), dayKey: "2026-05-30", model: "claude-opus-4-7", rawModel: "claude-opus-4-7",
            projectPath: "/p", sessionId: "s", messageId: nil, requestId: nil,
            gitBranch: nil, isSidechain: false, isSubagent: subagent,
            input: 10, cacheRead: 0, cacheCreate1h: 0, cacheCreate5m: 0, output: output)
    }

    @Test("includeSubagents = true (default) include gli eventi subagent")
    func includesSubagentsByDefault() {
        let events = [event(subagent: false, output: 5), event(subagent: true, output: 7)]
        let report = CostCalculator.build(events: events)
        // Token = (10+5) + (10+7) = 32.
        #expect(report.totals.totalTokens == 32)
    }

    @Test("includeSubagents = false esclude gli eventi subagent dagli aggregati")
    func excludesSubagentsWhenOff() {
        let events = [event(subagent: false, output: 5), event(subagent: true, output: 7)]
        let report = CostCalculator.build(events: events, includeSubagents: false)
        // Resta solo l'evento NON-subagent: 10+5 = 15.
        #expect(report.totals.totalTokens == 15)
    }

    @Test("includeSubagents = false con SOLI eventi subagent → report vuoto")
    func allSubagentsExcludedYieldsEmpty() {
        let events = [event(subagent: true, output: 5), event(subagent: true, output: 7)]
        let report = CostCalculator.build(events: events, includeSubagents: false)
        #expect(report.totals.totalTokens == 0)
        #expect(report.byModel.isEmpty)
    }
}

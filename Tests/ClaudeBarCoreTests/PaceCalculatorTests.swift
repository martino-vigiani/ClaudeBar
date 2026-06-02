import Foundation
import Testing
@testable import ClaudeBarCore

// Pace & Forecast — formula da DECISIONS.md §Pace.

@Suite("PaceCalculator")
struct PaceCalculatorTests {
    /// Reset tra 1 ora → metà finestra 5h già trascorsa (windowStart = now - 4h).
    private var now: Date { Date(timeIntervalSince1970: 1_700_000_000) }
    private var resetsIn1h: Date { now.addingTimeInterval(3600) } // 4h trascorse su 5h.

    @Test("Sopra ritmo: usato 90% a 80% del tempo → over + ETA prima del reset")
    func overPace() throws {
        let p = try #require(PaceCalculator.project(
            kind: .fiveHour, utilization: 90, resetsAt: resetsIn1h, now: now))
        #expect(abs(p.paceMarker - 0.8) < 0.001) // 4h/5h.
        #expect(p.isOverPace)
        #expect(p.rhythm == .over)
        let eta = try #require(p.etaToEmpty)
        #expect(eta < resetsIn1h)             // esaurisci prima del reset.
        #expect(!p.reachesResetWithMargin)
    }

    @Test("Sotto ritmo: usato 10% a 80% del tempo → under + arrivi al reset con margine")
    func underPace() throws {
        let p = try #require(PaceCalculator.project(
            kind: .fiveHour, utilization: 10, resetsAt: resetsIn1h, now: now))
        #expect(!p.isOverPace)
        #expect(p.rhythm == .under)
        #expect(p.etaToEmpty == nil)
        #expect(p.reachesResetWithMargin)
    }

    @Test("In linea entro la tolleranza → onTrack")
    func onTrack() throws {
        // 80% usato a 80% del tempo (delta 0 < tolleranza).
        let p = try #require(PaceCalculator.project(
            kind: .fiveHour, utilization: 80, resetsAt: resetsIn1h, now: now))
        #expect(p.rhythm == .onTrack)
    }

    @Test("Senza resetsAt non c'è pace")
    func noResetNoPace() {
        #expect(PaceCalculator.project(kind: .fiveHour, utilization: 50, resetsAt: nil, now: now) == nil)
    }

    @Test("Già esaurito (100%) → ETA = adesso")
    func alreadyEmpty() throws {
        let p = try #require(PaceCalculator.project(
            kind: .fiveHour, utilization: 100, resetsAt: resetsIn1h, now: now))
        #expect(p.etaToEmpty == now)
        #expect(!p.reachesResetWithMargin)
    }
}

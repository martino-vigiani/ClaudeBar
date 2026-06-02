import ClaudeBarCore
import Foundation

// ClaudeBarCLI — DEV-TOOL interno (NON nel bundle, NON distribuito).
// Scopo: dumpare l'AnalyticsReport per validare parser .jsonl + calcolo costi
// contro `ccusage` / `claude /usage` (criterio di accettazione MVP).
//
// Uso:
//   swift run ClaudeBarCLI            → indicizza ~/.claude/projects e stampa il report
//   swift run ClaudeBarCLI --json     → output JSON del report
//   swift run ClaudeBarCLI --limits   → fetch dei limiti ufficiali (Keychain + OAuth)

func formatUSD(_ value: Double?) -> String {
    guard let value else { return "n/d" }
    return String(format: "$%.2f", value)
}

func formatInt(_ value: Int) -> String {
    let f = NumberFormatter()
    f.numberStyle = .decimal
    return f.string(from: NSNumber(value: value)) ?? "\(value)"
}

func dumpReport(_ report: AnalyticsReport, json: Bool) {
    if json {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(report), let s = String(data: data, encoding: .utf8) {
            print(s)
        }
        return
    }

    let t = report.totals
    print("=== ClaudeBar — Analytics report ===")
    print("Generato: \(report.generatedAt)")
    print("")
    print("TOTALI (stima API-equivalente\(report.costEstimated ? ", include alias stimati" : "")):")
    print("  input:        \(formatInt(t.input))")
    print("  output:       \(formatInt(t.output))")
    print("  cache read:   \(formatInt(t.cacheRead))")
    print("  cache 5m:     \(formatInt(t.cacheWrite5m))")
    print("  cache 1h:     \(formatInt(t.cacheWrite1h))")
    print("  TOTALE token: \(formatInt(t.totalTokens))")
    print("  costo:        \(formatUSD(t.costUSD))")
    print("  cache eff.:   \(String(format: "%.1f%%", report.cacheEfficiency * 100))")
    print("")
    print("PER MODELLO:")
    for m in report.byModel.prefix(15) {
        let est = m.costEstimated ? " (stima)" : ""
        let name = m.model.padding(toLength: 26, withPad: " ", startingAt: 0)
        let tok = formatInt(m.totalTokens).padding(toLength: 16, withPad: " ", startingAt: 0)
        print("  \(name) \(tok) \(formatUSD(m.costUSD))\(est)")
    }
    print("")
    print("PER PROGETTO (top 10):")
    for p in report.byProject.prefix(10) {
        let name = p.displayName.padding(toLength: 32, withPad: " ", startingAt: 0)
        let tok = formatInt(p.totalTokens).padding(toLength: 16, withPad: " ", startingAt: 0)
        print("  \(name) \(tok) \(formatUSD(p.costUSD))")
    }
    print("")
    print("Giorni con attività: \(report.byDay.count) | Sessioni: \(report.bySession.count)")
}

func dumpLimits(_ snapshot: LimitsSnapshot) {
    print("=== ClaudeBar — Limiti ufficiali ===")
    print("Account: \(snapshot.accountLabel) | Piano: \(snapshot.subscriptionType) | Source: \(snapshot.source)")
    func line(_ label: String, _ w: UsageWindow?) {
        guard let w else { return }
        let reset = w.resetsAt.map { "\($0)" } ?? "—"
        var s = "  \(label.padding(toLength: 16, withPad: " ", startingAt: 0)) usato \(String(format: "%.0f%%", w.utilization)) | reset \(reset)"
        if let p = w.pace {
            s += " | ritmo \(p.rhythm)\(p.isOverPace ? " (sopra)" : "")"
            if let eta = p.etaToEmpty { s += " | esaurisci \(eta)" }
            else if p.reachesResetWithMargin { s += " | arrivi al reset con margine" }
        }
        print(s)
    }
    line("Sessione 5h", snapshot.fiveHour)
    line("Settimana", snapshot.sevenDay)
    line("Sett. Opus", snapshot.sevenDayOpus)
    line("Sett. Sonnet", snapshot.sevenDaySonnet)
    line("Extra crediti", snapshot.extraUsage)
    print("  Più critica: \(snapshot.mostCritical.kind) (\(String(format: "%.0f%%", snapshot.mostCritical.utilization)) usato)")
}

// MARK: - Entry

let args = CommandLine.arguments
let wantJSON = args.contains("--json")
let wantLimits = args.contains("--limits")

if wantLimits {
    let service = ClaudeLimitsService()
    do {
        let snapshot = try await service.fetchUsage(userInitiated: true)
        dumpLimits(snapshot)
    } catch {
        FileHandle.standardError.write(Data("Errore limiti: \(error.localizedDescription)\n".utf8))
        exit(1)
    }
} else {
    // In modalità --json stdout deve contenere SOLO il JSON: i messaggi vanno su stderr.
    if wantJSON {
        FileHandle.standardError.write(Data("Indicizzazione transcript in corso…\n".utf8))
    } else {
        print("Indicizzazione transcript in corso…")
    }
    let start = Date()
    let indexer = TranscriptIndexer(progress: { p in
        if !wantJSON {
            FileHandle.standardError.write(Data(String(format: "\r  %.0f%%", p * 100).utf8))
        }
    })
    do {
        let report = try await indexer.refresh(force: false)
        if !wantJSON { FileHandle.standardError.write(Data("\r       \r".utf8)) }
        let elapsed = Date().timeIntervalSince(start)
        dumpReport(report, json: wantJSON)
        if !wantJSON {
            print("")
            print("(indicizzato in \(String(format: "%.1f", elapsed))s)")
        }
    } catch {
        FileHandle.standardError.write(Data("Errore indicizzazione: \(error.localizedDescription)\n".utf8))
        exit(1)
    }
}

import ClaudeBarCore
import Foundation
import OSLog

/// Costruisce il testo di diagnostica copiato negli appunti dalla sezione Avanzato.
///
/// Mette insieme (1) identità app + ambiente, (2) percorsi dei dati e conteggi del report corrente,
/// (3) — best-effort — le ultime righe di log dell'app via `OSLogStore`. Tutto resta locale: il testo
/// finisce solo negli appunti, niente viene inviato. Se `OSLogStore` non è accessibile (sandbox /
/// permessi), la sezione log riporta semplicemente che i log non sono leggibili.
enum DiagnosticsReport {
    /// Subsystem dei `Logger` usati nell'app e nel Core, per filtrare i log nella diagnostica.
    private static let subsystems = [AppInfo.bundleIdentifier, "com.subralabs.claudebar.core"]

    static func build(report: AnalyticsReport?) -> String {
        var sections: [String] = []
        sections.append(self.environmentSection())
        sections.append(self.dataSection(report: report))
        sections.append(self.logSection())
        return sections.joined(separator: "\n\n")
    }

    // MARK: Ambiente

    private static func environmentSection() -> String {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        var lines = ["== ClaudeBar — Diagnostica =="]
        lines.append("Generato: \(ISO8601DateFormatter().string(from: Date()))")
        lines.append("App: \(AppInfo.displayName) \(AppInfo.shortVersion) (\(AppInfo.buildNumber))")
        lines.append("Bundle: \(AppInfo.bundleIdentifier)")
        lines.append("macOS: \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)")
        return lines.joined(separator: "\n")
    }

    // MARK: Dati / cache

    private static func dataSection(report: AnalyticsReport?) -> String {
        var lines = ["== Dati =="]
        for root in AppPaths.transcriptRoots() {
            let exists = FileManager.default.fileExists(atPath: root.path)
            lines.append("Transcript: \(root.path) \(exists ? "(presente)" : "(assente)")")
        }
        lines.append("Cache app: \(AppPaths.appSupportDir().path)")
        lines.append("Indice: \(AppPaths.indexDir().path)")

        if let report {
            lines.append("Report — token totali: \(report.totals.totalTokens)")
            lines.append("Report — giorni: \(report.byDay.count), modelli: \(report.byModel.count), progetti: \(report.byProject.count)")
            if let cost = report.totals.costUSD {
                lines.append("Report — costo stimato: $\(String(format: "%.2f", cost))")
            }
            lines.append("Report — generato: \(ISO8601DateFormatter().string(from: report.generatedAt))")
        } else {
            lines.append("Report: nessuna cache su disco.")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Log (OSLogStore, best-effort)

    private static func logSection() -> String {
        guard let entries = self.recentLogLines(limit: 80) else {
            return "== Log recenti ==\n(Log non leggibili: OSLogStore non accessibile in questo contesto.)"
        }
        if entries.isEmpty {
            return "== Log recenti ==\n(Nessuna voce di log nelle ultime ore.)"
        }
        return "== Log recenti (\(entries.count)) ==\n" + entries.joined(separator: "\n")
    }

    /// Ultime righe di log dei subsystem dell'app, dall'ultima ora. `nil` se lo store non è leggibile.
    private static func recentLogLines(limit: Int) -> [String]? {
        guard let store = try? OSLogStore(scope: .currentProcessIdentifier) else { return nil }
        let since = store.position(date: Date().addingTimeInterval(-3600))
        let predicate = NSPredicate(format: "subsystem IN %@", self.subsystems)
        guard let entries = try? store.getEntries(at: since, matching: predicate) else { return nil }

        var lines: [String] = []
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        for case let entry as OSLogEntryLog in entries {
            let time = formatter.string(from: entry.date)
            lines.append("[\(time)] \(entry.category): \(entry.composedMessage)")
        }
        // Tieni le ultime `limit` righe (le più recenti).
        return Array(lines.suffix(limit))
    }
}

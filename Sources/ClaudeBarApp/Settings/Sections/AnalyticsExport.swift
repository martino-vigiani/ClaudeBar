import ClaudeBarCore
import Foundation

/// Serializzazione del `AnalyticsReport` per l'esportazione dalla sezione Avanzato.
///
/// - **JSON**: il report completo (è già `Codable`), con date ISO-8601 e output indentato.
/// - **CSV**: più sezioni concatenate (totali, per giorno, per modello, per progetto), ciascuna con
///   intestazione. Pensato per aprirsi in un foglio di calcolo; i numeri non sono formattati in
///   "compatto" ma esatti, e i costi sono in USD con punto decimale.
enum AnalyticsExport {
    /// Report completo in JSON (pretty, date ISO-8601). `nil` se la codifica fallisce.
    static func json(from report: AnalyticsReport) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(report) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Report in CSV multi-sezione (totali + per giorno/modello/progetto).
    static func csv(from report: AnalyticsReport) -> String {
        var lines: [String] = []

        // Sezione: totali.
        lines.append("# Totals")
        lines.append("metric,value")
        lines.append("total_tokens,\(report.totals.totalTokens)")
        lines.append("input,\(report.totals.input)")
        lines.append("output,\(report.totals.output)")
        lines.append("cache_read,\(report.totals.cacheRead)")
        lines.append("cache_write_5m,\(report.totals.cacheWrite5m)")
        lines.append("cache_write_1h,\(report.totals.cacheWrite1h)")
        lines.append("cost_usd,\(Self.cost(report.totals.costUSD))")
        lines.append("cache_efficiency,\(String(format: "%.4f", report.cacheEfficiency))")
        lines.append("")

        // Sezione: per giorno.
        lines.append("# By day")
        lines.append("day,tokens,input,output,cache_read,cost_usd")
        for day in report.byDay {
            lines.append([
                Self.escape(day.dayKey),
                "\(day.totalTokens)",
                "\(day.input)",
                "\(day.output)",
                "\(day.cacheRead)",
                Self.cost(day.costUSD),
            ].joined(separator: ","))
        }
        lines.append("")

        // Sezione: per modello.
        lines.append("# By model")
        lines.append("model,tokens,cost_usd,cost_estimated")
        for model in report.byModel {
            lines.append([
                Self.escape(model.model),
                "\(model.totalTokens)",
                Self.cost(model.costUSD),
                model.costEstimated ? "yes" : "no",
            ].joined(separator: ","))
        }
        lines.append("")

        // Sezione: per progetto.
        lines.append("# By project")
        lines.append("project,path,tokens,cost_usd")
        for project in report.byProject {
            lines.append([
                Self.escape(project.displayName),
                Self.escape(project.projectPath),
                "\(project.totalTokens)",
                Self.cost(project.costUSD),
            ].joined(separator: ","))
        }

        return lines.joined(separator: "\n").appending("\n")
    }

    /// Costo per il CSV: punto decimale e vuoto se sconosciuto (così la colonna resta numerica).
    private static func cost(_ value: Double?) -> String {
        guard let value else { return "" }
        return String(format: "%.6f", value)
    }

    /// Escape CSV minimale: racchiude tra virgolette se il campo contiene virgola/virgolette/newline
    /// e raddoppia le virgolette interne (RFC 4180).
    private static func escape(_ field: String) -> String {
        guard field.contains(",") || field.contains("\"") || field.contains("\n") else {
            return field
        }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}

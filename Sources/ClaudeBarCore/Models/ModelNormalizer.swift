import Foundation

// Normalizzazione del model id verso le chiavi della pricing table.
// Estende la regex di CodexBar per coprire i casi reali verificati nei `.jsonl` dell'utente:
//   claude-opus-4-7 (più usato), varianti `[1m]` (claude-opus-4-7[1m]),
//   alias brevi opus/sonnet/haiku, `<synthetic>`.

public enum ModelNormalizer {
    /// Alias brevi → famiglia corrente "nota". Il costo per alias è una **stima** (il modello
    /// esatto è ignoto): l'aggregato che li include va marcato `costEstimated`.
    /// Aggiornare quando esce una nuova famiglia di default.
    public static let aliasMap: [String: String] = [
        "opus": "claude-opus-4-8",
        "sonnet": "claude-sonnet-4-6",
        "haiku": "claude-haiku-4-5",
    ]

    /// Token di sistema senza billing: vanno esclusi dal costo (ma possono contribuire ai token).
    public static let syntheticSentinel = "<synthetic>"

    /// Normalizza un model id grezzo verso la chiave della pricing table.
    ///
    /// Passi (nell'ordine):
    /// 1. trim; rimuovi prefisso `anthropic.` / segmento bedrock `...claude-...`
    /// 2. rimuovi suffisso `[1m]` (necessario per `claude-opus-4-7[1m]`)
    /// 3. rimuovi suffisso versione bedrock `-v\d+:\d+`
    /// 4. rimuovi data Vertex `@YYYYMMDD`
    /// 5. rimuovi data `-YYYYMMDD` se la base è in tabella
    /// 6. mappa alias brevi opus/sonnet/haiku
    /// 7. lascia `<synthetic>` invariato (riconoscibile via `isSynthetic`)
    public static func normalize(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return s }

        if s == syntheticSentinel { return s }

        // 1. prefisso "anthropic." e segmento bedrock con "."
        if s.hasPrefix("anthropic.") {
            s = String(s.dropFirst("anthropic.".count))
        }
        if let lastDot = s.lastIndex(of: "."), s.contains("claude-") {
            let tail = String(s[s.index(after: lastDot)...])
            if tail.hasPrefix("claude-") { s = tail }
        }

        // 2. suffisso "[1m]" (e in generale "[...]" a fine stringa).
        if let bracket = s.range(of: #"\[[^\]]*\]$"#, options: .regularExpression) {
            s.removeSubrange(bracket)
        }

        // 3. suffisso versione bedrock "-v\d+:\d+".
        if let vRange = s.range(of: #"-v\d+:\d+$"#, options: .regularExpression) {
            s.removeSubrange(vRange)
        }

        // 4. data Vertex "@YYYYMMDD" (claude-opus-4-5@20251101 → claude-opus-4-5).
        if let at = s.firstIndex(of: "@") {
            s = String(s[..<at])
        }

        // 5. data "-YYYYMMDD" se la base è in tabella.
        if let dateRange = s.range(of: #"-\d{8}$"#, options: .regularExpression) {
            let base = String(s[..<dateRange.lowerBound])
            if PricingTable.embedded[base] != nil {
                s = base
            }
        }

        // 6. alias brevi.
        if let mapped = aliasMap[s] {
            return mapped
        }

        return s
    }

    /// true se il model id grezzo è il token di sistema senza billing.
    public static func isSynthetic(_ raw: String) -> Bool {
        raw.trimmingCharacters(in: .whitespacesAndNewlines) == syntheticSentinel
    }

    /// true se il model id grezzo è un alias breve non versionato → costo stimato.
    public static func isAlias(_ raw: String) -> Bool {
        aliasMap[raw.trimmingCharacters(in: .whitespacesAndNewlines)] != nil
    }
}

import Foundation

// Percorsi standard usati dal Core: root dei transcript Claude, Application Support, cache.
// Parametrico sul nome prodotto per il rebrand a costo zero (DECISIONS.md).

public enum AppPaths {
    /// Nome cartella sotto Application Support / Caches. Parametrico per il rebrand.
    public static let productFolderName = "ClaudeBar"

    /// `$CLAUDE_CONFIG_DIR` se impostata, altrimenti `~/.claude`.
    public static func claudeHome(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let custom = environment["CLAUDE_CONFIG_DIR"], !custom.isEmpty {
            return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude", isDirectory: true)
    }

    /// Root dei transcript: `~/.claude/projects` (+ varianti note).
    /// Ritorna solo i percorsi effettivamente esistenti; se nessuno esiste, ritorna il primario.
    public static func transcriptRoots(environment: [String: String] = ProcessInfo.processInfo.environment) -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var candidates: [URL] = [
            claudeHome(environment: environment).appendingPathComponent("projects", isDirectory: true),
            home.appendingPathComponent(".config/claude/projects", isDirectory: true),
        ]
        // De-dup preservando l'ordine.
        var seen = Set<String>()
        candidates = candidates.filter { seen.insert($0.standardizedFileURL.path).inserted }

        let existing = candidates.filter { FileManager.default.fileExists(atPath: $0.path) }
        return existing.isEmpty ? [candidates[0]] : existing
    }

    /// `~/Library/Application Support/<Product>/`.
    public static func appSupportDir() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent(productFolderName, isDirectory: true)
    }

    /// File di override pricing locale: `<AppSupport>/pricing-overrides.json`.
    public static func pricingOverridesURL() -> URL {
        appSupportDir().appendingPathComponent("pricing-overrides.json", isDirectory: false)
    }

    /// Directory dell'indice incrementale: `<AppSupport>/index/`.
    public static func indexDir() -> URL {
        appSupportDir().appendingPathComponent("index", isDirectory: true)
    }

    /// Crea una directory se non esiste (best-effort).
    public static func ensureDirectory(_ url: URL) {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
}

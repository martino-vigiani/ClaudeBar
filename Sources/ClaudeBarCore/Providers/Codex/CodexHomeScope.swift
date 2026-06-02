import Foundation

// Risoluzione della "home" di Codex: `$CODEX_HOME` se impostato, altrimenti `~/.codex`.
// Vi risiedono `auth.json` (credenziali OAuth) e `config.toml` (override base URL).

public enum CodexHomeScope {
    /// Directory home di Codex: `$CODEX_HOME` (se non vuoto) oppure `~/.codex`.
    public static func homeURL(
        env: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default) -> URL
    {
        if let raw = env["CODEX_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            return URL(fileURLWithPath: raw, isDirectory: true)
        }
        return fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
    }
}

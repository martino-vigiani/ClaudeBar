import Foundation

/// Identità di app parametrica (02-app-architecture.md §2.1): display name override-abile,
/// bundle id che pilota i path su disco. Cambiare il display name NON sposta cache/impostazioni
/// (derivano dal bundle id).
enum AppInfo {
    /// Bundle id reale a runtime; fallback al valore di release se non in bundle (es. dev `swift run`).
    static var bundleIdentifier: String {
        Bundle.main.bundleIdentifier ?? "com.subralabs.claudebar"
    }

    /// Nome visualizzato: `CFBundleDisplayName` se presente, altrimenti "ClaudeBar".
    static var displayName: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? "ClaudeBar"
    }

    static var shortVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1"
    }

    static var buildNumber: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
    }

    /// Prefisso delle chiavi UserDefaults (analogo al prefisso di CodexBar).
    static let defaultsPrefix = "clbar."
}

// NB: i path su disco (transcript root, Application Support, cache) vivono in
// `ClaudeBarCore.AppPaths` (transcriptRoots()/appSupportDir()), condivisi con CLI/test.
// L'app non ridefinisce un proprio AppPaths per evitare ambiguità di nome col modulo Core.

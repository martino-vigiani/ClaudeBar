import Foundation
import os

// Wrapper su os.Logger con categorie, per il Core. Nessuna dipendenza AppKit.

public enum CoreLog {
    private static let subsystem = "com.subralabs.claudebar.core"

    public static let limits = Logger(subsystem: subsystem, category: "limits")
    public static let analytics = Logger(subsystem: subsystem, category: "analytics")
    public static let keychain = Logger(subsystem: subsystem, category: "keychain")
    public static let pricing = Logger(subsystem: subsystem, category: "pricing")
    public static let persistence = Logger(subsystem: subsystem, category: "persistence")
}

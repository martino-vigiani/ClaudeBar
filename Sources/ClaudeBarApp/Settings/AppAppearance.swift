import AppKit

/// Aspetto richiesto dall'utente per l'app (finestre: Preferenze + pannello).
///
/// `.system` segue l'aspetto di macOS; `.light`/`.dark` lo forzano via `NSApp.appearance`.
/// Nota: l'icona della menu bar disegna comunque per il contrasto della *menu bar* corrente
/// (vedi `GlanceAppearance` derivato da `effectiveAppearance`), indipendente da questa scelta.
enum AppAppearance: String, Sendable, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { self.rawValue }

    var label: String {
        switch self {
        case .system: "Sistema"
        case .light: "Chiaro"
        case .dark: "Scuro"
        }
    }

    /// `NSAppearance` da imporre a `NSApp.appearance`. `nil` per `.system` (segue macOS).
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }

    /// SF Symbol per il picker nelle Impostazioni.
    var symbolName: String {
        switch self {
        case .system: "circle.lefthalf.filled"
        case .light: "sun.max"
        case .dark: "moon"
        }
    }
}

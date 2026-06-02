import Foundation

// Classificazione del glance sull'USATO + soglie condivise (02 §13).
// Vive in Core (no AppKit) così che CLI/test possano riusarla. La FUNZIONE colore
// (used → NSColor/Color, dipende da AppKit/SwiftUI) vive nell'app, non qui.
//
// SEMANTICA LOCK (DECISIONS.md §"LOCK semantica glance"): l'input è il **% USATO**
// (utilization), normalizzato in frazione 0...1. Più usato → più critico.

/// Stato qualitativo del glance, mappato sull'USATO.
public enum GlanceState: String, Sendable, Equatable, CaseIterable {
    /// Tutto ok (poco usato).
    case ok
    /// Avviso (usato oltre la soglia warn).
    case warn
    /// Quota bassa rimanente (usato oltre la soglia critical).
    case low
    /// Critico (usato oltre la soglia critical, vicino al limite).
    case critical
    /// Praticamente esaurito (usato oltre la soglia empty) → pulsa.
    case empty
}

/// Soglie condivise per la classificazione glance, espresse sull'USATO (frazione 0...1).
/// Allineate a `DECISIONS.md` (verde <60, ambra 60–85, rosso >85, pulsa ≥95).
public enum GlanceThresholds {
    /// Sopra questa frazione di USATO → `warn` (ambra). Default 0.60.
    public static let warn: Double = 0.60
    /// Sopra questa frazione di USATO → `critical` (rosso). Default 0.85.
    public static let critical: Double = 0.85
    /// Sopra questa frazione di USATO → `empty` (pulsa). Default 0.95.
    public static let empty: Double = 0.95
}

extension GlanceState {
    /// Classifica una frazione di USATO (0...1) in uno stato di glance.
    ///
    /// Mapping (sull'USATO):
    /// - `< warn`        → `.ok`
    /// - `[warn, crit)`  → `.warn`
    /// - `[crit, empty)` → `.critical`
    /// - `>= empty`      → `.empty`
    ///
    /// Nota: `.low` è un alias semantico disponibile per la UI ma non prodotto da questa
    /// funzione (la scala primaria usa ok/warn/critical/empty). Tenuto nell'enum per il §13.
    public static func glanceState(forUsed usedFraction: Double) -> GlanceState {
        let used = min(max(usedFraction, 0), 1)
        if used >= GlanceThresholds.empty { return .empty }
        if used >= GlanceThresholds.critical { return .critical }
        if used >= GlanceThresholds.warn { return .warn }
        return .ok
    }

    /// true se lo stato richiede l'effetto "pulse" dell'icona (USATO ≥ soglia empty).
    public var shouldPulse: Bool { self == .empty }
}

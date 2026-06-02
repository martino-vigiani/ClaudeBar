import Foundation

/// Metadati del modulo Core di ClaudeBar.
///
/// `ClaudeBarCore` (il modulo) è la libreria pura del progetto: **non** importa AppKit né
/// SwiftUI. Contiene i value type `Sendable`, i servizi limiti (OAuth/Keychain), il parser
/// incrementale `.jsonl`, la pricing table e il calcolo Pace/Forecast.
///
/// NB: questo namespace si chiama `ClaudeBarCoreInfo` e **non** `ClaudeBarCore`: un enum
/// omonimo al modulo ombreggerebbe il qualificatore di modulo (es. `ClaudeBarCore.AppPaths`
/// non risolverebbe più al tipo del modulo). Le aree sono in `ClaudeBarCoreArea`.
public enum ClaudeBarCoreInfo {
    /// Versione interna dello schema/contratto del Core. Bump quando cambia un tipo Sendable di confine.
    public static let schemaVersion = 1
}

/// Aree del Core, mappate sulle sottocartelle di `Sources/ClaudeBarCore/`.
/// Marker di documentazione: il contenuto reale è di competenza del data-engineer.
public enum ClaudeBarCoreArea: String, Sendable, CaseIterable {
    case models = "Models"
    case limits = "Limits"
    case analytics = "Analytics"
    case persistence = "Persistence"
    case util = "Util"
}

import Foundation

// Schema della cache limiti su disco. Serve al "glance/pannello visibile <100ms":
// all'avvio dipingiamo subito l'ultimo snapshot salvato, prima di rete e refresh.
// La conformità Codable di `LimitsSnapshot` (e dei suoi membri) è dichiarata nei rispettivi
// tipi dominio (richiesto per la sintesi automatica).

/// Schema versionato della cache limiti su disco.
struct LimitsCacheFile: Codable {
    static let schemaVersion = 1
    let schemaVersion: Int
    /// Istante di salvataggio: usato per la staleness al paint a freddo.
    let savedAt: Date
    let snapshot: LimitsSnapshot
}

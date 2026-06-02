import Foundation

// Schema della cache aggregati su disco. Serve al "glance/pannello visibile <100ms":
// all'avvio carichiamo l'ultimo report salvato per dipingere subito, prima del re-index
// e della rete. La conformità Codable dei tipi report è dichiarata in `AnalyticsReport.swift`
// (richiesto per la sintesi automatica).

/// Schema versionato della cache aggregati su disco.
struct AnalyticsCacheFile: Codable {
    static let schemaVersion = 1
    var schemaVersion: Int = AnalyticsCacheFile.schemaVersion
    /// Fingerprint pricing con cui è stato calcolato (invalida se i prezzi cambiano).
    var pricingFingerprint: String
    var report: AnalyticsReport
}

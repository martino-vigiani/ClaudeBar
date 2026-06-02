import ClaudeBarCore

/// Classificazione dello STATO del glance sull'USATO, usando le soglie scelte dall'utente
/// (`warnThreshold`/`criticalThreshold`) invece delle costanti fisse di Core.
///
/// SORGENTE UNICA app-side: la usano sia `AppModel.recomputeGlance` (icona reale) sia l'anteprima
/// live nelle Impostazioni (sezione Menu bar), così classificazione e preview coincidono sempre.
///
/// LOCK glance (DECISIONS): si classifica SEMPRE sull'USATO; le soglie cambiano solo DOVE scattano
/// ambra/rosso. Il GRADIENTE di colore continuo resta la curva fissa di `IconRenderer.color(forUsed:)`
/// (coerenza icona↔pannello): le soglie pilotano lo stato semantico, non le ancore di colore.
enum GlanceClassifier {
    /// Classifica una frazione di USATO (0...1) usando le soglie utente.
    /// Robustezza: ordina warn ≤ critical e tiene `empty` (pulsazione) ≥ critical, così
    /// configurazioni invertite o estreme non producono stati incoerenti.
    static func state(used: Double, warn: Double, critical: Double) -> GlanceState {
        let u = min(max(used, 0), 1)
        let w = min(max(warn, 0), 1)
        let c = max(min(max(critical, 0), 1), w)
        let empty = max(GlanceThresholds.empty, c)
        if u >= empty { return .empty }
        if u >= c { return .critical }
        if u >= w { return .warn }
        return .ok
    }
}

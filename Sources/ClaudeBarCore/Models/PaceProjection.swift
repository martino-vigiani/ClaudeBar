import Foundation

// Pace & Forecast — feature MVP (DECISIONS.md §"Matematica del pace", 02 §11).
// Tipo dominio + calcolatore puro. Per ogni `UsageWindow` con `utilization` (0–100)
// e `resetsAt` produce un indicatore di ritmo + previsione di esaurimento.

/// Stato di ritmo della finestra rispetto al consumo lineare atteso.
public enum PaceRhythm: String, Sendable, Equatable, Codable {
    /// In linea con il tempo trascorso (entro la tolleranza).
    case onTrack
    /// Sopra ritmo: stai consumando più in fretta del lineare (rischio esaurimento anticipato).
    case over
    /// Sotto ritmo: stai consumando più lentamente del lineare (margine).
    case under
}

/// Proiezione Pace & Forecast per una finestra di consumo.
public struct PaceProjection: Sendable, Equatable, Codable {
    /// = `elapsedFrac` (0...1): frazione di tempo trascorsa nella finestra,
    /// cioè "dove dovresti essere" se consumassi in modo lineare.
    public var paceMarker: Double
    /// `usedFrac > elapsedFrac` → stai consumando sopra il ritmo lineare.
    public var isOverPace: Bool
    /// Stato qualitativo del ritmo (per il colore verde/ambra/rosso in UI).
    public var rhythm: PaceRhythm
    /// Istante di esaurimento stimato (al ritmo lineare dall'inizio della finestra),
    /// se cade **prima** del reset. `nil` se arrivi al reset con margine.
    public var etaToEmpty: Date?
    /// true → al ritmo corrente arrivi al reset senza esaurire la quota.
    public var reachesResetWithMargin: Bool

    public init(
        paceMarker: Double,
        isOverPace: Bool,
        rhythm: PaceRhythm,
        etaToEmpty: Date?,
        reachesResetWithMargin: Bool)
    {
        self.paceMarker = paceMarker
        self.isOverPace = isOverPace
        self.rhythm = rhythm
        self.etaToEmpty = etaToEmpty
        self.reachesResetWithMargin = reachesResetWithMargin
    }
}

/// Calcolo puro del Pace & Forecast (matematica fissata in `DECISIONS.md` §Pace).
public enum PaceCalculator {
    /// Tolleranza attorno al ritmo lineare per classificare `onTrack` (frazione, ±).
    /// Sotto questa distanza da `elapsedFrac`, il consumo è considerato in linea.
    public static let rhythmTolerance: Double = 0.05

    /// Calcola la proiezione per una finestra.
    ///
    /// - Parameters:
    ///   - kind: tipo di finestra (determina la `duration` nominale).
    ///   - utilization: % USATA, 0...100.
    ///   - resetsAt: istante di reset. Se `nil`, non è possibile calcolare il pace.
    ///   - now: istante corrente (iniettabile per i test).
    ///   - duration: durata REALE della finestra (estensione multi-provider). Se `nil`, vale
    ///     `kind.duration` (caso Claude, comportamento invariato). I provider con finestre non
    ///     standard (Gemini daily 24h, Cursor billing cycle variabile) passano qui la durata vera.
    /// - Returns: la proiezione, oppure `nil` se mancano dati per calcolarla.
    public static func project(
        kind: PaceWindowKind,
        utilization: Double,
        resetsAt: Date?,
        now: Date = Date(),
        duration durationOverride: TimeInterval? = nil) -> PaceProjection?
    {
        guard let resetsAt else { return nil }

        let duration = durationOverride ?? kind.duration
        guard duration > 0 else { return nil }

        // windowStart = resets_at - duration; elapsed = now - windowStart; remaining = resets_at - now.
        let windowStart = resetsAt.addingTimeInterval(-duration)
        let elapsed = now.timeIntervalSince(windowStart)
        let remainingTime = resetsAt.timeIntervalSince(now)

        let usedFrac = clamp(utilization / 100, 0, 1)
        let elapsedFrac = clamp(elapsed / duration, 0, 1)

        let isOverPace = usedFrac > elapsedFrac

        // Stato ritmo con tolleranza simmetrica attorno a elapsedFrac.
        let delta = usedFrac - elapsedFrac
        let rhythm: PaceRhythm =
            if delta > rhythmTolerance { .over }
            else if delta < -rhythmTolerance { .under }
            else { .onTrack }

        // ETA esaurimento al ritmo lineare dall'inizio finestra.
        // rate = usedFrac / elapsed (frazione per secondo); etaToEmpty(sec) = (1 - usedFrac) / rate.
        var etaToEmpty: Date?
        var reachesResetWithMargin = true
        if usedFrac > 0, elapsed > 0 {
            let rate = usedFrac / elapsed
            if rate > 0 {
                let secondsToEmpty = (1 - usedFrac) / rate
                if secondsToEmpty < remainingTime {
                    // Esaurisci PRIMA del reset → mostra ETA assoluto.
                    etaToEmpty = now.addingTimeInterval(secondsToEmpty)
                    reachesResetWithMargin = false
                }
            }
        }
        // Caso limite: già esaurito (usedFrac >= 1) e finestra non ancora resettata.
        if usedFrac >= 1 {
            etaToEmpty = now
            reachesResetWithMargin = false
        }

        return PaceProjection(
            paceMarker: elapsedFrac,
            isOverPace: isOverPace,
            rhythm: rhythm,
            etaToEmpty: etaToEmpty,
            reachesResetWithMargin: reachesResetWithMargin)
    }

    /// Comodità: arricchisce una finestra con la sua proiezione di pace. Usa la durata
    /// EFFETTIVA della finestra (custom se presente, altrimenti nominale dal `kind`), così il
    /// Pace è corretto anche per i provider con finestre non standard.
    public static func withPace(_ window: UsageWindow, now: Date = Date()) -> UsageWindow {
        var window = window
        window.pace = project(
            kind: window.kind,
            utilization: window.utilization,
            resetsAt: window.resetsAt,
            now: now,
            duration: window.effectiveDuration)
        return window
    }

    private static func clamp(_ value: Double, _ low: Double, _ high: Double) -> Double {
        min(max(value, low), high)
    }
}

import AppKit
import ClaudeBarCore

// Spec immutabile che descrive l'icona della status bar da disegnare.
// LOCK semantica glance (DECISIONS.md §1 + "LOCK semantica glance"): anello, percentuale
// numerica e colore rappresentano tutti il % USATO (`used`) della finestra PIÙ CRITICA.
// Più usato → più rosso. Soglie sull'usato: verde <60, ambra 60–85, rosso >85, pulsa ≥95.
//
// Lo stato semantico (`GlanceState`) e le soglie vivono in ClaudeBarCore (condivisi con CLI/test);
// qui usiamo direttamente `PaceWindowKind` di Core come etichetta della finestra critica.

/// Stile dell'icona: anello singolo (default) oppure doppio arco sessione+settimana.
enum GlanceStyle: Sendable, Equatable {
    case ring
    case dualBar
}

/// Quale percentuale mostrare come testo accanto all'anello. Default `.used` (DECISIONS §1).
enum PercentLabel: Sendable, Equatable {
    case used
    case remaining
    case hidden
}

/// Animazione corrente dell'icona. Guidata dal `DisplayLinkDriver` solo mentre serve.
enum GlanceAnimation: Sendable, Equatable {
    case none
    case pulse        // usato ≥95% → pulsa lentamente
    case refreshSpin  // micro-rotazione dell'arco durante un refresh
    case loadingSpin  // spinner d'arco indeterminato in loading
}

/// Aspetto della menu bar (per il contrasto del disegno).
enum GlanceAppearance: Sendable, Equatable {
    case light
    case dark
}

/// Trattamento "stale/errore": l'icona viene desaturata/abbassata, MAI un rosso falso
/// (un dato vecchio non deve sembrare "critico"). Non cambia lo `state` semantico.
struct GlanceIconSpec: Sendable, Equatable {
    /// 0...1, % USATO della finestra PIÙ CRITICA → arco + colore + percentuale.
    var used: Double
    /// Quale finestra è la più critica (per il badge nel pannello).
    var criticalKind: PaceWindowKind
    /// 0...1, % USATO settimanale (secondo arco/riga, solo `.dualBar`).
    var weeklyUsed: Double?
    /// 5 livelli derivati dalle soglie sull'usato.
    var state: GlanceState
    /// `.ring` (default) | `.dualBar`.
    var style: GlanceStyle
    /// Quale % mostrare come testo. Default `.used`.
    var percentLabel: PercentLabel
    /// Fallback template B/N (preferenza utente / "Aumenta contrasto").
    var monochrome: Bool
    /// Trattamento DIM per dati vecchi/non disponibili. Non implica colore "critico".
    var dim: Bool
    /// Animazione corrente.
    var animation: GlanceAnimation
    /// Aspetto della menu bar (light/dark) per il contrasto.
    var appearance: GlanceAppearance

    init(
        used: Double,
        criticalKind: PaceWindowKind = .fiveHour,
        weeklyUsed: Double? = nil,
        state: GlanceState,
        style: GlanceStyle = .ring,
        percentLabel: PercentLabel = .used,
        monochrome: Bool = false,
        dim: Bool = false,
        animation: GlanceAnimation = .none,
        appearance: GlanceAppearance = .dark)
    {
        self.used = used
        self.criticalKind = criticalKind
        self.weeklyUsed = weeklyUsed
        self.state = state
        self.style = style
        self.percentLabel = percentLabel
        self.monochrome = monochrome
        self.dim = dim
        self.animation = animation
        self.appearance = appearance
    }

    /// Spec di placeholder usata in fase di loading (nessun dato): anello grigio neutro.
    static let loading = GlanceIconSpec(
        used: 0,
        state: .ok,
        percentLabel: .hidden,
        dim: true,
        animation: .loadingSpin)

    /// Spec neutra per stati senza dato utile (no-subscription, keychain negato): trattino neutro.
    static let neutral = GlanceIconSpec(
        used: 0,
        state: .ok,
        percentLabel: .hidden,
        dim: true)
}

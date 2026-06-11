import SwiftUI

// MARK: - Design System (DS)
//
// Token di design del pannello ClaudeBar (rif. docs/plan/03-design.md §2 e §8).
// Tutto qui dentro è puramente presentazionale: spaziatura, raggi, dimensioni,
// tipografia e — soprattutto — la scala di colore SEMANTICA basata sul % USATO.
//
// Convenzione (DECISIONS.md, LOCK semantica glance): il valore primario è SEMPRE
// il `% usato` (utilization 0…100). Più usato → più rosso. Niente "remaining" come
// canale primario.

enum DS {

    // MARK: Spacing — scala a base 4
    enum Spacing {
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 20
        static let xxl: CGFloat = 32
    }

    // MARK: Radius — raggi concentrici (double-bezel)
    enum Radius {
        static let panel: CGFloat = 26
        static let card: CGFloat = 18
        static let inner: CGFloat = 14
        static let chip: CGFloat = 10
        static let pill: CGFloat = 999
    }

    // MARK: Size
    enum Size {
        static let ring: CGFloat = 96          // diametro anelli grandi del pannello
        static let ringLineWidth: CGFloat = 9  // spessore arco anello grande
        static let panelWidth: CGFloat = 360
        static let panelMaxHeight: CGFloat = 560
        /// Altezza max quando la fascia limiti è collassata ai soli anelli: il pannello
        /// cresce un po' così lo ScrollView analytics guadagna spazio reale, non solo quello
        /// liberato dalla fascia (vedi `CollapseHandle` / PanelContentView).
        static let panelMaxHeightExpanded: CGFloat = 600
        static let paceBarHeight: CGFloat = 12
        static let hairline: CGFloat = 1
    }

    // MARK: Durations / springs
    enum Motion {
        /// Molla morbida "premium" (~cubic-bezier(0.32,0.72,0,1)) per apertura/morphing.
        static let soft = Animation.interpolatingSpring(stiffness: 180, damping: 22)
        /// Riempimento "strumento vivo" dell'anello: molla con micro-overshoot al tip
        /// (più reattiva di `soft`) per il count-up e i cambi di quota dell'arco.
        static let gauge = Animation.interpolatingSpring(stiffness: 170, damping: 18)
        /// Cambi di valore live (numero, barra).
        static let smooth = Animation.smooth(duration: 0.45)
        /// Interpolazione cromatica (no scatto).
        static let color = Animation.easeInOut(duration: 0.6)
        /// Pulsazione critico/empty.
        static let pulse = Animation.easeInOut(duration: 1.4).repeatForever(autoreverses: true)
    }
}

// MARK: - Tipografia

extension Font {
    /// Numero grande "hero" / centro anello — SF Rounded, monospaced digits.
    static func dsDisplay(_ size: CGFloat = 28) -> Font {
        .system(size: size, weight: .semibold, design: .rounded).monospacedDigit()
    }
    // Text style semantici (non size fisse) → scalano con Dynamic Type. Le size base restano vicine
    // ai valori precedenti su macOS: title3 15, body 13, callout 12, caption 10, caption2 10.
    static let dsTitle = Font.title3.weight(.semibold)
    static let dsHeadline = Font.body.weight(.medium)
    static let dsBody = Font.body
    static let dsMono = Font.system(.callout, design: .monospaced)
    static let dsCaption = Font.caption
    /// Eyebrow / micro-badge sezione (UPPERCASE + tracking).
    static let dsEyebrow = Font.caption2.weight(.semibold)
}

// MARK: - Stato d'uso e scala di colore semantica

/// Stato derivato dal % USATO (soglie da DECISIONS.md §LOCK / 03-design §1.1).
enum UsageState: Sendable {
    case ok    // <60 usato
    case warn  // 60–85
    case crit  // >85
    case empty // ≥95 (rosso + glow/pulsa)

    static func from(used: Double) -> UsageState {
        switch used {
        case ..<60: .ok
        case 60..<85: .warn
        case 85..<95: .crit
        default: .empty
        }
    }
}

/// Scala di colore: 0…100 (% USATO) → verde → ambra → rosso, interpolato
/// in modo fluido (niente gradini netti). Le soglie servono solo per stato/glifo.
enum UsageColorScale {

    /// Colore interpolato sul % usato (0…100).
    ///
    /// SORGENTE UNICA: delega a `IconRenderer.color(forUsed:)` (NSColor) così l'anello del
    /// pannello e l'icona menu bar hanno ESATTAMENTE lo stesso colore a parità di % usato
    /// — coerenza glance↔glass richiesta dal design (§4.4, "Option B" definitiva). La curva è
    /// canonica e NON parametrica sulle soglie utente: quelle pilotano solo lo STATO, non il colore.
    static func color(used: Double) -> Color {
        Color(nsColor: IconRenderer.color(forUsed: max(0, min(100, used)) / 100))
    }

    static func state(used: Double) -> UsageState { .from(used: used) }

    /// Versione desaturata/dim per lo stato "stale" (mai rosso falso): vedi §3.5.
    static func dim(_ color: Color) -> Color { color.opacity(0.55) }
}

// MARK: - Colori di superficie / hairline

extension Color {
    /// Sfondo neutro delle card (NON glass — il contenuto resta leggibile).
    static let dsCardBackground = Color(nsColor: .controlBackgroundColor)
    // Nota: nessun token di tinta "clay". Il vetro del pannello è NEUTRO puro
    // (DECISIONS.md §3): nessuna tinta sul glass.
}

// MARK: - Hover highlight (affordance puntatore, macOS)

extension View {
    /// Evidenziazione al passaggio del puntatore: un fill neutro che si intensifica su hover,
    /// dietro al contenuto. Dà affordance "cliccabile" coerente a tutte le superfici tap del
    /// pannello (disclosure, picker, switcher, maniglia) senza ripetere lo stesso `onHover`.
    /// Trasparente a riposo (default) → si può applicare anche sopra elementi con sfondo proprio.
    func dsHoverHighlight<S: Shape>(
        in shape: S,
        rest: Double = 0,
        hover: Double = 0.08
    ) -> some View {
        modifier(HoverHighlight(shape: shape, rest: rest, hover: hover))
    }
}

private struct HoverHighlight<S: Shape>: ViewModifier {
    let shape: S
    let rest: Double
    let hover: Double
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .background(shape.fill(Color.primary.opacity(hovering ? hover : rest)))
            .contentShape(shape)
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.14), value: hovering)
    }
}

// MARK: - Hairline + inset highlight (double-bezel §2.4)

extension View {
    /// Bordo "vivo" delle card: hairline esterna + inset highlight bianco soffuso.
    /// Adatta automaticamente le opacità a light/dark.
    func dsCardBezel(cornerRadius: CGFloat = DS.Radius.card) -> some View {
        modifier(CardBezel(cornerRadius: cornerRadius))
    }
}

private struct CardBezel: ViewModifier {
    let cornerRadius: CGFloat
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let hairline = scheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.08)
        // Light mode: highlight bianco più tenue (0.5 lavava il testo vicino al bordo alto)
        // e fill più opaco → maggior contrasto del testo su card sul vetro chiaro.
        let inset = scheme == .dark ? Color.white.opacity(0.12) : Color.white.opacity(0.32)
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.dsCardBackground.opacity(scheme == .dark ? 0.5 : 0.86))
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(hairline, lineWidth: DS.Size.hairline)
            )
            // Inset highlight 1px in alto (bordo "incastonato").
            .overlay(alignment: .top) {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(inset, lineWidth: DS.Size.hairline)
                    .mask(
                        LinearGradient(colors: [.white, .clear],
                                       startPoint: .top, endPoint: .center)
                    )
            }
    }
}

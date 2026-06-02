import SwiftUI

// MARK: - GlassPanel
//
// La cornice Liquid Glass del pannello (il "vassoio" che galleggia sotto la barra).
// Regola d'oro (skill liquid-glass): glass SOLO sul contenitore di navigazione,
// MAI sul contenuto.
//
// VETRO NEUTRO (DECISIONS.md §3, fa fede sui doc di pianificazione): materiale Liquid
// Glass di sistema PURO, `.regular`, NESSUNA tinta (niente "warm-clay": era una
// raccomandazione dei pianificatori poi scartata dall'utente). Nessuna opzione di tint.
//
// Tutti gli elementi glass (cornice + pulsanti header) DEVONO condividere un solo
// GlassEffectContainer per coerenza visiva e per evitare CABackdropLayer multipli.

struct GlassPanel<Content: View>: View {
    @ViewBuilder var content: () -> Content

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        content()
            .background {
                if reduceTransparency {
                    // Accessibilità: niente trasparenza → superficie solida.
                    RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous)
                        .fill(Color(nsColor: .windowBackgroundColor))
                } else {
                    RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous)
                        .fill(.clear)
                        // Vetro NEUTRO puro: nessun .tint(...).
                        .glassEffect(.regular, in: .rect(cornerRadius: DS.Radius.panel))
                }
            }
            .overlay {
                // Inset highlight sottile sul bordo della cornice ("vivo").
                RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous)
                    .strokeBorder(.white.opacity(0.12), lineWidth: DS.Size.hairline)
                    .blendMode(.plusLighter)
                    .allowsHitTesting(false)
            }
        // NB: l'ombra NON è qui — viene applicata in PanelContentView DOPO il clipShape
        // della cornice, così segue la forma arrotondata (niente angolo squadrato).
    }
}

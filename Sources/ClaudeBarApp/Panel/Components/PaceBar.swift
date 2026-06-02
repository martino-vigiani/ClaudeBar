import SwiftUI

// MARK: - PaceBar (FEATURE CHIAVE — "Pace & Forecast")
//
// Barra di ritmo + previsione di esaurimento (DECISIONS.md §"Pace & Forecast").
//   • riempimento      = % quota USATA (utilization);
//   • MARKER verticale = "dove dovresti essere" = % di tempo trascorso (ritmo lineare atteso);
//   • TACCHE fisse     = 50% / 75% / 100%;
//   • testo ETA        = "A questo ritmo esaurisci tra ~Xh Ym" (o "Arrivi al reset con margine");
//   • stato ritmo      = in linea / sopra ritmo / sotto ritmo (verde/ambra/rosso).
//
// La matematica è PRE-CALCOLATA da Core in `PaceInfo`; qui solo presentazione.

struct PaceBar: View {
    let window: UsageWindowVM

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var used: Double { window.utilization }
    private var fillFraction: Double { max(0, min(1, used / 100)) }
    /// Finestra esaurita: utilization ≥ 100% (>= 99.5 per evitare flicker di arrotondamento).
    /// In questo stato "sopra ritmo" + "esaurisci tra ~0m" è privo di senso: la quota è già finita.
    private var isExhausted: Bool { used >= 99.5 }
    /// Colore critico/rosso, coerente con `PaceStatus.over.color`.
    private var limitReachedColor: Color { UsageColorScale.color(used: 92) }
    // Elemento glance della finestra attiva → colore sulla curva parametrica con le soglie utente.
    private var fillColor: Color { window.glanceColor }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s) {
            track
            footer
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Pace \(window.kind.eyebrow)"))
        .accessibilityValue(Text(paceAccessibilityValue))
    }

    // MARK: Track (barra + marker + tacche)

    private var track: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = DS.Size.paceBarHeight
            ZStack(alignment: .leading) {
                // Fondo.
                Capsule()
                    .fill(Color.primary.opacity(0.10))
                    .frame(height: h)

                // Riempimento = usato.
                Capsule()
                    .fill(fillColor.gradient)
                    .frame(width: max(h, w * fillFraction), height: h)
                    .animation(DS.Motion.smooth, value: fillFraction)
                    .animation(DS.Motion.color, value: fillColor)

                // Tacche fisse 50 / 75 / 100.
                ForEach([0.5, 0.75, 1.0], id: \.self) { t in
                    tick(at: t, width: w, height: h)
                }

                // Marker "dove dovresti essere" (pace marker).
                if let pace = window.pace {
                    paceMarker(at: pace.paceMarker, width: w, height: h)
                }
            }
            .frame(height: max(h, 22)) // spazio extra sopra per il glifo del marker
        }
        .frame(height: 22)
    }

    private func tick(at t: Double, width: CGFloat, height: CGFloat) -> some View {
        // 100% = bordo destro; lo disegniamo leggermente più alto per leggibilità.
        let isEnd = t >= 1.0
        return Rectangle()
            .fill(Color.primary.opacity(isEnd ? 0.30 : 0.22))
            .frame(width: 1.2, height: height + 4)
            .offset(x: min(width - 1.2, width * t) - (isEnd ? 1.2 : 0))
    }

    private func paceMarker(at frac: Double, width: CGFloat, height: CGFloat) -> some View {
        let x = min(width, max(0, width * frac))
        return ZStack(alignment: .top) {
            // Asta del marker.
            Rectangle()
                .fill(Color.primary.opacity(0.85))
                .frame(width: 2, height: height + 8)
            // Glifo a goccia in cima (segna "dove dovresti essere").
            Image(systemName: "arrowtriangle.down.fill")
                .font(.system(size: 7, weight: .bold))
                .foregroundStyle(.primary.opacity(0.85))
                .offset(y: -7)
        }
        .offset(x: x - 1)
        .animation(reduceMotion ? nil : DS.Motion.smooth, value: frac)
        .accessibilityHidden(true)
    }

    // MARK: Footer (stato ritmo + ETA)

    @ViewBuilder
    private var footer: some View {
        if isExhausted {
            // Finestra al 100%: niente stato ritmo né ETA ("sopra ritmo / ~0m" è insensato),
            // solo l'etichetta critica "Limit reached". Il reset è già mostrato altrove.
            Label {
                Text("Limit reached")
                    .font(.dsCaption.weight(.medium))
            } icon: {
                Image(systemName: "exclamationmark.octagon.fill")
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(limitReachedColor)
            .labelStyle(.titleAndIcon)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if let pace = window.pace {
            // Due righe (stato sopra, ETA sotto): nelle due colonne strette del pannello una
            // riga sola troncava ("esaurisci tr…"). Così niente troncamenti.
            VStack(alignment: .leading, spacing: 2) {
                Label {
                    Text(pace.status.label)
                        .font(.dsCaption.weight(.medium))
                } icon: {
                    Image(systemName: pace.status.symbol)
                        .font(.system(size: 11, weight: .semibold))
                }
                .foregroundStyle(pace.status.color)
                .labelStyle(.titleAndIcon)

                Text(etaText(pace))
                    .font(.dsCaption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .contentTransition(.numericText())
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: ETA formatting

    private func etaText(_ pace: PaceInfo) -> LocalizedStringKey {
        guard let eta = pace.etaToEmpty else {
            return "You'll reach the reset with margin"
        }
        return "runs out in ~\(Self.compactDuration(eta))"
    }

    /// "1h 39m", "47m", "2h".
    static func compactDuration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        let h = total / 3600
        let m = (total % 3600) / 60
        if h > 0 && m > 0 { return "\(h)h \(m)m" }
        if h > 0 { return "\(h)h" }
        return "\(m)m"
    }

    private var paceAccessibilityValue: LocalizedStringKey {
        if isExhausted { return "\(Int(used.rounded())) percent used, Limit reached" }
        guard let pace = window.pace else { return "\(Int(used.rounded())) percent used" }
        if let eta = pace.etaToEmpty {
            return "\(Int(used.rounded())) percent used, \(pace.status.label), at this pace you run out in \(Self.compactDuration(eta))"
        } else {
            return "\(Int(used.rounded())) percent used, \(pace.status.label), you'll reach the reset with margin"
        }
    }
}

#Preview("PaceBar — over / under pace") {
    VStack(spacing: 28) {
        PaceBar(window: .init(
            kind: .session, utilization: 62, resetsAt: .now,
            pace: PaceInfo(paceMarker: 0.45, status: .over,
                           etaToEmpty: 1.65 * 3600, emptyAt: .now)))
        PaceBar(window: .init(
            kind: .weekly, utilization: 38, resetsAt: .now,
            pace: PaceInfo(paceMarker: 0.55, status: .under,
                           etaToEmpty: nil, emptyAt: nil)))
        PaceBar(window: .init(
            kind: .session, utilization: 88, resetsAt: .now,
            pace: PaceInfo(paceMarker: 0.86, status: .onTrack,
                           etaToEmpty: 0.6 * 3600, emptyAt: .now)))
        // Esaurita (100%): "Limit reached", nessuno stato ritmo né ETA.
        PaceBar(window: .init(
            kind: .weekly, utilization: 100, resetsAt: .now,
            pace: PaceInfo(paceMarker: 0.7, status: .over,
                           etaToEmpty: 0, emptyAt: .now)))
    }
    .padding(40)
    .frame(width: 360)
}

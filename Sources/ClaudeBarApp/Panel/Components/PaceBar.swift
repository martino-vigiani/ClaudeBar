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
    // Elemento glance della finestra attiva → colore sulla curva parametrica con le soglie utente.
    private var fillColor: Color { window.glanceColor }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s) {
            track
            footer
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Ritmo \(window.kind.eyebrow)"))
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
        if let pace = window.pace {
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

    private func etaText(_ pace: PaceInfo) -> String {
        guard let eta = pace.etaToEmpty else {
            return "Arrivi al reset con margine"
        }
        return "esaurisci tra ~\(Self.compactDuration(eta))"
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

    private var paceAccessibilityValue: String {
        guard let pace = window.pace else { return "\(Int(used.rounded())) percento usato" }
        let etaPart: String
        if let eta = pace.etaToEmpty {
            etaPart = "a questo ritmo esaurisci tra \(Self.compactDuration(eta))"
        } else {
            etaPart = "arrivi al reset con margine"
        }
        return "\(Int(used.rounded())) percento usato, \(pace.status.label), \(etaPart)"
    }
}

#Preview("PaceBar — sopra / sotto ritmo") {
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
    }
    .padding(40)
    .frame(width: 360)
}

import SwiftUI

// MARK: - UsageRing
//
// Anello grande del pannello (Ø ~96pt). Stesso linguaggio visivo dell'icona menu
// bar: traccia di fondo + arco = % USATO, colore semantico interpolato.
// Centro: % grande (SF Rounded, monospaced) + micro-label. Tap → switch
// usato↔rimanente. Oltre 85% usato: alone semantico; ≥95% pulsazione (no Reduce Motion).

struct UsageRing: View {
    let window: UsageWindowVM
    /// Mostra il % usato (true) o il rimanente (false). Toggle al tap.
    @Binding var showUsed: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
    @State private var pulse = false

    private var used: Double { window.utilization }
    private var displayed: Double { showUsed ? used : window.remaining }
    // Elemento glance della finestra attiva → colore sulla curva parametrica con le soglie utente.
    private var color: Color { window.glanceColor }
    private var fraction: Double { max(0, min(1, used / 100)) }
    private var isGlowing: Bool { used >= 85 }
    private var isPulsing: Bool { used >= 95 && !reduceMotion }

    var body: some View {
        ZStack {
            // Traccia di fondo.
            Circle()
                .stroke(Color.primary.opacity(0.10),
                        style: StrokeStyle(lineWidth: DS.Size.ringLineWidth, lineCap: .round))

            // Arco di consumo.
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(color,
                        style: StrokeStyle(lineWidth: DS.Size.ringLineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90)) // parte da ore 12
                .shadow(color: isGlowing ? color.opacity(0.6) : .clear,
                        radius: isGlowing ? 6 : 0)
                .animation(DS.Motion.smooth, value: fraction)
                .animation(DS.Motion.color, value: color)

            // Centro: numero + label.
            VStack(spacing: 0) {
                Text("\(Int(displayed.rounded()))%")
                    .font(.dsDisplay(26))
                    .foregroundStyle(.primary)
                    .contentTransition(.numericText(value: displayed))
                Text(showUsed ? "used" : "free")
                    .font(.dsCaption)
                    .foregroundStyle(.secondary)
                    .contentTransition(.opacity)
            }

            // Micro-glifo di avviso oltre l'85% usato: canale NON cromatico
            // (utile con daltonismo / "Differenzia senza colori").
            if used >= 85 || differentiateWithoutColor {
                Image(systemName: used >= 95 ? "exclamationmark.triangle.fill" : "exclamationmark.circle.fill")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(color)
                    .opacity(used >= 85 ? 1 : 0)
                    .offset(y: DS.Size.ring / 2 - DS.Size.ringLineWidth - 6)
                    .symbolEffect(.pulse, isActive: isPulsing)
                    .accessibilityHidden(true)
            }
        }
        .frame(width: DS.Size.ring, height: DS.Size.ring)
        .scaleEffect(pulse ? 1.03 : 1.0)
        .animation(isPulsing ? DS.Motion.pulse : .default, value: pulse)
        .contentShape(Circle())
        .onTapGesture { withAnimation(DS.Motion.smooth) { showUsed.toggle() } }
        .onAppear { if isPulsing { pulse = true } }
        .onChange(of: isPulsing) { _, newValue in pulse = newValue }
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(Text(window.kind.eyebrow))
        .accessibilityValue(Text("\(Int(used.rounded())) percent used, \(window.state.accessibilityDescription)"))
        .accessibilityHint(Text("Tap to switch between used and remaining"))
    }
}

extension UsageState {
    var accessibilityDescription: String {
        switch self {
        case .ok: String(localized: "within limits")
        case .warn: String(localized: "warning")
        case .crit: String(localized: "critical")
        case .empty: String(localized: "nearly exhausted")
        }
    }
}

#Preview("UsageRing — states") {
    HStack(spacing: 24) {
        UsageRing(window: .init(kind: .session, utilization: 28, resetsAt: .now, pace: nil),
                  showUsed: .constant(true))
        UsageRing(window: .init(kind: .session, utilization: 72, resetsAt: .now, pace: nil),
                  showUsed: .constant(true))
        UsageRing(window: .init(kind: .session, utilization: 97, resetsAt: .now, pace: nil),
                  showUsed: .constant(true))
    }
    .padding(40)
}

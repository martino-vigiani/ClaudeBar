import SwiftUI

// MARK: - UsageRing  (OVERDRIVE — "living gauge")
//
// Anello grande del pannello (Ø ~96pt). Stesso linguaggio visivo dell'icona menu bar:
// traccia di fondo + arco = % USATO, colore semantico interpolato sulla curva canonica
// CONDIVISA con l'icona (`window.glanceColor` → IconRenderer) → coerenza glance↔glass.
// Quel colore NON si tocca: è una regola di design (DECISIONS §4.4).
//
// Strumento "vivo" (tutto degrada con Reduce Motion → stato statico, niente moto):
//   • count-up      — numero + arco salgono da 0 all'apertura (molla `gauge`);
//   • arco-fantasma — proiezione tratteggiata di DOVE atterri al reset al ritmo attuale;
//                     deriva dai dati Pace PRE-calcolati in Core (`paceMarker`/`etaToEmpty`),
//                     nessuna nuova matematica: solo geometria dell'arco;
//   • glow continuo — l'alone cresce con l'uso (nessun gradino on/off all'85%);
//   • sweep         — quando critico un riflesso ruota lungo l'arco (sostituisce il vecchio
//                     pulse di scala → un solo movimento, niente rumore visivo).

struct UsageRing: View {
    let window: UsageWindowVM
    /// Mostra il % usato (true) o il rimanente (false). Toggle al tap.
    @Binding var showUsed: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor

    // Stato d'animazione "vivo".
    @State private var animatedFraction: Double = 0  // arco (frazione usata)
    @State private var animatedValue: Double = 0      // numero al centro (count-up)
    @State private var sweep = false                  // riflesso rotante (solo critico)
    @State private var appeared = false               // gate per l'ingresso dell'arco-fantasma

    private var used: Double { window.utilization }
    private var displayed: Double { showUsed ? used : window.remaining }
    // Elemento glance della finestra → stesso colore dell'icona a parità di % usato.
    private var color: Color { window.glanceColor }
    private var fraction: Double { max(0, min(1, used / 100)) }
    private var isPulsing: Bool { used >= 95 && !reduceMotion }

    /// Proiezione al reset (0…1): DOVE atterri al ritmo attuale. Deriva dai dati Pace
    /// PRE-calcolati in Core, quindi è solo presentazione:
    ///   • `etaToEmpty != nil` ⇒ Core stima l'esaurimento PRIMA del reset ⇒ proietta a pieno;
    ///   • altrimenti estrapola linearmente: usato in `paceMarker` di tempo ⇒ a fine finestra
    ///     (tempo = 1) ≈ usato / paceMarker.
    /// Ritorna `nil` se non c'è Pace, se la finestra è già piena, o se la proiezione non
    /// aggiunge nulla oltre l'usato attuale.
    private var projectedFraction: Double? {
        guard let pace = window.pace, used < 99.5 else { return nil }
        let projected: Double
        if pace.etaToEmpty != nil {
            projected = 1.0
        } else if pace.paceMarker > 0.05 {
            projected = min(1, fraction / pace.paceMarker)
        } else {
            return nil
        }
        return projected > fraction + 0.01 ? projected : nil
    }

    var body: some View {
        let arcTo = min(1, max(0, animatedFraction))
        let color = self.color            // un solo NSColor per pass (body "caldo": animazioni)
        // Glow CONTINUO legato al riempimento ANIMATO: cresce con l'arco (intro) e con l'uso;
        // spento sotto il 50% → pieno verso il 95% (nessuno scatto on/off all'85%).
        let glow = max(0, min(1, (arcTo * 100 - 50) / 45))
        let glowRadius: CGFloat = glow <= 0 ? 0 : 2 + glow * 7
        let glowColor: Color = glow <= 0 ? .clear : color.opacity(0.25 + glow * 0.45)

        return ZStack {
            // Traccia di fondo.
            Circle()
                .stroke(Color.primary.opacity(0.10),
                        style: StrokeStyle(lineWidth: DS.Size.ringLineWidth, lineCap: .round))

            // Arco-fantasma "Pace": continuazione TENUE dal tip + tacca sul punto di reset
            // proiettato. L'occhio legge tip-luminoso (ora) → arco-tenue (traiettoria) →
            // tacca (atterraggio); lo spazio fino al 100% comunica il margine.
            if let proj = projectedFraction, proj > arcTo {
                arc(from: arcTo, to: proj)
                    .stroke(color.opacity(0.20), style: ghostStroke)
                    .opacity(appeared || reduceMotion ? 1 : 0)
                    .animation(reduceMotion ? nil : DS.Motion.gauge, value: projectedFraction)
                ProjectionTick(fraction: proj, color: color)
                    .opacity(appeared || reduceMotion ? 1 : 0)
            }

            // Arco di consumo.
            arc(from: 0, to: arcTo)
                .stroke(color, style: solidStroke)
                .shadow(color: glowColor, radius: glowRadius)
                .animation(DS.Motion.color, value: color)

            // Sweep speculare: riflesso che ruota lungo l'arco quando critico (no Reduce Motion).
            // Maschera = la sola forma dell'arco → si muove solo il riflesso, non l'arco.
            if isPulsing {
                Rectangle()
                    .fill(sweepGradient)
                    .rotationEffect(.degrees(sweep ? 360 : 0))
                    .mask { arc(from: 0, to: arcTo).stroke(Color.white, style: solidStroke) }
                    .blendMode(.plusLighter)
                    .allowsHitTesting(false)
            }

            // Centro: numero (count-up) + label.
            VStack(spacing: 0) {
                Text("\(Int(min(100, max(0, animatedValue)).rounded()))%")
                    .font(.dsDisplay(26))
                    .foregroundStyle(.primary)
                    .contentTransition(.numericText(value: animatedValue))
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
        .contentShape(Circle())
        .onTapGesture { withAnimation(DS.Motion.smooth) { showUsed.toggle() } }
        .onAppear { startIntro() }
        .onChange(of: fraction) { _, new in
            withAnimation(reduceMotion ? nil : DS.Motion.gauge) { animatedFraction = new }
        }
        .onChange(of: displayed) { _, new in
            withAnimation(reduceMotion ? nil : DS.Motion.smooth) { animatedValue = new }
        }
        .onChange(of: isPulsing) { _, now in updateSweep(now) }
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(Text(window.kind.eyebrow))
        .accessibilityValue(Text("\(Int(used.rounded())) percent used, \(window.state.accessibilityDescription)"))
        .accessibilityHint(Text("Tap to switch between used and remaining"))
    }

    // MARK: - Forme & stili

    /// Arco circolare (frazione 0…1) che parte da ore 12.
    private func arc(from start: Double, to end: Double) -> some Shape {
        Circle()
            .trim(from: min(1, max(0, start)), to: min(1, max(0, end)))
            .rotation(.degrees(-90))
    }

    private var solidStroke: StrokeStyle {
        StrokeStyle(lineWidth: DS.Size.ringLineWidth, lineCap: .round)
    }

    /// Arco-fantasma: continuo e più sottile dell'arco pieno (così "ora" e "proiezione"
    /// si distinguono per spessore oltre che per opacità).
    private var ghostStroke: StrokeStyle {
        StrokeStyle(lineWidth: DS.Size.ringLineWidth - 3, lineCap: .round)
    }

    /// Riflesso: un punto luce stretto lungo la circonferenza (il resto trasparente).
    private var sweepGradient: AngularGradient {
        AngularGradient(
            gradient: Gradient(stops: [
                .init(color: .white.opacity(0.0), location: 0.40),
                .init(color: .white.opacity(0.50), location: 0.50),
                .init(color: .white.opacity(0.0), location: 0.60),
            ]),
            center: .center)
    }

    // MARK: - Moto

    /// Ingresso: count-up del numero (curva morbida, niente overshoot) + riempimento
    /// dell'arco a molla. Con Reduce Motion tutto è istantaneo.
    private func startIntro() {
        if reduceMotion {
            animatedFraction = fraction
            animatedValue = displayed
            appeared = true
        } else {
            withAnimation(DS.Motion.gauge) { animatedFraction = fraction }
            withAnimation(DS.Motion.smooth) { animatedValue = displayed }
            withAnimation(.easeOut(duration: 0.4)) { appeared = true }
        }
        updateSweep(isPulsing)
    }

    /// Avvia/ferma la rotazione continua del riflesso (solo critico, no Reduce Motion).
    private func updateSweep(_ active: Bool) {
        guard !reduceMotion else { return }
        if active {
            withAnimation(.linear(duration: 2.4).repeatForever(autoreverses: false)) { sweep = true }
        } else {
            sweep = false
        }
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
        UsageRing(window: .init(kind: .session, utilization: 72, resetsAt: .now,
                                pace: PaceInfo(paceMarker: 0.5, status: .over,
                                               etaToEmpty: nil, emptyAt: nil)),
                  showUsed: .constant(true))
        UsageRing(window: .init(kind: .session, utilization: 97, resetsAt: .now,
                                pace: PaceInfo(paceMarker: 0.9, status: .over,
                                               etaToEmpty: 600, emptyAt: .now)),
                  showUsed: .constant(true))
    }
    .padding(40)
}

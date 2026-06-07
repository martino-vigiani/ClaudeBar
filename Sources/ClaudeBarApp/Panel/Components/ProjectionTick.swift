import SwiftUI

// MARK: - ProjectionTick
//
// Tacca radiale "atterri qui" sul punto di reset PROIETTATO dell'anello (UsageRing).
// Pattern clock-tick: la capsula è centrata nello ZStack, spostata al bordo con `offset`
// (che NON cambia il frame) e poi ruotata attorno al centro dell'anello con `rotationEffect`
// → finisce esattamente sull'angolo `fraction` della circonferenza.

struct ProjectionTick: View {
    /// Frazione 0…1 lungo la circonferenza (0 = ore 12, in senso orario).
    let fraction: Double
    /// Colore semantico della finestra (passato dall'anello → un solo `NSColor` per pass).
    let color: Color

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let angle = Angle.degrees(-90 + min(1, max(0, fraction)) * 360)
        Capsule()
            .fill(color.opacity(0.55))
            .frame(width: 2.5, height: DS.Size.ringLineWidth + 8)
            .offset(y: -DS.Size.ring / 2)
            .rotationEffect(angle)
            .animation(reduceMotion ? nil : DS.Motion.gauge, value: fraction)
            .accessibilityHidden(true)
    }
}

#Preview("ProjectionTick") {
    ZStack {
        Circle()
            .stroke(Color.primary.opacity(0.10),
                    style: StrokeStyle(lineWidth: DS.Size.ringLineWidth, lineCap: .round))
        ProjectionTick(fraction: 0.7, color: UsageColorScale.color(used: 70))
    }
    .frame(width: DS.Size.ring, height: DS.Size.ring)
    .padding(40)
}

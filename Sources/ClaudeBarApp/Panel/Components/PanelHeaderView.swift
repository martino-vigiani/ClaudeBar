import SwiftUI

// MARK: - PanelHeaderView (§4.3 — identità)
//
// Sinistra: pallino di stato (colore semantico della finestra critica) + account + plan.
// Destra: "aggiornato Ns fa" + refresh (glass, ruota durante il fetch) + settings (glass).
// I due pulsanti glass condividono il GlassEffectContainer del pannello (li avvolge il root).

struct PanelHeaderView: View {
    let account: AccountVM?
    let statusColor: Color
    let lastUpdated: Date?
    let isRefreshing: Bool
    let onRefresh: () -> Void
    let onSettings: () -> Void
    let onQuit: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var spin = false

    var body: some View {
        HStack(alignment: .top, spacing: DS.Spacing.s) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    statusDot
                    Text(account?.name ?? "ClaudeBar")
                        .font(.dsTitle)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if let plan = account?.plan {
                        Text(plan.uppercased())
                            .font(.dsEyebrow)
                            .tracking(0.6)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                Capsule().fill(Color.primary.opacity(0.08))
                            )
                            .fixedSize()
                    }
                }
                if let updated = lastUpdated {
                    Text(updatedText(updated))
                        .font(.dsCaption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }

            Spacer(minLength: DS.Spacing.s)

            refreshButton
            settingsButton
            quitButton
        }
    }

    // MARK: Status dot

    private var statusDot: some View {
        Circle()
            .fill(statusColor)
            .frame(width: 9, height: 9)
            .shadow(color: statusColor.opacity(0.6), radius: 3)
            .animation(DS.Motion.color, value: statusColor)
            .accessibilityHidden(true)
    }

    // MARK: Buttons — cerchi puliti e SEPARATI (niente .buttonStyle(.glass), che nel
    // GlassEffectContainer condiviso "fondeva" i due bottoni in una capsula con rientranza).

    private var refreshButton: some View {
        Button(action: onRefresh) {
            Image(systemName: "arrow.clockwise")
                .rotationEffect(.degrees(spin ? 360 : 0))
        }
        .buttonStyle(HeaderIconButtonStyle())
        .help("Refresh")
        .accessibilityLabel("Refresh")
        .onChange(of: isRefreshing) { _, refreshing in
            guard !reduceMotion else { return }
            if refreshing {
                withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) {
                    spin = true
                }
            } else {
                withAnimation(.easeOut(duration: 0.2)) { spin = false }
            }
        }
    }

    private var settingsButton: some View {
        Button(action: onSettings) {
            Image(systemName: "gearshape")
        }
        .buttonStyle(HeaderIconButtonStyle())
        .help("Preferences")
        .accessibilityLabel("Preferences")
    }

    // Quit: stessa forma neutra degli altri due, ma con affordance "uscita" su hover (tinta rossa)
    // così a riposo non grida e a colpo d'occhio si capisce che è l'azione che chiude l'app.
    private var quitButton: some View {
        Button(action: onQuit) {
            Image(systemName: "power")
        }
        .buttonStyle(HeaderIconButtonStyle(role: .quit))
        .help("Quit ClaudeBar")
        .accessibilityLabel("Quit ClaudeBar")
    }

    // MARK: Helpers

    private func updatedText(_ date: Date) -> LocalizedStringKey {
        let secs = Int(Date().timeIntervalSince(date))
        if secs < 5 { return "updated just now" }
        if secs < 60 { return "updated \(secs)s ago" }
        let mins = secs / 60
        if mins < 60 { return "updated \(mins)m ago" }
        return "updated \(mins / 60)h ago"
    }
}

// MARK: - Stile bottone icona dell'header
//
// Cerchio neutro sottile, leggero feedback alla pressione. NON glass → niente fusione
// tra bottoni adiacenti. Coerente col vetro neutro. Il ruolo `.quit` aggiunge una tinta
// rossa SOLO su hover (a riposo resta neutro come gli altri): affordance di uscita discreta.

private enum HeaderIconRole {
    case neutral
    case quit
}

private struct HeaderIconButtonStyle: ButtonStyle {
    var role: HeaderIconRole = .neutral

    func makeBody(configuration: Configuration) -> some View {
        IconButtonBody(configuration: configuration, role: role)
    }

    private struct IconButtonBody: View {
        let configuration: Configuration
        let role: HeaderIconRole
        @State private var hovering = false

        private var isQuitHot: Bool { role == .quit && hovering }

        var body: some View {
            let tint: Color = isQuitHot ? UsageColorScale.color(used: 95) : .secondary
            let fillOpacity = configuration.isPressed ? 0.16 : (hovering ? 0.12 : 0.07)
            return configuration.label
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isQuitHot ? AnyShapeStyle(tint) : AnyShapeStyle(.secondary))
                .frame(width: 26, height: 26)
                .background(
                    Circle().fill(
                        isQuitHot
                            ? AnyShapeStyle(tint.opacity(configuration.isPressed ? 0.22 : 0.14))
                            : AnyShapeStyle(Color.primary.opacity(fillOpacity)))
                )
                .contentShape(Circle())
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.14), value: hovering)
                .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
        }
    }
}

#Preview("Header") {
    GlassEffectContainer {
        PanelHeaderView(
            account: AccountVM(name: "martino", plan: "Max"),
            statusColor: UsageColorScale.color(used: 62),
            lastUpdated: Date().addingTimeInterval(-8),
            isRefreshing: false,
            onRefresh: {}, onSettings: {}, onQuit: {}
        )
        .padding()
    }
    .frame(width: 360)
    .padding()
}

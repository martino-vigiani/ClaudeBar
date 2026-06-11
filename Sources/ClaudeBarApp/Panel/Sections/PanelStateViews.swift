import SwiftUI

// MARK: - View per gli stati non-OK del pannello (§6, §7)
//
// Principio chiave (DECISIONS / 03-design §6): le ANALYTICS LOCALI restano SEMPRE
// visibili sotto questi banner. Mai numeri inventati per i limiti; mai rosso falso.

// MARK: Loading skeleton (primo fetch)

struct LimitsLoadingView: View {
    var body: some View {
        HStack(alignment: .top, spacing: DS.Spacing.l) {
            ForEach(0..<2, id: \.self) { _ in
                VStack(spacing: DS.Spacing.s) {
                    Capsule().fill(Color.primary.opacity(0.08)).frame(width: 70, height: 10)
                    Circle().fill(Color.primary.opacity(0.06))
                        .frame(width: DS.Size.ring, height: DS.Size.ring)
                    Capsule().fill(Color.primary.opacity(0.08)).frame(width: 90, height: 9)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .redacted(reason: .placeholder)
        .shimmer()
        .accessibilityLabel("Loading limits")
    }
}

// MARK: Banner stale

struct StaleBanner: View {
    let since: Date
    var body: some View {
        InfoBanner(
            symbol: "clock.arrow.circlepath",
            tint: .secondary,
            title: String(localized: "Data from \(minutes) min ago"),
            message: String(localized: "Refreshing…")
        )
    }
    private var minutes: Int { max(1, Int(Date().timeIntervalSince(since) / 60)) }
}

// MARK: Card errore limiti (analytics restano sotto)

struct LimitsErrorView: View {
    let message: String
    let onRetry: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s) {
            Label("Limits unavailable", systemImage: "wifi.slash")
                .font(.dsHeadline)
                .foregroundStyle(.primary)
            Text(message)
                .font(.dsCaption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Retry", action: onRetry)
                .buttonStyle(PanelActionButtonStyle(role: .prominent))
                .frame(maxWidth: .infinity)
                .padding(.top, DS.Spacing.xs)
        }
        .padding(DS.Spacing.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dsCardBezel()
    }
}

// MARK: No-auth onboarding INLINE

struct NoAuthView: View {
    let onReconnect: () -> Void
    let onHowTo: () -> Void
    /// Nome del provider attivo (per generalizzare il messaggio multi-provider). Default Claude.
    var providerName: String = "Claude"
    /// Messaggio guida (sovrascrivibile per i provider a consumo: "inserisci la API key…").
    var message: String?
    /// Riconnessione in corso: il bottone diventa "Reconnecting…" e si disabilita, così l'utente
    /// vede che dopo la password l'app sta lavorando (sta aspettando il refresh pigro della CLI) e
    /// non lo percepisce come inerte. Riusa `isRefreshing` dell'AppModel via l'adapter.
    var isReconnecting: Bool = false

    private var resolvedMessage: String {
        message ?? String(localized: "Sign in with Claude Code to see your session and weekly limits.")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s) {
            Label("\(providerName) access not detected", systemImage: "lock")
                .font(.dsHeadline)
            Text(resolvedMessage)
                .font(.dsCaption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: DS.Spacing.s) {
                Button("How to", action: onHowTo)
                    .buttonStyle(PanelActionButtonStyle(role: .secondary))
                Button(isReconnecting ? String(localized: "Reconnecting…") : String(localized: "Reconnect"),
                       action: onReconnect)
                    .buttonStyle(PanelActionButtonStyle(role: .prominent))
                    .disabled(isReconnecting)
                    // La label cambia ("Reconnect"→"Reconnecting…"): fissiamo il comando Voice
                    // Control su "Reconnect" così resta invocabile anche durante la riconnessione.
                    .accessibilityInputLabels([String(localized: "Reconnect")])
                Spacer(minLength: 0)
            }
            .padding(.top, DS.Spacing.xs)
        }
        .padding(DS.Spacing.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dsCardBezel()
    }
}

// MARK: No subscription

struct NoSubscriptionView: View {
    var body: some View {
        InfoBanner(
            symbol: "lock.open",
            tint: .secondary,
            title: String(localized: "Session limits unavailable"),
            message: String(localized: "The 5h/weekly windows require a Max plan. Local analytics stay available.")
        )
        .dsCardBezel()
    }
}

// MARK: Banner generico riusabile

struct InfoBanner: View {
    let symbol: String
    let tint: Color
    let title: String
    let message: String
    var body: some View {
        HStack(alignment: .top, spacing: DS.Spacing.s) {
            Image(systemName: symbol)
                .font(.system(size: 14))
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.dsHeadline)
                Text(message).font(.dsCaption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(DS.Spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Stile bottoni d'azione degli stati (no-auth, errore, …)
//
// Capsule pulite, monocrome, NON glass. Stesso motivo dell'header (PanelHeaderView §69):
// dentro il GlassEffectContainer condiviso del pannello due bottoni `.glass` adiacenti si
// FONDONO in un'unica capsula con rientranza ("blob"). Qui usiamo background espliciti, così
// i bottoni restano separati, di dimensione coerente e con la spaziatura dell'HStack.
//
// Nessun accento blu di sistema (DECISIONS §3, vetro NEUTRO): il "prominent" è una capsula
// graphite neutra (Color.primary a bassa opacità), il "secondary" è bordato sottile.

private struct PanelActionButtonStyle: ButtonStyle {
    enum Role { case secondary, prominent }
    let role: Role

    func makeBody(configuration: Configuration) -> some View {
        ActionButtonBody(configuration: configuration, role: role)
    }

    private struct ActionButtonBody: View {
        let configuration: Configuration
        let role: Role
        @Environment(\.colorScheme) private var scheme
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var hovering = false

        var body: some View {
            let pressed = configuration.isPressed
            return configuration.label
                .font(.dsHeadline)
                .foregroundStyle(labelColor)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, DS.Spacing.m)
                .frame(height: 28)
                .background {
                    Capsule(style: .continuous).fill(fill(pressed: pressed, hovering: hovering))
                }
                .overlay {
                    if role == .secondary {
                        Capsule(style: .continuous)
                            .strokeBorder(Color.primary.opacity(scheme == .dark ? 0.16 : 0.14),
                                          lineWidth: DS.Size.hairline)
                    }
                }
                .contentShape(Capsule(style: .continuous))
                .opacity(pressed ? 0.85 : 1)
                .onHover { hovering = $0 }
                .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: pressed)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: hovering)
                // Reset @State stantio dopo l'orderOut del pannello (vedi HoverHighlight).
                .onReceive(NotificationCenter.default.publisher(for: .claudeBarPanelDidHide)) { _ in
                    hovering = false
                }
        }

        /// Colore label: il prominent ha un fill graphite "pieno", quindi serve il colore di
        /// contrasto (chiaro su light dove il fill è scuro, scuro su dark dove il fill è chiaro).
        private var labelColor: Color {
            switch role {
            case .prominent: scheme == .dark ? .primary : Color(nsColor: .windowBackgroundColor)
            case .secondary: .secondary
            }
        }

        /// Fill: hover dà un gradino intermedio tra riposo e pressed → feedback prima del click.
        private func fill(pressed: Bool, hovering: Bool) -> Color {
            switch role {
            case .prominent:
                // Graphite neutro: scuro su light, chiaro su dark — leggibile, mai blu.
                if scheme == .dark {
                    let base = pressed ? 0.24 : (hovering ? 0.20 : 0.16)
                    return Color.primary.opacity(base)
                } else {
                    let base = pressed ? 0.78 : (hovering ? 0.94 : 0.88)
                    return Color.primary.opacity(base)
                }
            case .secondary:
                return Color.primary.opacity(pressed ? 0.12 : (hovering ? 0.10 : 0.06))
            }
        }
    }
}

// MARK: - Shimmer (per skeleton loading)

private struct Shimmer: ViewModifier {
    @State private var phase: CGFloat = -1
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        content.overlay {
            if !reduceMotion {
                GeometryReader { geo in
                    LinearGradient(
                        colors: [.clear, .white.opacity(0.25), .clear],
                        startPoint: .leading, endPoint: .trailing)
                    .frame(width: geo.size.width * 0.6)
                    .offset(x: phase * geo.size.width * 1.6)
                    .blendMode(.plusLighter)
                }
                .allowsHitTesting(false)
                .mask(content)
                .onAppear {
                    withAnimation(.linear(duration: 1.3).repeatForever(autoreverses: false)) {
                        phase = 1
                    }
                }
            }
        }
    }
}

extension View {
    func shimmer() -> some View { modifier(Shimmer()) }
}

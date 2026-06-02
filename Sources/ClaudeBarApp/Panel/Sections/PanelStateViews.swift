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
        .accessibilityLabel("Caricamento limiti in corso")
    }
}

// MARK: Banner stale

struct StaleBanner: View {
    let since: Date
    var body: some View {
        InfoBanner(
            symbol: "clock.arrow.circlepath",
            tint: .secondary,
            title: "Dati di \(minutes) min fa",
            message: "Aggiorno…"
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
            Label("Limiti non disponibili", systemImage: "wifi.slash")
                .font(.dsHeadline)
                .foregroundStyle(.primary)
            Text(message)
                .font(.dsCaption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: onRetry) {
                Text("Riprova").frame(maxWidth: .infinity)
            }
            .buttonStyle(.glass)
            .tint(.clear)
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

    private var resolvedMessage: String {
        message ?? "Effettua il login con Claude Code per vedere i tuoi limiti di sessione e settimanali."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s) {
            Label("Accesso a \(providerName) non rilevato", systemImage: "lock")
                .font(.dsHeadline)
            Text(resolvedMessage)
                .font(.dsCaption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: DS.Spacing.s) {
                Button("Come fare", action: onHowTo)
                    .buttonStyle(.glass).tint(.clear)
                Button("Riconnetti", action: onReconnect)
                    .buttonStyle(.glassProminent)
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
            title: "Limiti sessione non disponibili",
            message: "Le finestre 5h/settimana richiedono un piano Max. Le analytics locali restano disponibili."
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

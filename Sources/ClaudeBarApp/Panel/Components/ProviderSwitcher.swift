import SwiftUI

// MARK: - ProviderSwitcher (MP-6 — selettore del provider visualizzato nel pannello)
//
// Compatto, vetro NEUTRO (DECISIONS §3): una pillola con un segmento per provider abilitato
// (SF Symbol + nome corto + pallino di stato). Mostrato dal `PanelContentView` SOLO se ci sono
// ≥2 provider abilitati; con 1 solo provider non compare e il pannello resta identico all'MVP.
//
// Branding neutro: nessun colore di brand. Il pallino di stato usa la scala semantica del % usato
// (coerente con anello/icona) quando disponibile; altrimenti è assente.

struct ProviderSwitcher: View {
    let providers: [ProviderChipVM]
    let activeID: String?
    let onSelect: (String) -> Void

    var body: some View {
        // Per restare leggibile a 6 provider: il chip ATTIVO mostra logo + nome + pallino,
        // gli INATTIVI collassano a solo-logo (+ pallino) con tooltip. Se la riga eccede
        // comunque, scorre orizzontalmente invece di troncare i nomi a "C…".
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DS.Spacing.xs) {
                ForEach(providers) { provider in
                    segment(for: provider)
                }
            }
            .padding(DS.Spacing.xxs)
            .animation(DS.Motion.soft, value: activeID)
        }
        .scrollClipDisabled()
        .background {
            Capsule(style: .continuous)
                .fill(Color.primary.opacity(0.06))
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Provider selector")
    }

    @ViewBuilder
    private func segment(for provider: ProviderChipVM) -> some View {
        let isActive = provider.id == activeID
        Button {
            onSelect(provider.id)
        } label: {
            HStack(spacing: 5) {
                ProviderGlyph(providerID: provider.id, fallbackSymbol: provider.symbol, size: 12)
                // Nome solo sul chip attivo → compatto e leggibile anche con 6 provider.
                if isActive {
                    Text(provider.name)
                        .font(.dsCaption.weight(.semibold))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .transition(.opacity.combined(with: .move(edge: .leading)))
                }
                if let used = provider.stateColorUsed {
                    Circle()
                        .fill(UsageColorScale.color(used: used))
                        .frame(width: 5, height: 5)
                }
            }
            .padding(.horizontal, isActive ? DS.Spacing.s : DS.Spacing.xs)
            .padding(.vertical, DS.Spacing.xs)
            .foregroundStyle(isActive ? Color.primary : Color.secondary)
            .background {
                if isActive {
                    Capsule(style: .continuous)
                        .fill(Color.primary.opacity(0.10))
                }
            }
            // Hover sui chip inattivi: affordance "cliccabile" (il puntatore è il primo input su macOS).
            .dsHoverHighlight(in: Capsule(style: .continuous), hover: isActive ? 0 : 0.08)
        }
        .buttonStyle(.plain)
        // Tooltip sui chip collassati (e utile anche su quello attivo) per non perdere il nome.
        .help(provider.name)
        .accessibilityLabel(provider.name)
        .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
    }
}

#Preview("ProviderSwitcher") {
    ProviderSwitcher(
        providers: [
            ProviderChipVM(id: "claude", name: "Claude", symbol: "sparkles", stateColorUsed: 62),
            ProviderChipVM(id: "openai_api", name: "OpenAI", symbol: "key.horizontal", stateColorUsed: nil),
            ProviderChipVM(id: "gemini", name: "Gemini", symbol: "diamond", stateColorUsed: 18),
        ],
        activeID: "claude",
        onSelect: { _ in })
        .padding(40)
}

#Preview("ProviderSwitcher — 6 provider") {
    ProviderSwitcher(
        providers: [
            ProviderChipVM(id: "claude", name: "Claude", symbol: "sparkles", stateColorUsed: 62),
            ProviderChipVM(id: "codex", name: "Codex", symbol: "chevron.left.forwardslash.chevron.right", stateColorUsed: 41),
            ProviderChipVM(id: "gemini", name: "Gemini", symbol: "diamond", stateColorUsed: 18),
            ProviderChipVM(id: "cursor", name: "Cursor", symbol: "cursorarrow", stateColorUsed: nil),
            ProviderChipVM(id: "anthropic_api", name: "Anthropic", symbol: "key.horizontal", stateColorUsed: 88),
            ProviderChipVM(id: "openai_api", name: "OpenAI", symbol: "key.horizontal", stateColorUsed: 7),
        ],
        activeID: "claude",
        onSelect: { _ in })
        .frame(width: 320)
        .padding(40)
}

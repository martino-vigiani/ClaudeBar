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
        HStack(spacing: DS.Spacing.xs) {
            ForEach(providers) { provider in
                segment(for: provider)
            }
        }
        .padding(DS.Spacing.xxs)
        .background {
            Capsule(style: .continuous)
                .fill(Color.primary.opacity(0.06))
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Selettore provider")
    }

    @ViewBuilder
    private func segment(for provider: ProviderChipVM) -> some View {
        let isActive = provider.id == activeID
        Button {
            onSelect(provider.id)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: provider.symbol)
                    .font(.system(size: 11, weight: .medium))
                Text(provider.name)
                    .font(.dsCaption.weight(isActive ? .semibold : .regular))
                    .lineLimit(1)
                if let used = provider.stateColorUsed {
                    Circle()
                        .fill(UsageColorScale.color(used: used))
                        .frame(width: 5, height: 5)
                }
            }
            .padding(.horizontal, DS.Spacing.s)
            .padding(.vertical, DS.Spacing.xs)
            .foregroundStyle(isActive ? Color.primary : Color.secondary)
            .background {
                if isActive {
                    Capsule(style: .continuous)
                        .fill(Color.primary.opacity(0.10))
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .animation(DS.Motion.soft, value: isActive)
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

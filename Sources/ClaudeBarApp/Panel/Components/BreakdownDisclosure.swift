import SwiftUI

// MARK: - Breakdown DisclosureGroup (condiviso)
//
// Disclosure leggera "vetro neutro" usata sia da AnalyticsSection (By model / By project)
// sia da UsageCostSection (By model dei provider a consumo): header con count + chevron
// con hover scoped, righe espandibili con barra GeometryReader, transizione clippata.
// `showCost` sceglie se il valore mostrato è costo o token.

struct BreakdownDisclosure: View {
    let title: String
    let items: [BreakdownItem]
    let showCost: Bool
    @State private var open = false
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var maxValue: Double {
        max(1, items.map { showCost ? $0.cost : Double($0.tokens) }.max() ?? 1)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header: cliccabile su TUTTA la pill (vedi .contentShape + .onTapGesture sotto).
            HStack(spacing: DS.Spacing.s) {
                Text(title).font(.dsHeadline)
                Spacer()
                if !items.isEmpty {
                    Text("\(items.count)")
                        .font(.dsCaption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                // Hover scoped al solo chevron: tingere il chevron non deve far rivalutare
                // l'intera card (con i suoi GeometryReader) — quindi @State hover e animazione
                // vivono qui, non sul wrapper.
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(open || hovering ? Color.primary : Color.secondary)
                    .rotationEffect(.degrees(open ? 90 : 0))
                    .onHover { hovering = $0 }
                    .animation(reduceMotion ? nil : DS.Motion.hover, value: hovering)
            }

            if open {
                Group {
                    if items.isEmpty {
                        Text("No data in this period")
                            .font(.dsCaption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, DS.Spacing.s)
                    } else {
                        VStack(spacing: DS.Spacing.s) {
                            ForEach(items) { item in
                                let value = showCost ? item.cost : Double(item.tokens)
                                HStack(spacing: DS.Spacing.s) {
                                    Image(systemName: item.symbol)
                                        .font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 14)
                                    Text(item.label)
                                        .font(.dsBody)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                        .frame(width: 120, alignment: .leading)
                                    GeometryReader { geo in
                                        ZStack(alignment: .leading) {
                                            Capsule().fill(Color.primary.opacity(0.08))
                                            Capsule()
                                                .fill(Color.primary.opacity(0.45))
                                                .frame(width: max(4, geo.size.width * (value / maxValue)))
                                        }
                                    }
                                    .frame(height: 6)
                                    Text(showCost ? item.cost.currencyString : item.tokens.compactString)
                                        .font(.dsMono).foregroundStyle(.secondary)
                                        .frame(width: 52, alignment: .trailing)
                                }
                            }
                        }
                        .padding(.top, DS.Spacing.s)
                    }
                }
                // `.move(edge: .top)` farebbe scivolare le righe SOPRA l'header durante la
                // transizione: clippiamo il contenuto espandibile ai propri bounds così
                // l'entrata/uscita resta dentro il blocco e non sovrasta il titolo.
                .clipped()
                .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(DS.Spacing.m)
        .contentShape(Rectangle()) // tutta la pill (anche i bordi) è area di tap
        .dsCardBezel()
        .onTapGesture { withAnimation(reduceMotion ? nil : DS.Motion.soft) { open.toggle() } }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(open ? Text("\(title), expanded") : Text("\(title), collapsed"))
        .animation(reduceMotion ? nil : DS.Motion.soft, value: open)
        // Reset hover quando il pannello si nasconde: senza mouse-exit (panel chiuso da
        // fuori) lo stato hover resterebbe acceso al riapri. Notification dal panel-host.
        .onReceive(NotificationCenter.default.publisher(for: .claudeBarPanelDidHide)) { _ in
            hovering = false
        }
    }
}

#Preview("BreakdownDisclosure") {
    let items = [
        BreakdownItem(label: "claude-opus-4", cost: 22.0, tokens: 2_000_000, symbol: "cube"),
        BreakdownItem(label: "claude-sonnet-4", cost: 12.1, tokens: 1_400_000, symbol: "cube"),
    ]
    return VStack(spacing: DS.Spacing.s) {
        BreakdownDisclosure(title: "By model", items: items, showCost: true)
        BreakdownDisclosure(title: "By project", items: [], showCost: false)
    }
    .padding(20)
    .frame(width: 360)
}

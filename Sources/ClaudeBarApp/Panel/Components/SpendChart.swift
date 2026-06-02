import SwiftUI
import Charts

// MARK: - SpendChart (Swift Charts)
//
// Grafico area+line di spesa o token nel tempo. Sfondo NEUTRO (niente glass dietro
// i numeri → leggibilità). Ingresso animato. Hover su mac → RuleMark + annotation
// col valore (HIG charts: tooltip on hover).

struct SpendChart: View {
    let series: [SpendPoint]
    /// true = mostra costo; false = mostra token.
    var showCost: Bool = true

    @State private var hovered: SpendPoint?
    @State private var appeared = false

    private func value(_ p: SpendPoint) -> Double {
        showCost ? p.cost : Double(p.tokens)
    }

    var body: some View {
        Chart {
            ForEach(series) { point in
                let v = value(point)

                AreaMark(
                    x: .value("Quando", point.date),
                    y: .value("Valore", appeared ? v : 0)
                )
                .interpolationMethod(.catmullRom)
                .foregroundStyle(
                    .linearGradient(
                        colors: [Color.primary.opacity(0.22), Color.primary.opacity(0.02)],
                        startPoint: .top, endPoint: .bottom)
                )

                LineMark(
                    x: .value("Quando", point.date),
                    y: .value("Valore", appeared ? v : 0)
                )
                .interpolationMethod(.catmullRom)
                .foregroundStyle(Color.primary.opacity(0.85))
                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
            }

            if let hovered {
                RuleMark(x: .value("Quando", hovered.date))
                    .foregroundStyle(Color.primary.opacity(0.25))
                    .annotation(position: .top, alignment: .center, spacing: 4) {
                        Text(showCost ? hovered.cost.currencyString : hovered.tokens.compactString)
                            .font(.dsMono)
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                    }
                PointMark(
                    x: .value("Quando", hovered.date),
                    y: .value("Valore", value(hovered))
                )
                .foregroundStyle(Color.primary)
                .symbolSize(60)
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) {
                AxisGridLine().foregroundStyle(Color.primary.opacity(0.05))
                AxisValueLabel().font(.system(size: 9)).foregroundStyle(.tertiary)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) {
                AxisGridLine().foregroundStyle(Color.primary.opacity(0.05))
                AxisValueLabel().font(.system(size: 9)).foregroundStyle(.tertiary)
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            hovered = nearestPoint(to: location, proxy: proxy, geo: geo)
                        case .ended:
                            hovered = nil
                        }
                    }
            }
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.6)) { appeared = true }
        }
        .accessibilityLabel("Andamento \(showCost ? "spesa" : "token")")
    }

    private func nearestPoint(to location: CGPoint, proxy: ChartProxy, geo: GeometryProxy) -> SpendPoint? {
        guard let plotFrame = proxy.plotFrame else { return nil }
        let xPos = location.x - geo[plotFrame].origin.x
        guard let date: Date = proxy.value(atX: xPos) else { return nil }
        return series.min(by: {
            abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date))
        })
    }
}

#Preview("SpendChart") {
    SpendChart(series: MockPanelViewModel.sampleAnalytics(range: .week).series, showCost: true)
        .frame(width: 320, height: 120)
        .padding()
}

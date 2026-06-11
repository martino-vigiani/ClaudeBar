import SwiftUI

// MARK: - LimitsSection (Fascia A — i limiti ufficiali)
//
// I due anelli grandi (Sessione 5h + Settimana) affiancati, ciascuno con eyebrow,
// anello = % usato, countdown reset (relativo + assoluto) e — sotto — la BARRA PACE
// & FORECAST per la finestra (DECISIONS.md feature chiave). Eventuali cap per-modello
// (Opus/Sonnet) sono mostrati sotto come righe compatte.

struct LimitsSection: View {
    let windows: [UsageWindowVM]
    @Binding var showUsed: Bool
    /// Collassata: mostra solo i 2 anelli (niente reset/pace/cap) → fascia compatta.
    var collapsed: Bool = false

    private var primary: [UsageWindowVM] {
        windows.filter { $0.kind == .session || $0.kind == .weekly }
    }
    private var caps: [UsageWindowVM] {
        windows.filter { $0.kind == .weeklyOpus || $0.kind == .weeklySonnet }
    }

    var body: some View {
        VStack(spacing: collapsed ? DS.Spacing.s : DS.Spacing.l) {
            // Due anelli grandi affiancati.
            HStack(alignment: .top, spacing: DS.Spacing.l) {
                ForEach(primary) { window in
                    WindowColumn(window: window, showUsed: $showUsed, collapsed: collapsed)
                        .frame(maxWidth: .infinity)
                }
            }

            // Cap per-modello (se presenti) — nascosti quando collassato.
            if !collapsed, !caps.isEmpty {
                VStack(spacing: DS.Spacing.s) {
                    ForEach(caps) { cap in
                        CapRow(window: cap)
                    }
                }
                .padding(DS.Spacing.m)
                .dsCardBezel()
            }
        }
    }
}

// MARK: - Colonna di una finestra (anello + reset + pace)

private struct WindowColumn: View {
    let window: UsageWindowVM
    @Binding var showUsed: Bool
    var collapsed: Bool = false

    var body: some View {
        VStack(spacing: DS.Spacing.s) {
            EyebrowTag(text: window.eyebrow, symbol: window.kind.symbol)

            UsageRing(window: window, showUsed: $showUsed)

            // Reset + Pace solo in modalità estesa: nello stato collassato resta il solo anello.
            if !collapsed {
                ResetCountdown(resetsAt: window.resetsAt, kind: window.kind)

                if window.pace != nil {
                    PaceBar(window: window)
                        .padding(.top, DS.Spacing.xxs)
                }
            }
        }
    }
}

// MARK: - Riga cap per-modello (compatta)

private struct CapRow: View {
    let window: UsageWindowVM

    var body: some View {
        HStack(spacing: DS.Spacing.s) {
            Image(systemName: window.kind.symbol)
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(window.eyebrow.capitalized)
                .font(.dsHeadline)
            Spacer(minLength: DS.Spacing.s)
            // Mini barra colorata.
            MiniUsageBar(used: window.utilization)
                .frame(width: 70)
            Text("\(Int(window.utilization.rounded()))%")
                .font(.dsMono)
                .foregroundStyle(.primary)
                .frame(width: 40, alignment: .trailing)
        }
    }
}

// MARK: - Mini barra usata (riusabile)

struct MiniUsageBar: View {
    let used: Double
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.10))
                Capsule()
                    .fill(UsageColorScale.color(used: used))
                    .frame(width: max(6, geo.size.width * min(1, used / 100)))
                    .animation(DS.Motion.smooth, value: used)
            }
        }
        .frame(height: 6)
    }
}

// MARK: - Eyebrow tag

struct EyebrowTag: View {
    let text: String
    var symbol: String?
    var body: some View {
        HStack(spacing: 4) {
            if let symbol {
                Image(systemName: symbol).font(.system(size: 9, weight: .semibold))
            }
            Text(text)
                .font(.dsEyebrow)
                .tracking(0.6)
        }
        .foregroundStyle(.secondary)
    }
}

// MARK: - Countdown reset

struct ResetCountdown: View {
    let resetsAt: Date
    let kind: WindowKind

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let remaining = max(0, resetsAt.timeIntervalSince(context.date))
            Text("reset \(relative(remaining)) · \(absolute)")
                .font(.dsMono)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .contentTransition(.numericText())
        }
    }

    private func relative(_ secs: TimeInterval) -> String {
        let t = Int(secs)
        let d = t / 86400, h = (t % 86400) / 3600, m = (t % 3600) / 60
        if d > 0 { return "\(d)d \(h)h" }
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }

    private var absolute: String {
        // Sessione: ora del giorno. Settimana: giorno + ora. Formatter STATICI: allocare un
        // `DateFormatter` è costoso e questa computed gira a ogni body eval.
        (kind == .session ? Self.timeFormatter : Self.dayTimeFormatter).string(from: resetsAt)
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = .current
        f.setLocalizedDateFormatFromTemplate("HH:mm")
        return f
    }()

    private static let dayTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = .current
        f.setLocalizedDateFormatFromTemplate("EEE HH:mm")
        return f
    }()
}

#Preview("LimitsSection") {
    LimitsSection(windows: MockPanelViewModel.sampleWindows(),
                  showUsed: .constant(true))
        .padding(20)
        .frame(width: 360)
}

import SwiftUI

/// Sezione NOTIFICHE delle Impostazioni (SET-3).
///
/// Ogni controllo è già CABLATO al comportamento reale: l'`AppModel.evaluateNotifications`
/// passa `settings.sessionThresholds` (% USATO) + `settings.notificationSound` a
/// `AppNotifications.evaluateSessionThresholds(thresholds:sound:)` / `evaluateWeeklyReset(sound:)`.
/// La de-dup per ciclo di reset è dentro `AppNotifications` (DECISIONS §4); qui si configura solo
/// COSA notificare. Vetro NEUTRO: nessuna tinta, niente `.glassEffect()` sul contenuto.
struct NotificationsSettingsSection: View {
    @Bindable var settings: SettingsStore

    var body: some View {
        SettingsSectionScaffold(section: .notifications) {
            self.masterGroup
            self.sessionGroup
            self.weeklyGroup
        }
    }

    // MARK: Suono (interruttore trasversale a tutte le notifiche)

    private var masterGroup: some View {
        SettingsGroup(
            "Sound",
            footnote: "With sound off, notifications arrive silently.")
        {
            Toggle("Play a sound", isOn: self.$settings.notificationSound)
                .toggleStyle(.switch)
        }
    }

    // MARK: Sessione 5h — abilita + soglie editabili

    private var sessionGroup: some View {
        SettingsGroup(
            "5h session",
            footnote: "One notification per threshold per cycle: when the window expires the thresholds rearm.")
        {
            Toggle("Notify when thresholds are reached", isOn: self.$settings.notifyOnSessionThreshold)
                .toggleStyle(.switch)

            if self.settings.notifyOnSessionThreshold {
                Divider()
                ThresholdEditor(thresholds: self.$settings.sessionThresholds)
            }
        }
    }

    // MARK: Reset settimanale — celebrazione

    private var weeklyGroup: some View {
        SettingsGroup(
            "Weekly",
            footnote: "When the weekly limit resets you get a reset notification.")
        {
            Toggle("Celebrate the weekly reset", isOn: self.$settings.notifyOnWeeklyReset)
                .toggleStyle(.switch)
        }
    }
}

// MARK: - Editor delle soglie (% usato)
//
// Mostra le soglie correnti come "chip" rimovibili (in scala di grigi, vetro neutro) + un campo
// per aggiungerne di nuove. Il modello normalizza in-place (clamp 1...99, dedup, ordina) via
// `SettingsStore.normalizeThresholds`, quindi qui non serve replicare la validazione: si propone
// e si lascia che il setter pulisca. Le soglie sono in % USATO (coerente col LOCK glance).

private struct ThresholdEditor: View {
    @Binding var thresholds: [Int]

    @State private var draft: String = ""
    @FocusState private var fieldFocused: Bool

    /// Soglia digitata valida (1...99) e non già presente.
    private var pendingValue: Int? {
        guard let value = Int(self.draft.trimmingCharacters(in: .whitespaces)),
              (1...99).contains(value),
              !self.thresholds.contains(value)
        else { return nil }
        return value
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.m) {
            Text("Warning thresholds (% used)")
                .font(.dsCaption.weight(.semibold))
                .textCase(.uppercase)
                .kerning(0.4)
                .foregroundStyle(.secondary)

            if self.thresholds.isEmpty {
                Text("No thresholds: you won't get session warnings until you add one.")
                    .font(.dsCaption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                self.chips
            }

            self.addRow
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // Chip in flusso a capo (FlowLayout): un pill per ogni soglia, con "x" per rimuovere.
    private var chips: some View {
        ThresholdFlowLayout(spacing: DS.Spacing.s) {
            ForEach(self.thresholds, id: \.self) { value in
                ThresholdChip(value: value) { self.remove(value) }
            }
        }
    }

    // Riga "aggiungi soglia": campo numerico breve + suffisso "%" + bottone Add.
    //
    // FIX layout: dentro un `Form`, `TextField("80", text:)` interpreta "80" come ETICHETTA del
    // campo e la mostra a SINISTRA del box (autolabeling di Form) → "80" finiva fuori dal campo.
    // Soluzione: etichetta nascosta (`.labelsHidden()`) e "80" passato come `prompt:` così è il
    // vero placeholder grigio DENTRO il campo. Larghezza 56pt + `.lineLimit(1)` per riga singola.
    private var addRow: some View {
        HStack(spacing: DS.Spacing.s) {
            TextField("threshold", text: self.$draft, prompt: Text(verbatim: "80"))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .lineLimit(1)
                .frame(width: 56)
                .focused(self.$fieldFocused)
                .onSubmit { self.commitDraft() }
            Text("%")
                .font(.dsBody)
                .foregroundStyle(.secondary)
            Button("Add") { self.commitDraft() }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(self.pendingValue == nil)
            Spacer()
        }
    }

    private func commitDraft() {
        guard let value = self.pendingValue else { return }
        // Il setter normalizza (dedup/clamp/ordina); aggiungiamo e lasciamo fare al modello.
        self.thresholds = self.thresholds + [value]
        self.draft = ""
        self.fieldFocused = true
    }

    private func remove(_ value: Int) {
        withAnimation(DS.Motion.soft) {
            self.thresholds = self.thresholds.filter { $0 != value }
        }
    }
}

// MARK: - Chip soglia

private struct ThresholdChip: View {
    let value: Int
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: DS.Spacing.xs) {
            Text("\(self.value)%")
                .font(.dsMono)
                .foregroundStyle(.primary)
            Button(action: self.onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    // Tondino neutro dietro la "x": hit target più ampio e look più rifinito.
                    .frame(width: 14, height: 14)
                    .background(Circle().fill(Color.primary.opacity(0.06)))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove threshold \(self.value)%")
        }
        .padding(.leading, DS.Spacing.m)
        .padding(.trailing, DS.Spacing.xs)
        .padding(.vertical, DS.Spacing.xs)
        // Capsule neutra (vetro monocromo): sfondo tenue + hairline appena percettibile.
        .background(Capsule(style: .continuous).fill(Color.primary.opacity(0.08)))
        .overlay(Capsule(style: .continuous).strokeBorder(Color.primary.opacity(0.06), lineWidth: 1))
    }
}

// MARK: - Layout a flusso (wrap) per le chip
//
// Mini-implementazione di un layout che dispone le sottoview in righe, andando a capo quando
// non c'è più spazio. Evita dipendenze esterne e resta coerente col vetro neutro (nessuno stile).

private struct ThresholdFlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        // Larghezza disponibile: se la proposta è infinita (caso degenere), disponiamo su una
        // riga sola sommando le larghezze. In pratica il layout vive in un GroupBox a larghezza
        // finita, quindi va a capo correttamente.
        let maxWidth = (proposal.width.flatMap { $0.isFinite ? $0 : nil }) ?? .greatestFiniteMagnitude
        let rows = self.layout(subviews: subviews, maxWidth: maxWidth)
        let height = rows.last.map { $0.y + $0.rowHeight } ?? 0
        let usedWidth = rows.map { row in
            row.items.reduce(CGFloat.zero) { partial, item in
                max(partial, item.x + subviews[item.index].sizeThatFits(.unspecified).width)
            }
        }.max() ?? 0
        return CGSize(width: proposal.width ?? usedWidth, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        let rows = self.layout(subviews: subviews, maxWidth: bounds.width)
        for row in rows {
            for item in row.items {
                let size = subviews[item.index].sizeThatFits(.unspecified)
                subviews[item.index].place(
                    at: CGPoint(x: bounds.minX + item.x, y: bounds.minY + row.y),
                    proposal: ProposedViewSize(size))
            }
        }
    }

    // Calcola la disposizione in righe.
    private struct Item { let index: Int; let x: CGFloat }
    private struct Row { var items: [Item] = []; var y: CGFloat = 0; var rowHeight: CGFloat = 0 }

    private func layout(subviews: Subviews, maxWidth: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        var x: CGFloat = 0
        var y: CGFloat = 0
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                current.y = y
                rows.append(current)
                y += current.rowHeight + self.spacing
                current = Row()
                x = 0
            }
            current.items.append(Item(index: index, x: x))
            current.rowHeight = max(current.rowHeight, size.height)
            x += size.width + self.spacing
        }
        if !current.items.isEmpty {
            current.y = y
            rows.append(current)
        }
        return rows
    }
}

#Preview("Notifiche") {
    NotificationsSettingsSection(settings: SettingsStore())
        .frame(width: 484, height: 560)
}

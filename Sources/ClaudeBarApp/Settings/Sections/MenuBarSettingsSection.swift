import ClaudeBarCore
import SwiftUI

/// Sezione MENU BAR / ICONA delle Impostazioni (SET-2).
///
/// Copre l'aspetto del glance nella status bar: stile dell'anello (singolo / sessione+settimana),
/// percentuale numerica (on/off + usato/rimanente), icona monocromatica, pulsazione su critico e
/// soglie di stato. Ogni controllo si lega al `SettingsStore` (@Observable): la persistenza e la
/// propagazione live all'icona (`recomputeGlance` → `StatusItemController.updateGlance`) avvengono
/// nei `didSet`/`onChange` del modello, quindi al cambio l'icona reale si aggiorna subito.
///
/// In cima, un'**anteprima live** disegna l'icona con lo stesso `IconRenderer` della status bar,
/// così l'utente vede l'effetto delle scelte mentre le fa. NB (LOCK glance, DECISIONS): arco e
/// colore restano SEMPRE sull'% USATO; `numberContent` cambia solo il TESTO.
struct MenuBarSettingsSection: View {
    @Bindable var settings: SettingsStore

    var body: some View {
        SettingsSectionScaffold(section: .menuBar) {
            self.previewGroup
            self.styleGroup
            self.numberGroup
            self.thresholdsGroup
        }
    }

    // MARK: Anteprima live

    private var previewGroup: some View {
        SettingsGroup(
            "Anteprima",
            footnote: "L'anteprima usa lo stesso disegno della menu bar. Colore e riempimento seguono sempre la quota USATA.")
        {
            GlancePreviewStrip(settings: self.settings)
                .frame(maxWidth: .infinity)
                .padding(.vertical, DS.Spacing.xs)
        }
    }

    // MARK: Stile

    private var styleGroup: some View {
        SettingsGroup("Stile") {
            Picker("Anello", selection: self.$settings.glanceStyle) {
                Text("Singolo").tag(GlanceStyle.ring)
                Text("Sessione + settimana").tag(GlanceStyle.dualBar)
            }
            .pickerStyle(.segmented)

            Divider()

            Toggle("Icona monocromatica (B/N)", isOn: self.$settings.monochromeIcon)
                .toggleStyle(.switch)
            Text("In monocromatico il sistema ricolora l'icona come template B/N: utile per il massimo contrasto. Il colore semantico resta nel pannello.")
                .font(.dsCaption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            Toggle("Pulsa quando la quota è quasi esaurita", isOn: self.$settings.pulseOnCritical)
                .toggleStyle(.switch)
            Text("Quando l'uso supera la soglia critica massima l'icona pulsa lentamente. Rispetta «Riduci movimento».")
                .font(.dsCaption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Percentuale numerica

    private var numberGroup: some View {
        SettingsGroup(
            "Percentuale",
            footnote: self.settings.showPercentLabel
                ? "«Usato» mostra la quota consumata (es. 71%); «Rimanente» mostra quanto resta (es. 29%)."
                : "Senza percentuale l'icona resta il solo anello, più compatta.")
        {
            Toggle("Mostra la percentuale accanto all'anello", isOn: self.$settings.showPercentLabel)
                .toggleStyle(.switch)

            if self.settings.showPercentLabel {
                Divider()
                Picker("Il numero mostra", selection: self.$settings.numberContent) {
                    ForEach(GlanceNumberContent.allCases) { content in
                        Text(content.label).tag(content)
                    }
                }
                .pickerStyle(.segmented)
            }
        }
    }

    // MARK: Soglie di stato (sull'usato)

    private var thresholdsGroup: some View {
        SettingsGroup(
            "Soglie di stato",
            footnote: "A quale quota USATA l'icona passa allo stato di avviso e poi critico (etichetta nell'anteprima, pulsazione e notifiche). La tinta dell'anello segue una scala fissa, condivisa col pannello.")
        {
            ThresholdSlider(
                title: "Avviso (ambra)",
                value: self.$settings.warnThreshold,
                range: 0.30...0.80)
            Divider()
            ThresholdSlider(
                title: "Critico (rosso)",
                value: self.$settings.criticalThreshold,
                range: 0.70...0.98)
        }
    }
}

// MARK: - Slider di soglia (etichetta + slider + valore %)

/// Riga "etichetta · slider · valore %" per una soglia di stato. La soglia è una frazione 0...1
/// mostrata come percentuale intera.
private struct ThresholdSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>

    var body: some View {
        HStack(spacing: DS.Spacing.m) {
            Text(self.title)
                .font(.dsBody)
            Spacer(minLength: DS.Spacing.s)
            Slider(value: self.$value, in: self.range)
                .frame(width: 168)
            Text("\(Int((self.value * 100).rounded()))%")
                .font(.dsMono)
                .monospacedDigit()
                .frame(width: 42, alignment: .trailing)
        }
    }
}

// MARK: - Striscia di anteprima live dell'icona

/// Disegna l'icona della status bar (via `IconRenderer`, lo stesso usato a runtime) a più livelli
/// di USATO, così l'utente vede subito l'effetto di stile/percentuale/monocromo/soglie. È puramente
/// presentazionale: deriva la spec dalle preferenze correnti senza toccare l'AppModel.
///
/// Le soglie di stato pilotano lo STATO (etichetta OK/AMBRA/CRITICO/ESAURITO via `GlanceClassifier`
/// + soglia di pulsazione): muovere gli slider aggiorna in tempo reale l'etichetta sotto ogni
/// campione. Il COLORE dell'arco resta la curva canonica di `IconRenderer.color`, sorgente unica
/// condivisa con l'anello del pannello (non si scollega, per coerenza icona↔pannello — DECISIONS §5).
private struct GlancePreviewStrip: View {
    @Bindable var settings: SettingsStore

    /// Campioni di USATO rappresentativi (verde / ambra / rosso) per mostrare l'intera scala.
    private let samples: [Double] = [0.32, 0.72, 0.96]

    var body: some View {
        HStack(spacing: DS.Spacing.l) {
            ForEach(self.samples, id: \.self) { used in
                let state = self.state(forUsed: used)
                VStack(spacing: DS.Spacing.xs) {
                    GlanceIconView(image: self.icon(forUsed: used, state: state))
                    Text("\(Int((used * 100).rounded()))% usato")
                        .font(.dsCaption)
                        .foregroundStyle(.secondary)
                    Text(Self.stateLabel(state))
                        .font(.dsEyebrow)
                        .tracking(0.4)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    /// Classifica un campione con la STESSA `GlanceClassifier.state` del runtime, passando le soglie
    /// utente: così muovere gli slider «Soglie di stato» aggiorna lo stato (e l'etichetta) in tempo reale.
    private func state(forUsed used: Double) -> GlanceState {
        GlanceClassifier.state(
            used: used,
            warn: self.settings.warnThreshold,
            critical: self.settings.criticalThreshold)
    }

    /// Costruisce lo STESSO `GlanceIconSpec` del runtime (stile/percentLabel/monocromo) e lo
    /// renderizza con la stessa pipeline di `IconRenderer`: preview↔icona reale coincidono.
    /// "Option B" definitiva: le soglie utente pilotano lo STATO (`state` via `GlanceClassifier` →
    /// etichetta OK/AMBRA/CRITICO live), NON il COLORE dell'arco (curva canonica condivisa col pannello).
    private func icon(forUsed used: Double, state: GlanceState) -> NSImage {
        let weekly: Double? = self.settings.glanceStyle == .dualBar ? max(0, used - 0.20) : nil
        let spec = GlanceIconSpec(
            used: used,
            weeklyUsed: weekly,
            state: state,
            style: self.settings.glanceStyle,
            percentLabel: self.settings.percentLabel,
            monochrome: self.settings.monochromeIcon,
            appearance: .dark)
        // L'anteprima è statica (niente pulsazione animata): phase 0 → frame stabile.
        return IconRenderer.render(spec, phase: 0)
    }

    /// Etichetta breve dello stato del glance per l'anteprima (coerente con la scala colore).
    private static func stateLabel(_ state: GlanceState) -> String {
        switch state {
        case .ok: "OK"
        case .warn: "AMBRA"
        case .low: "BASSO"
        case .critical: "CRITICO"
        case .empty: "ESAURITO"
        }
    }
}

/// Mostra una `NSImage` dell'icona su una pillola scura che simula la menu bar, per leggere bene
/// il colore reale (non-template) indipendentemente dall'aspetto della finestra Impostazioni.
/// In modalità monocromatica l'immagine è un template B/N: SwiftUI la ricolora col `foregroundStyle`,
/// quindi forziamo il bianco per riprodurre l'aspetto in una menu bar scura (altrimenti sparirebbe).
private struct GlanceIconView: View {
    let image: NSImage

    var body: some View {
        Image(nsImage: self.image)
            .interpolation(.high)
            .foregroundStyle(.white)
            .frame(height: 18)
            .padding(.horizontal, DS.Spacing.s)
            .padding(.vertical, DS.Spacing.xs)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous)
                    .fill(Color.black.opacity(0.85)))
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.08), lineWidth: DS.Size.hairline))
    }
}

#Preview("Menu bar") {
    MenuBarSettingsSection(settings: SettingsStore())
        .frame(width: 484, height: 620)
}

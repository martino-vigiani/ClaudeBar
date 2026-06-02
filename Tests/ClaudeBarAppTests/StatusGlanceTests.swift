import AppKit
import Testing
@testable import ClaudeBarApp
@testable import ClaudeBarCore

// Test del layer app shell (core-engineer, IMPL-C): mappa colore del glance, classificazione
// stato, render dell'icona, intervalli di refresh, mappatura AppStatus→glance.

@Suite("Glance color scale")
struct GlanceColorTests {
    /// Il colore del glance deve diventare più rosso al crescere dell'USATO (LOCK semantica).
    @Test("Più usato → più rosso (componente R cresce, G cala da verde a rosso)")
    func colorGetsRedderWithUsage() {
        func srgb(_ used: Double) -> NSColor {
            IconRenderer.color(forUsed: used).usingColorSpace(.sRGB)!
        }
        let low = srgb(0.10)   // verde
        let mid = srgb(0.70)   // ambra
        let high = srgb(0.98)  // rosso

        // Il rosso non cala mai passando da verde→ambra→rosso.
        #expect(low.redComponent <= mid.redComponent + 0.001)
        // Il verde cala da ambra a rosso (più critico = meno verde).
        #expect(high.greenComponent < mid.greenComponent)
        // A pieno usato il rosso domina il verde.
        #expect(high.redComponent > high.greenComponent)
    }

    @Test("clamp fuori range non crasha ed è monotono ai bordi")
    func colorClampsOutOfRange() {
        let below = IconRenderer.color(forUsed: -1).usingColorSpace(.sRGB)!
        let zero = IconRenderer.color(forUsed: 0).usingColorSpace(.sRGB)!
        let above = IconRenderer.color(forUsed: 2).usingColorSpace(.sRGB)!
        let full = IconRenderer.color(forUsed: 1).usingColorSpace(.sRGB)!
        #expect(abs(below.redComponent - zero.redComponent) < 0.001)
        #expect(abs(above.redComponent - full.redComponent) < 0.001)
    }
}

@Suite("Glance classifier (soglie utente)")
struct GlanceClassifierTests {
    @Test("Soglie di default (0.60/0.85) replicano la classificazione di Core")
    func defaultsMatchCore() {
        let warn = GlanceThresholds.warn, critical = GlanceThresholds.critical
        for used in stride(from: 0.0, through: 1.0, by: 0.05) {
            #expect(
                GlanceClassifier.state(used: used, warn: warn, critical: critical)
                    == GlanceState.glanceState(forUsed: used))
        }
    }

    @Test("Soglie personalizzate spostano DOVE scattano ambra/rosso")
    func customThresholdsShiftState() {
        // Utente più prudente: ambra a 40%, rosso a 70%.
        #expect(GlanceClassifier.state(used: 0.45, warn: 0.40, critical: 0.70) == .warn)
        #expect(GlanceClassifier.state(used: 0.72, warn: 0.40, critical: 0.70) == .critical)
        #expect(GlanceClassifier.state(used: 0.30, warn: 0.40, critical: 0.70) == .ok)
    }

    @Test("Soglie invertite o estreme non producono stati incoerenti")
    func robustToInvalidThresholds() {
        // critical < warn → l'ordinamento difensivo tiene critical ≥ warn.
        let s = GlanceClassifier.state(used: 0.50, warn: 0.80, critical: 0.30)
        #expect(s == .ok) // sotto entrambe (warn=0.80, critical clampato a 0.80)
        // empty resta ancorata ≥ critical: a usato pieno pulsa sempre.
        #expect(GlanceClassifier.state(used: 1.0, warn: 0.40, critical: 0.70) == .empty)
    }
}

@Suite("Icon rendering")
struct IconRenderingTests {
    @Test("Icona a colori NON è template; monocroma È template")
    func templateFlag() {
        let colored = IconRenderer.render(GlanceIconSpec(used: 0.62, state: .warn))
        #expect(colored.isTemplate == false)

        let mono = IconRenderer.render(GlanceIconSpec(used: 0.62, state: .warn, monochrome: true))
        #expect(mono.isTemplate == true)
    }

    @Test("Il render produce un'immagine non vuota e cacha per chiave quantizzata")
    func rendersAndCaches() {
        let spec = GlanceIconSpec(used: 0.50, state: .ok)
        let a = IconRenderer.render(spec)
        let b = IconRenderer.render(spec)
        #expect(a.size.width > 0 && a.size.height > 0)
        // Stessa chiave quantizzata → stessa istanza dalla cache.
        #expect(a === b)
    }

    @Test("Mostrare la % allarga l'icona rispetto al solo anello")
    func percentLabelWidensIcon() {
        let ringOnly = IconRenderer.render(GlanceIconSpec(used: 0.71, state: .warn, percentLabel: .hidden))
        let withPercent = IconRenderer.render(GlanceIconSpec(used: 0.71, state: .warn, percentLabel: .used))
        #expect(withPercent.size.width > ringOnly.size.width)
    }
}

@Suite("AppStatus → glance")
struct AppStatusTests {
    @Test("Stati senza dato utile preferiscono glance neutro (mai rosso falso)")
    func neutralStates() {
        #expect(AppStatus.loading.prefersNeutralGlance)
        #expect(AppStatus.noSubscription.prefersNeutralGlance)
        #expect(AppStatus.keychainDenied.prefersNeutralGlance)
        #expect(AppStatus.offline.prefersNeutralGlance)
        #expect(AppStatus.ready.prefersNeutralGlance == false)
    }

    @Test("Stati 'vecchi' applicano il DIM")
    func dimStates() {
        #expect(AppStatus.stale(since: Date()).prefersDimGlance)
        #expect(AppStatus.offline.prefersDimGlance)
        #expect(AppStatus.ready.prefersDimGlance == false)
    }
}

@Suite("Refresh interval")
struct RefreshIntervalTests {
    @Test("manual non ha durata; gli altri sì")
    func durations() {
        #expect(RefreshInterval.manual.duration == nil)
        #expect(RefreshInterval.fiveMinutes.duration == .seconds(300))
        #expect(RefreshInterval.oneMinute.duration == .seconds(60))
    }

    @Test("Tutti i casi hanno una label non vuota")
    func labels() {
        for interval in RefreshInterval.allCases {
            #expect(!interval.label.isEmpty)
        }
    }
}

@Suite("Core glance classification (riuso soglie)")
struct CoreGlanceClassificationTests {
    @Test("Le soglie sull'usato classificano correttamente e pulse parte a ≥95%")
    func thresholds() {
        #expect(GlanceState.glanceState(forUsed: 0.10) == .ok)
        #expect(GlanceState.glanceState(forUsed: 0.70) == .warn)
        #expect(GlanceState.glanceState(forUsed: 0.90) == .critical)
        #expect(GlanceState.glanceState(forUsed: 0.97) == .empty)
        #expect(GlanceState.glanceState(forUsed: 0.97).shouldPulse)
        #expect(GlanceState.glanceState(forUsed: 0.50).shouldPulse == false)
    }
}

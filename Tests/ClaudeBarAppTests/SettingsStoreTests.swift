import Foundation
import Testing
@testable import ClaudeBarApp
@testable import ClaudeBarCore

// Test del MODELLO impostazioni unificato (SET-1, settings-architect): default sensati,
// persistenza con prefisso clbar., derivazioni e reset. Ogni test usa un UserDefaults isolato
// per non inquinare lo standard.

@MainActor
@Suite("Settings model")
struct SettingsStoreTests {

    private func isolatedDefaults() -> UserDefaults {
        let suite = "test.settings.\(UUID().uuidString)"
        return UserDefaults(suiteName: suite)!
    }

    @Test("Default sensati: senza tocchi, comportamento come oggi")
    func sensibleDefaults() {
        let settings = SettingsStore(defaults: self.isolatedDefaults())
        #expect(settings.refreshInterval == .fiveMinutes)
        #expect(settings.appearance == .system)
        #expect(settings.launchAtLogin == false)
        #expect(settings.refreshOnPanelOpen == true)
        #expect(settings.refreshOnWake == true)
        #expect(settings.glanceStyle == .ring)
        #expect(settings.showPercentLabel == true)
        #expect(settings.numberContent == .used)
        #expect(settings.monochromeIcon == false)
        #expect(settings.pulseOnCritical == true)
        #expect(settings.notifyOnSessionThreshold == true)
        #expect(settings.notifyOnWeeklyReset == true)
        #expect(settings.notificationSound == true)
        #expect(settings.sessionThresholds == [50, 75, 90])
        #expect(settings.defaultAnalyticsRange == .today)
        #expect(settings.includeSubagentsInAnalytics == true)
        #expect(settings.showCostDisclaimer == true)
        #expect(settings.pricingOverridePath == nil)
    }

    @Test("Refresh interval persiste e si ricarica")
    func refreshIntervalPersists() {
        let defaults = self.isolatedDefaults()
        let a = SettingsStore(defaults: defaults)
        a.refreshInterval = .thirtyMinutes
        let b = SettingsStore(defaults: defaults)
        #expect(b.refreshInterval == .thirtyMinutes)
    }

    @Test("Appearance persiste e si ricarica")
    func appearancePersists() {
        let defaults = self.isolatedDefaults()
        let a = SettingsStore(defaults: defaults)
        a.appearance = .dark
        let b = SettingsStore(defaults: defaults)
        #expect(b.appearance == .dark)
    }

    @Test("onChange è invocato a ogni modifica persistita")
    func onChangeFires() {
        let settings = SettingsStore(defaults: self.isolatedDefaults())
        var count = 0
        settings.onChange = { count += 1 }
        settings.refreshInterval = .oneMinute
        settings.appearance = .light
        settings.pulseOnCritical = false
        #expect(count == 3)
    }

    @Test("percentLabel deriva da showPercentLabel + numberContent")
    func percentLabelDerivation() {
        let settings = SettingsStore(defaults: self.isolatedDefaults())
        settings.showPercentLabel = true
        settings.numberContent = .used
        #expect(settings.percentLabel == .used)
        settings.numberContent = .remaining
        #expect(settings.percentLabel == .remaining)
        settings.showPercentLabel = false
        #expect(settings.percentLabel == .hidden)
    }

    @Test("numberContent mantiene allineata la chiave compat showUsedInsteadOfRemaining")
    func numberContentCompat() {
        let settings = SettingsStore(defaults: self.isolatedDefaults())
        settings.numberContent = .remaining
        #expect(settings.showUsedInsteadOfRemaining == false)
        settings.showUsedInsteadOfRemaining = true
        #expect(settings.numberContent == .used)
    }

    @Test("Soglie sessione: normalizzazione (clamp 1...99, dedup, ordina) e persistenza")
    func sessionThresholdsNormalizeAndPersist() {
        let defaults = self.isolatedDefaults()
        let a = SettingsStore(defaults: defaults)
        a.sessionThresholds = [90, 50, 50, 0, 200, 75]
        #expect(a.sessionThresholds == [1, 50, 75, 90, 99])
        let b = SettingsStore(defaults: defaults)
        #expect(b.sessionThresholds == [1, 50, 75, 90, 99])
    }

    @Test("resetToDefaults riporta tutto ai default")
    func resetRestoresDefaults() {
        let defaults = self.isolatedDefaults()
        let settings = SettingsStore(defaults: defaults)
        settings.refreshInterval = .manual
        settings.appearance = .dark
        settings.monochromeIcon = true
        settings.sessionThresholds = [42]
        settings.includeSubagentsInAnalytics = false
        settings.defaultAnalyticsRange = .month

        settings.resetToDefaults()

        #expect(settings.refreshInterval == .fiveMinutes)
        #expect(settings.appearance == .system)
        #expect(settings.monochromeIcon == false)
        #expect(settings.sessionThresholds == [50, 75, 90])
        #expect(settings.includeSubagentsInAnalytics == true)
        #expect(settings.defaultAnalyticsRange == .today)

        // E i default persistono dopo un reload.
        let reloaded = SettingsStore(defaults: defaults)
        #expect(reloaded.appearance == .system)
        #expect(reloaded.sessionThresholds == [50, 75, 90])
    }

    @Test("schemaVersion scritto al primo avvio")
    func schemaVersionWritten() {
        let defaults = self.isolatedDefaults()
        _ = SettingsStore(defaults: defaults)
        #expect(defaults.integer(forKey: "clbar.schemaVersion") == SettingsStore.schemaVersion)
    }

    // MARK: - Menu bar / icona (SET-2): proprietà legate dalla MenuBarSettingsSection

    @Test("Proprietà menu bar persistono e si ricaricano (stile, monocromo, pulsazione, soglie)")
    func menuBarPropertiesPersist() {
        let defaults = self.isolatedDefaults()
        let a = SettingsStore(defaults: defaults)
        a.glanceStyle = .dualBar
        a.monochromeIcon = true
        a.pulseOnCritical = false
        a.warnThreshold = 0.50
        a.criticalThreshold = 0.90

        let b = SettingsStore(defaults: defaults)
        #expect(b.glanceStyle == .dualBar)
        #expect(b.monochromeIcon == true)
        #expect(b.pulseOnCritical == false)
        #expect(b.warnThreshold == 0.50)
        #expect(b.criticalThreshold == 0.90)
    }
}

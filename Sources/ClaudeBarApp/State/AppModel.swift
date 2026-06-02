import AppKit
import ClaudeBarCore
import Foundation
import os

/// Coordinatore @Observable @MainActor: UNICA fonte di verità per la UI (02-app-architecture.md §11).
///
/// Possiede i riferimenti ai servizi dati (via protocolli di confine), allo scheduler e al watcher.
/// Pubblica su MainActor i risultati Sendable degli attori e li traduce in `glanceSpec`/`status`.
/// NON parsa né fa rete direttamente: coordina e basta.
@MainActor
@Observable
final class AppModel {
    // MARK: - Stato osservato dalla UI

    private(set) var status: AppStatus = .loading
    private(set) var glanceSpec: GlanceIconSpec = .loading
    private(set) var limits: LimitsSnapshot?
    /// Snapshot UNIFICATO del provider ATTIVO (MP-7). Per i provider a limiti (Claude/Codex/…)
    /// `limits` ne è la proiezione (glance/Pace); per i provider a consumo (OpenAI/Anthropic API)
    /// porta `cost`/`credits` e `limits` è `nil`. È la fonte per `usageCost`/`credits` nell'adapter.
    private(set) var activeSnapshot: ProviderSnapshot?
    private(set) var analytics: AnalyticsReport?
    /// Primo full-index in corso (§6.4); `nil` = idle.
    private(set) var indexingProgress: Double?
    /// `true` durante un fetch dei limiti (per lo spinner del bottone refresh nell'header).
    private(set) var isRefreshingLimits = false
    private(set) var lastLimitsRefresh: Date?
    private(set) var lastAnalyticsRefresh: Date?
    /// Range selezionato per la sezione analytics (gestito qui per l'adapter UI).
    /// Inizializzato dal default scelto in Impostazioni (`defaultAnalyticsRange`).
    var analyticsRange: AnalyticsRange

    // MARK: - Dipendenze

    private let limitsService: any LimitsServicing
    private let indexer: any TranscriptIndexing
    private let persistence: any PersistenceServicing
    let settings: SettingsStore
    private let notifications: AppNotifications

    /// Registry multi-provider (MP-7). Quando presente, il refresh interroga il PROVIDER ATTIVO
    /// (`settings.activeProviderID`) via la sua pipeline di strategie. Quando `nil` (path legacy /
    /// test), si usa `limitsService` (solo-Claude) com'era: comportamento Claude IDENTICO.
    private let registry: ProviderRegistry?

    /// Collegato dall'AppDelegate dopo l'install dello status item (evita ciclo di init).
    private weak var statusController: StatusItemController?

    /// Finestra Impostazioni gestita a mano (la scene `Settings` di SwiftUI non si apre in modo
    /// affidabile per un'app accessory). Creata pigramente al primo `openPreferences()`.
    private let settingsWindow = SettingsWindowController()

    private let logger = Logger(subsystem: AppInfo.bundleIdentifier, category: "app-model")

    // Errori dei due sottosistemi, tracciati separatamente e fusi in `status` con priorità.
    private var limitsError: AppStatus?
    private var analyticsError: String?

    /// Ultimo valore noto del flag "includi subagent": serve a `applySettingsChange()` per
    /// rilevarne il cambio (il callback `onChange` è globale e non dice COSA è cambiato) e
    /// forzare la rigenerazione del report aggregato — altrimenti il numero non cambierebbe.
    private var lastIncludeSubagents: Bool

    init(
        limitsService: any LimitsServicing,
        indexer: any TranscriptIndexing,
        persistence: any PersistenceServicing,
        settings: SettingsStore,
        notifications: AppNotifications = AppNotifications(),
        registry: ProviderRegistry? = nil)
    {
        self.limitsService = limitsService
        self.indexer = indexer
        self.persistence = persistence
        self.settings = settings
        self.notifications = notifications
        self.registry = registry
        self.analyticsRange = settings.defaultAnalyticsRange
        self.lastIncludeSubagents = settings.includeSubagentsInAnalytics
    }

    func attach(statusController: StatusItemController) {
        self.statusController = statusController
        self.statusController?.updateGlance(self.glanceSpec)
    }

    /// Aggiorna l'avanzamento del primo full-index (chiamato dal callback dell'indexer).
    /// `1.0` (o oltre) segna il completamento → torna a idle.
    func updateIndexingProgress(_ value: Double) {
        self.indexingProgress = value >= 1.0 ? nil : value
    }

    // MARK: - Ciclo di vita

    /// Carica la cache (paint immediato anche offline), poi avvia il primo refresh.
    func bootstrap() async {
        // 1) Cache su disco → glance/pannello istantanei.
        if let cachedLimits = await self.persistence.loadCachedLimits() {
            self.limits = cachedLimits
            self.lastLimitsRefresh = cachedLimits.fetchedAt
        }
        if let cachedReport = await self.persistence.loadCachedReport() {
            self.analytics = cachedReport
            self.lastAnalyticsRefresh = cachedReport.generatedAt
        }
        self.recomputeStatus()
        self.recomputeGlance()

        // 1b) Auto-detect multi-provider: riempie SOLO i vuoti (non sovrascrive le scelte manuali).
        //     Context no-UI per non far comparire prompt al boot.
        if let registry {
            let context = ProviderFetchContext(userInitiated: false)
            let updated = await registry.applyingAutoDetect(to: self.settings.multiProvider, context: context)
            if updated != self.settings.multiProvider {
                self.settings.multiProvider = updated
            }
        }

        // 2) Primo refresh in parallelo (analytics + limiti).
        async let analyticsTask: Void = self.refreshAnalytics(force: false)
        async let limitsTask: Void = self.refreshLimitsNow(userInitiated: false)
        _ = await (analyticsTask, limitsTask)
    }

    /// Cambia il provider ATTIVO (dallo switcher del pannello) e ri-fetcha subito i suoi dati.
    /// Resetta lo stato del provider precedente per evitare di mostrare dati misti durante il fetch.
    func setActiveProvider(_ id: ProviderID) {
        guard id != self.settings.activeProviderID else { return }
        self.settings.setDefaultProvider(id)
        // Stato transitorio pulito: l'icona/pannello tornano "loading" finché arriva il nuovo snapshot.
        self.limits = nil
        self.activeSnapshot = nil
        self.limitsError = nil
        self.status = .loading
        self.recomputeGlance()
        Task { await self.refreshLimitsNow(userInitiated: true) }
    }

    func shutdown() {
        self.statusController?.prepareForShutdown()
    }

    // MARK: - Azioni

    /// Refresh dei dati del provider ATTIVO. `userInitiated` → Keychain con prompt (§7.2).
    /// Con `registry == nil` (path legacy) usa il solo-Claude `limitsService` come l'MVP.
    func refreshLimitsNow(userInitiated: Bool) async {
        self.isRefreshingLimits = true
        defer { self.isRefreshingLimits = false }
        do {
            if let registry {
                try await self.fetchActiveProvider(registry: registry, userInitiated: userInitiated)
            } else {
                // Path legacy solo-Claude (identico all'MVP).
                let snapshot = try await self.limitsService.fetchUsage(userInitiated: userInitiated)
                self.applyLimits(snapshot)
            }
            self.limitsError = nil
        } catch {
            self.handleLimitsError(error)
        }
        self.recomputeStatus()
        self.recomputeGlance()
    }

    /// Fetcha lo snapshot unificato del provider attivo e ne aggiorna lo stato.
    /// - Per i provider a LIMITI: deriva `limits` (glance/Pace/notifiche riusano la pipeline esistente).
    /// - Per i provider a CONSUMO: `limits` resta nil, `activeSnapshot` porta cost/credits (vista costo).
    private func fetchActiveProvider(registry: ProviderRegistry, userInitiated: Bool) async throws {
        let activeID = self.settings.activeProviderID
        guard let provider = registry.provider(for: activeID) else {
            throw ProviderError.noAvailableStrategy(activeID)
        }
        let context = ProviderFetchContext(
            userInitiated: userInitiated,
            environment: ProcessInfo.processInfo.environment)
        let snapshot = try await provider.snapshot(context: context)
        self.activeSnapshot = snapshot
        self.lastLimitsRefresh = snapshot.fetchedAt

        if let derived = snapshot.asLimitsSnapshot() {
            // Provider a limiti: riusa la pipeline glance/Pace/notifiche esistente.
            self.applyLimits(derived)
        } else {
            // Provider a consumo: niente finestre-limite. La vista costo/credito vive
            // nell'adapter via `activeSnapshot`; l'icona resta neutra (nessun "rosso" falso).
            self.limits = nil
            self.persistLimitsCacheIfClaude(nil, providerID: activeID)
        }
    }

    /// Applica uno snapshot a limiti: aggiorna `limits`, persiste (solo Claude), valuta le notifiche.
    private func applyLimits(_ snapshot: LimitsSnapshot) {
        self.limits = snapshot
        self.lastLimitsRefresh = snapshot.fetchedAt
        // Sincronizza `activeSnapshot` anche sul path legacy (così l'adapter è sempre coerente).
        if self.activeSnapshot == nil || self.activeSnapshot?.providerID == .claude {
            self.activeSnapshot = snapshot.asProviderSnapshot()
        }
        Task { await self.persistence.saveLimits(snapshot) }
        self.evaluateNotifications(for: snapshot)
    }

    /// La cache su disco dei limiti è pensata per Claude (l'MVP). Per gli altri provider non
    /// persistiamo limiti su disco in v1 (nessuna regressione del path Claude). No-op per ora.
    private func persistLimitsCacheIfClaude(_: LimitsSnapshot?, providerID _: ProviderID) {}

    /// Ingest incrementale dei transcript (delegato all'indexer in Core). Il flag "includi subagent"
    /// (preferenza Impostazioni → Analytics) è passato a ogni refresh: cambiarlo e ri-aprire il
    /// pannello aggiorna gli aggregati senza re-parse dell'indice.
    func refreshAnalytics(force: Bool) async {
        do {
            let report = try await self.indexer.refresh(
                force: force,
                includeSubagents: self.settings.includeSubagentsInAnalytics)
            self.analytics = report
            self.lastAnalyticsRefresh = report.generatedAt
            self.analyticsError = nil
            await self.persistence.saveReport(report)
        } catch is CancellationError {
            // Ignorato: cancellazione su quit/cambio sorgente.
        } catch {
            self.analyticsError = error.localizedDescription
            self.logger.error("analytics refresh fallito: \(error.localizedDescription, privacy: .public)")
        }
        self.recomputeStatus()
    }

    /// Azzera la cache dell'indice (stato incrementale + file su disco + report aggregato) e
    /// ricostruisce da zero. Usata da "Azzera cache indice" (sezione Avanzato, SET-4).
    /// Pulisce prima ENTRAMBE le cache, poi `refresh(force: true)` rilegge i transcript da capo.
    func clearIndexCacheAndRebuild() async {
        await self.indexer.clearCache()
        await self.persistence.clearCache()
        self.analytics = nil
        self.lastAnalyticsRefresh = nil
        await self.refreshAnalytics(force: true)
    }

    /// Chiamata all'apertura del pannello: refresh on-demand se i dati sono vecchi (§4),
    /// salvo che l'utente abbia disattivato il refresh all'apertura.
    func panelDidOpen() {
        if self.settings.refreshOnPanelOpen {
            let freshnessThreshold: TimeInterval = 30
            let isStaleLimits = self.lastLimitsRefresh.map { Date().timeIntervalSince($0) > freshnessThreshold } ?? true
            if isStaleLimits {
                Task { await self.refreshLimitsNow(userInitiated: true) }
            }
        }
        Task { await self.refreshAnalytics(force: false) }
    }

    /// Reagisce a un cambio nelle impostazioni (interval/soglie/launchAtLogin/glance/aspetto).
    func applySettingsChange() {
        LaunchAtLoginManager.setEnabled(self.settings.launchAtLogin)
        self.applyAppearance()
        self.recomputeGlance()

        // "Includi subagent": se il flag è cambiato, rigenera il report aggregato col nuovo valore
        // (il refresh è incrementale, niente re-parse: la cache per-file resta valida, cambia solo
        // l'aggregazione). Senza questo, il numero mostrato non cambierebbe finché non si riapre il
        // pannello. Lo facciamo solo al cambio effettivo per non rigenerare a ogni altra preferenza.
        if self.settings.includeSubagentsInAnalytics != self.lastIncludeSubagents {
            self.lastIncludeSubagents = self.settings.includeSubagentsInAnalytics
            Task { await self.refreshAnalytics(force: false) }
        }
    }

    /// Impone l'aspetto scelto (`Sistema`/`Chiaro`/`Scuro`) alle finestre dell'app via `NSApp`.
    /// `.system` (nsAppearance == nil) lascia che l'app segua macOS.
    func applyAppearance() {
        NSApp?.appearance = self.settings.appearance.nsAppearance
    }

    /// Risveglio dal sleep / ritorno connettività → refresh on-demand (no-UI), se abilitato.
    func handleWake() {
        guard self.settings.refreshOnWake else { return }
        Task { await self.refreshLimitsNow(userInitiated: false) }
    }

    func openPreferences() {
        // Il pannello è un NSPanel floating a livello .statusBar non-activating: la finestra
        // Impostazioni si aprirebbe DIETRO di esso. Chiudilo prima, poi mostra la nostra finestra.
        self.statusController?.closePanel()
        self.settingsWindow.show(settings: self.settings)
    }

    func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - Glance (finestra più critica)

    /// Classifica lo STATO del glance sull'USATO usando le soglie utente (delega al classificatore
    /// condiviso `GlanceClassifier`, stessa logica usata dall'anteprima live nelle Impostazioni).
    private func classifyGlance(used: Double) -> GlanceState {
        GlanceClassifier.state(
            used: used,
            warn: self.settings.warnThreshold,
            critical: self.settings.criticalThreshold)
    }

    /// Ricalcola `glanceSpec` da (limits, settings, status) e aggiorna lo StatusItemController.
    /// La finestra di riferimento è la PIÙ CRITICA = max(utilization) (DECISIONS §2).
    private func recomputeGlance() {
        let spec: GlanceIconSpec

        // Glance del provider attivo a CONSUMO con credito noto: l'anello riflette la frazione di
        // budget consumata (DECISIONS: l'icona segue il provider attivo). Solo se non ci sono
        // finestre-limite e lo stato non è neutro/loading. I provider a consumo SENZA credito
        // restano neutri (niente rosso falso).
        let consumptionUsed: Double? = (self.limits == nil && !self.status.prefersNeutralGlance)
            ? self.activeSnapshot?.credits?.usedFraction
            : nil

        if self.status.prefersNeutralGlance || (self.limits == nil && consumptionUsed == nil) {
            spec = self.status == .loading
                ? GlanceIconSpec(
                    used: 0, state: .ok, style: self.settings.glanceStyle,
                    percentLabel: .hidden, monochrome: self.settings.monochromeIcon,
                    dim: true, animation: .loadingSpin, appearance: self.appearance)
                : GlanceIconSpec(
                    used: 0, state: .ok, style: self.settings.glanceStyle,
                    percentLabel: .hidden, monochrome: self.settings.monochromeIcon,
                    dim: true, appearance: self.appearance)
        } else if let consumptionUsed {
            // Provider a consumo con credito: anello = % budget consumato, niente Pace/finestre.
            let used = max(0, min(consumptionUsed, 1))
            let glanceState = self.classifyGlance(used: used)
            let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            let shouldPulse = glanceState.shouldPulse && self.settings.pulseOnCritical && !reduceMotion
            spec = GlanceIconSpec(
                used: used,
                state: glanceState,
                style: self.settings.glanceStyle,
                percentLabel: self.settings.percentLabel,
                monochrome: self.settings.monochromeIcon,
                dim: self.status.prefersDimGlance,
                animation: shouldPulse ? .pulse : .none,
                appearance: self.appearance)
        } else if let limits = self.limits {
            let critical = limits.mostCritical
            let usedFrac = max(0, min(critical.utilization / 100, 1))
            let weeklyFrac = self.settings.glanceStyle == .dualBar
                ? max(0, min(limits.sevenDay.utilization / 100, 1))
                : nil
            let glanceState = self.classifyGlance(used: usedFrac)
            let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            let animation: GlanceAnimation =
                (glanceState.shouldPulse && self.settings.pulseOnCritical && !reduceMotion) ? .pulse : .none

            spec = GlanceIconSpec(
                used: usedFrac,
                criticalKind: critical.kind,
                weeklyUsed: weeklyFrac,
                state: glanceState,
                style: self.settings.glanceStyle,
                percentLabel: self.settings.percentLabel,
                monochrome: self.settings.monochromeIcon,
                dim: self.status.prefersDimGlance,
                animation: animation,
                appearance: self.appearance)
        } else {
            spec = .neutral
        }

        self.glanceSpec = spec
        self.statusController?.updateGlance(spec)
    }

    private var appearance: GlanceAppearance {
        // `NSApp` può essere nil prima dell'avvio dell'app (o in ambiente headless/test): in quel
        // caso ripieghiamo su `.light` invece di crashare. A runtime `NSApp` è sempre presente.
        guard let app = NSApp else { return .light }
        let name = app.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua])
        return name == .darkAqua ? .dark : .light
    }

    // MARK: - Stato

    private func recomputeStatus() {
        // Priorità: token/subscription/keychain > offline > stale > generico > ready.
        if let limitsError {
            self.status = limitsError
            return
        }
        if let limits {
            self.status = limits.isStale ? .stale(since: limits.fetchedAt) : .ready
            return
        }
        // Provider a CONSUMO: niente limiti ma snapshot valido (cost/credits) → ready.
        if let activeSnapshot {
            self.status = activeSnapshot.isStale ? .stale(since: activeSnapshot.fetchedAt) : .ready
            return
        }
        // Nessun dato limiti ma analytics potrebbero esserci: comunque "loading" finché non arriva nulla.
        if self.analytics != nil {
            self.status = .ready
        } else {
            self.status = .loading
        }
    }

    private func handleLimitsError(_ error: Error) {
        // Su errore, il dato del provider attivo non è valido: azzera lo snapshot per non
        // mostrare cost/credito stantii di un provider che ora fallisce (l'icona va neutra).
        self.activeSnapshot = nil
        self.limits = nil
        self.limitsError = Self.mapProviderError(error, activeProvider: self.settings.activeProviderID)
        self.logger.error("provider refresh fallito: \(error.localizedDescription, privacy: .public)")
    }

    /// Mappa un errore del provider attivo su `AppStatus`. Gestisce sia `ProviderError`
    /// (multi-provider) sia `ClaudeLimitsError` (path legacy Claude) sia `URLError`.
    private static func mapProviderError(_ error: Error, activeProvider: ProviderID) -> AppStatus {
        if let providerError = error as? ProviderError {
            switch providerError {
            case .noCredentials, .refreshDelegatedToOwner:
                return .tokenExpired
            case let .unauthorized(message):
                // Per le API a consumo (Admin key org), il messaggio del provider è azionabile:
                // mostriamo l'avviso esplicito invece di "ri-autenticati" generico.
                if activeProvider == .anthropicAPI || activeProvider == .openaiAPI {
                    return .error(message: message ?? "Richiede una Admin key di account org. Inseriscila nelle Impostazioni.")
                }
                return .tokenExpired
            case .keychainDenied:
                return .keychainDenied
            case .rateLimited, .network:
                return providerError.isTerminal ? .error(message: providerError.localizedDescription) : .offline
            case let .serverError(code, _):
                return .error(message: "Errore server (HTTP \(code)).")
            case .invalidResponse:
                return .error(message: "Risposta non valida dall'endpoint del provider.")
            case let .noAvailableStrategy(id):
                // Provider abilitato ma non configurato → invito a configurarlo.
                return .error(message: "\(id.defaultDisplayName) non è configurato. Aprine le Impostazioni.")
            }
        }
        return Self.mapLimitsError(error)
    }

    /// Mappa gli errori tipizzati di `ClaudeLimitsError` 1:1 sugli stati UI (mapping concordato
    /// con data-engineer). `URLError` non incapsulato → offline/error.
    private static func mapLimitsError(_ error: Error) -> AppStatus {
        if let limitsError = error as? ClaudeLimitsError {
            switch limitsError {
            // Nessuna credenziale o token non valido → serve (ri)autenticarsi. L'adapter UI
            // mappa tokenExpired/keychainDenied → PanelState.noAuth (CTA "accedi a Claude Code").
            case .noCredentials, .unauthorized, .refreshDelegatedToCLI, .noRefreshToken, .refreshFailedTerminal:
                return .tokenExpired
            case .keychainDenied:
                return .keychainDenied
            case .rateLimited:
                // Degradazione elegante: se c'è cache, il service ritorna uno snapshot .stale e
                // non lancia. Se lancia, non abbiamo cache → mostra come stale "da adesso".
                return .stale(since: Date())
            case .network:
                return .offline
            case .refreshFailedTransient:
                return .stale(since: Date())
            case let .serverError(code, _):
                return .error(message: "Errore server (HTTP \(code)).")
            case .invalidResponse:
                return .error(message: "Risposta non valida dall'endpoint limiti.")
            }
        }

        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost, .timedOut:
                return .offline
            default:
                return .error(message: urlError.localizedDescription)
            }
        }
        return .error(message: error.localizedDescription)
    }

    // MARK: - Notifiche

    private func evaluateNotifications(for snapshot: LimitsSnapshot) {
        self.notifications.evaluateSessionThresholds(
            windowKey: PaceWindowKind.fiveHour.rawValue,
            usedPercent: snapshot.fiveHour.utilization,
            resetsAt: snapshot.fiveHour.resetsAt,
            enabled: self.settings.notifyOnSessionThreshold,
            thresholds: self.settings.sessionThresholds.map(Double.init),
            sound: self.settings.notificationSound)

        self.notifications.evaluateWeeklyReset(
            windowKey: PaceWindowKind.sevenDay.rawValue,
            resetsAt: snapshot.sevenDay.resetsAt,
            enabled: self.settings.notifyOnWeeklyReset,
            sound: self.settings.notificationSound)
    }
}

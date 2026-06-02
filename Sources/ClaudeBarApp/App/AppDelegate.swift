import AppKit
import ClaudeBarCore
import SwiftUI

/// Lifecycle + composition root dell'app (02-app-architecture.md §2, §12).
///
/// Menu bar app pura (LSUIElement): nessuna icona nel Dock, nessuna finestra principale.
/// Costruisce il grafo delle dipendenze, installa lo `StatusItemController` (che crea
/// l'`NSStatusItem`), avvia watcher + scheduler e fa il bootstrap dell'`AppModel`.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var model: AppModel?
    private var statusController: StatusItemController?
    private var fileWatcher: FileWatcher?
    private var scheduler: RefreshScheduler?
    private let settings = SettingsStore()
    private let notifications = AppNotifications()

    /// Esposto alla scene `Settings` (Preferenze) in `ClaudeBarMain`.
    var settingsStore: SettingsStore { self.settings }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Ridondante con LSUIElement, ma esplicito: agent, niente Dock.
        NSApp.setActivationPolicy(.accessory)

        // 1) Servizi dati REALI di ClaudeBarCore, avvolti nei thin adapter di confine
        //    (CoreServiceAdapters): ClaudeLimitsService / TranscriptIndexer / PersistenceService.
        //    Il progress del primo full-index fa hop sul MainActor verso l'AppModel.
        //    Lo STESSO `ClaudeLimitsService` è condiviso col `ProviderRegistry` (ClaudeProvider lo
        //    avvolge) → per Claude il comportamento resta identico all'MVP (cache, gate 429, refresh).
        let claudeService = ClaudeLimitsService()
        let limitsService = LimitsServiceAdapter(service: claudeService)
        let persistence = PersistenceServiceAdapter(service: PersistenceService())

        // Registry multi-provider (MP-7): tutti i provider abilitabili, segreti SEMPRE in Keychain.
        let registry = ProviderRegistryFactory.makeRegistry(claudeService: claudeService)

        // Relay del progress: il callback @Sendable dell'indexer (chiamato off-main) inoltra al
        // MainActor verso l'AppModel. Il relay è Sendable e viene collegato al model dopo la sua
        // creazione (evita di catturare una var locale mutabile, vietato da Swift 6 strict).
        let progressRelay = IndexingProgressRelay()
        let indexer = TranscriptIndexerAdapter(
            indexer: TranscriptIndexer(progress: { value in
                progressRelay.report(value)
            }))

        // 2) AppModel — unica fonte di verità.
        let model = AppModel(
            limitsService: limitsService,
            indexer: indexer,
            persistence: persistence,
            settings: self.settings,
            notifications: self.notifications,
            registry: registry)
        self.model = model
        progressRelay.attach(model)

        // 3) Le impostazioni propagano i cambiamenti all'AppModel + sottosistemi.
        self.settings.onChange = { [weak self] in
            self?.handleSettingsChange()
        }

        // 4) Host del pannello SwiftUI. La view (`PanelContentView`, ui-engineer) è generica sul
        //    protocollo presentazionale; le passiamo l'adapter `AppModelPanelAdapter` che traduce
        //    l'AppModel nei tipi VM della UI.
        let panelHost = PanelHostController { [weak model] in
            guard let model else { return AnyView(EmptyView()) }
            let adapter = AppModelPanelAdapter(model)
            return AnyView(PanelContentView(model: adapter))
        }

        // 5) StatusItemController + install.
        let statusController = StatusItemController(
            panelHost: panelHost,
            onRefresh: { [weak model] in
                Task { await model?.refreshLimitsNow(userInitiated: true) }
                Task { await model?.refreshAnalytics(force: false) }
            },
            onPreferences: { [weak model] in model?.openPreferences() },
            onQuit: { [weak model] in model?.quit() })
        statusController.attach(model: model)
        statusController.install()
        self.statusController = statusController

        // 6) Chiude il ciclo: l'AppModel pilota l'icona via il controller.
        model.attach(statusController: statusController)

        // 7) FileWatcher sui transcript root (Core conosce le varianti) → ingest delta (debounce ~2s).
        let transcriptRoot = AppPaths.transcriptRoots().first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".claude/projects", isDirectory: true)
        let watcher = FileWatcher(root: transcriptRoot) { [weak model] in
            await model?.refreshAnalytics(force: false)
        }
        watcher.start()
        self.fileWatcher = watcher

        // 8) Scheduler refresh limiti (no-UI Keychain).
        let scheduler = RefreshScheduler(interval: self.settings.refreshInterval) { [weak model] in
            await model?.refreshLimitsNow(userInitiated: false)
        }
        scheduler.start()
        self.scheduler = scheduler

        // 9) Notifiche (soft, non blocca) + observer di sistema.
        self.notifications.requestAuthorizationIfNeeded()
        self.installSystemObservers()

        // 10) Allinea launch-at-login allo stato reale del servizio.
        self.settings.launchAtLogin = LaunchAtLoginManager.isEnabled

        // 11) Applica l'aspetto scelto (Sistema/Chiaro/Scuro) alle finestre dell'app.
        model.applyAppearance()

        // 12) Bootstrap: cache → paint immediato → primo refresh.
        Task { await model.bootstrap() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false // è un agent
    }

    func applicationWillTerminate(_ notification: Notification) {
        self.fileWatcher?.stop()
        self.scheduler?.stop()
        self.model?.shutdown()
    }

    // MARK: - Observers di sistema

    private func installSystemObservers() {
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(
            self,
            selector: #selector(self.handleWake),
            name: NSWorkspace.didWakeNotification,
            object: nil)

        // Cambio appearance (dark/light) → ridisegna l'icona con il contrasto corretto.
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(self.handleAppearanceChange),
            name: NSNotification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil)

        #if DEBUG
        // Hook di test/automazione (solo DEBUG): apre/chiude il pannello da fuori processo per la
        // verifica headless. In release NON è registrato, così l'app personale non espone un toggle
        // a processi terzi.
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(self.handleTogglePanelNotification),
            name: NSNotification.Name("com.subralabs.claudebar.togglePanel"),
            object: nil)
        #endif
    }

    #if DEBUG
    @objc private func handleTogglePanelNotification() {
        self.statusController?.togglePanel()
    }
    #endif

    @objc private func handleWake() {
        self.scheduler?.resume()
        self.model?.handleWake()
    }

    @objc private func handleAppearanceChange() {
        self.model?.applySettingsChange()
    }

    private func handleSettingsChange() {
        self.scheduler?.setInterval(self.settings.refreshInterval)
        self.model?.applySettingsChange()
    }

    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        DistributedNotificationCenter.default().removeObserver(self)
    }
}

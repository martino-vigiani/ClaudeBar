import AppKit
import ClaudeBarCore

/// Controller dello `NSStatusItem`: crea l'item, configura il button e il click handling,
/// ridisegna l'icona (chiamato dall'AppModel) e pilota le animazioni dell'icona via DisplayLink
/// (02-app-architecture.md §3).
@MainActor
final class StatusItemController {
    private let statusItem: NSStatusItem
    private let panelHost: PanelHostController
    private weak var model: AppModel?

    private var currentSpec: GlanceIconSpec = .loading
    private var animationDriver: DisplayLinkDriver?
    private var animationPhase: CGFloat = 0

    /// `onRefresh`/`onPreferences`/`onQuit`: azioni del menu rapido (iniettate dall'AppDelegate).
    private let onRefresh: @MainActor () -> Void
    private let onPreferences: @MainActor () -> Void
    private let onQuit: @MainActor () -> Void

    init(
        panelHost: PanelHostController,
        onRefresh: @escaping @MainActor () -> Void,
        onPreferences: @escaping @MainActor () -> Void,
        onQuit: @escaping @MainActor () -> Void)
    {
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.panelHost = panelHost
        self.onRefresh = onRefresh
        self.onPreferences = onPreferences
        self.onQuit = onQuit
    }

    /// Configura button, target/action e disegna l'icona iniziale.
    func install() {
        guard let button = self.statusItem.button else { return }
        button.target = self
        button.action = #selector(self.handleClick(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.toolTip = AppInfo.displayName
        self.applyCurrentSpec()
    }

    /// Ridisegna l'icona con la nuova spec. Avvia/ferma il display link a seconda dell'animazione.
    func updateGlance(_ spec: GlanceIconSpec) {
        let wasAnimating = self.currentSpec.animation != .none
        self.currentSpec = spec
        self.applyCurrentSpec()

        let needsAnimation = spec.animation != .none
        if needsAnimation, !wasAnimating {
            self.startAnimation()
        } else if !needsAnimation, wasAnimating {
            self.stopAnimation()
        }
    }

    func prepareForShutdown() {
        self.stopAnimation()
        self.panelHost.prepareForShutdown()
        NSStatusBar.system.removeStatusItem(self.statusItem)
    }

    // MARK: - Disegno

    private func applyCurrentSpec() {
        guard let button = self.statusItem.button else { return }
        let image = IconRenderer.render(self.currentSpec, phase: self.animationPhase)
        button.image = image
        button.imagePosition = .imageOnly
    }

    // MARK: - Animazione (display link, on-demand)

    private func startAnimation() {
        guard self.animationDriver == nil else { return }
        // L'icona anima a 12fps (pulse) o un po' più veloce per gli spin; teniamo 12 per il pulse.
        let fps: Double = self.currentSpec.animation == .pulse ? 12 : 24
        self.animationPhase = 0
        let driver = DisplayLinkDriver(fps: fps) { [weak self] in
            self?.tickAnimation()
        }
        self.animationDriver = driver
        driver.start()
    }

    private func stopAnimation() {
        self.animationDriver?.stop()
        self.animationDriver = nil
        self.animationPhase = 0
        self.applyCurrentSpec()
    }

    private func tickAnimation() {
        // Incremento di fase: per pulse usiamo un periodo ~1.4s, per gli spin un giro continuo.
        let increment: CGFloat = self.currentSpec.animation == .pulse ? 0.10 : 0.18
        self.animationPhase += increment
        if self.animationPhase > .pi * 2 {
            self.animationPhase -= .pi * 2
        }
        self.applyCurrentSpec()
    }

    // MARK: - Click handling

    @objc private func handleClick(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        let isRightClick = event?.type == .rightMouseUp
        let isCommandClick = event?.modifierFlags.contains(.command) ?? false

        if isRightClick || isCommandClick {
            self.showQuickMenu()
        } else {
            self.togglePanel()
        }
    }

    func togglePanel() {
        guard let button = self.statusItem.button else { return }
        // NB: il refresh on-demand all'apertura (`panelDidOpen`) è innescato dalla view SwiftUI
        // nel suo `.onAppear` (via il protocollo PanelViewModeling → AppModel.panelDidOpen()).
        // NON lo chiamiamo anche qui per evitare un DOPPIO refresh (doppio fetch limiti +
        // potenziale doppio prompt Keychain) alla stessa apertura.
        self.panelHost.toggle(relativeTo: button)
    }

    /// Chiude il pannello. Usato prima di aprire le Preferenze: il pannello è floating a livello
    /// `.statusBar` e coprirebbe la finestra Impostazioni.
    func closePanel() {
        self.panelHost.close()
    }

    func attach(model: AppModel) {
        self.model = model
    }

    private func showQuickMenu() {
        let menu = NSMenu()

        let refresh = NSMenuItem(title: "Aggiorna", action: #selector(self.menuRefresh), keyEquivalent: "r")
        refresh.target = self
        menu.addItem(refresh)

        menu.addItem(.separator())

        let prefs = NSMenuItem(title: "Preferenze…", action: #selector(self.menuPreferences), keyEquivalent: ",")
        prefs.target = self
        menu.addItem(prefs)

        let quit = NSMenuItem(title: "Esci da \(AppInfo.displayName)", action: #selector(self.menuQuit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        // Mostra il menu al click destro senza renderlo permanente sul button.
        self.statusItem.menu = menu
        self.statusItem.button?.performClick(nil)
        self.statusItem.menu = nil
    }

    @objc private func menuRefresh() { self.onRefresh() }
    @objc private func menuPreferences() { self.onPreferences() }
    @objc private func menuQuit() { self.onQuit() }
}

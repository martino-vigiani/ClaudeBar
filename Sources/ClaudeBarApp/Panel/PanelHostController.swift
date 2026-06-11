import AppKit
import SwiftUI

extension Notification.Name {
    /// Postata quando il pannello viene nascosto (orderOut su click-fuori / Esc / shutdown).
    /// La SwiftUI view la osserva per resettare stato effimero (es. hover della CollapseHandle),
    /// che AppKit non azzera da sé visto che il pannello viene riusato tra un'apertura e l'altra.
    static let claudeBarPanelDidHide = Notification.Name("claudeBarPanelDidHide")

    /// Postata dal contenuto SwiftUI quando la sua fitting size cambia a pannello aperto
    /// (es. collapse/expand della fascia limiti). Il controller ri-dimensiona e ri-ancora il
    /// pannello mantenendo il top edge sotto il bottone status (cresce verso il basso).
    static let claudeBarPanelContentDidResize = Notification.Name("claudeBarPanelContentDidResize")
}

/// NSPanel borderless non-activating che ospita la SwiftUI view del pannello (Liquid Glass)
/// ancorata sotto l'icona della status bar (02-app-architecture.md §4).
///
/// Si chiude su click-fuori (event monitor globale) o Esc. Non ruba il focus all'app frontmost
/// (`.nonactivatingPanel`), così resta un overlay leggero come un menu.
@MainActor
final class PanelHostController {
    private var panel: PanelWindow?
    private var globalClickMonitor: Any?
    private var localKeyMonitor: Any?
    /// Observer della notification di resize del contenuto SwiftUI (collapse/expand fascia limiti).
    private var contentResizeObserver: NSObjectProtocol?
    private let makeRootView: @MainActor () -> AnyView
    /// Bottone della status bar a cui il pannello è ancorato. Serve al monitor click-fuori:
    /// da macOS 27 beta (Darwin 27) la status bar è hostata out-of-process, quindi il click
    /// sull'icona arriva ANCHE al global monitor — senza questo filtro il monitor chiude al
    /// mouseDown e il toggle (mouseUp) riapre subito: il pannello non si chiude mai cliccando
    /// l'icona. (Altre app menu-bar mostrano lo stesso bug sulla beta: comportamento OS-level.)
    /// Il filtro è innocuo sulle versioni dove il click NON raggiunge il monitor: non scatta.
    private weak var anchorButton: NSStatusBarButton?

    /// Azione "apri Preferenze" (scorciatoia cmd+, mentre il pannello è key). Iniettata dall'AppDelegate.
    var onPreferences: (@MainActor () -> Void)?

    /// `makeRootView`: factory della root SwiftUI (la fornisce l'AppModel/adapter, vedi wiring).
    init(makeRootView: @escaping @MainActor () -> AnyView) {
        self.makeRootView = makeRootView
    }

    var isVisible: Bool { self.panel?.isVisible ?? false }

    /// Apre o chiude il pannello ancorato al `statusButton`.
    func toggle(relativeTo statusButton: NSStatusBarButton) {
        if self.isVisible {
            self.close()
        } else {
            self.open(relativeTo: statusButton)
        }
    }

    func open(relativeTo statusButton: NSStatusBarButton) {
        let panel = self.panel ?? self.makePanel()
        self.panel = panel
        self.anchorButton = statusButton
        self.positionPanel(panel, below: statusButton)
        panel.makeKeyAndOrderFront(nil)
        self.installDismissMonitors()
        self.installContentResizeObserver()
    }

    func close() {
        self.removeDismissMonitors()
        self.removeContentResizeObserver()
        self.panel?.orderOut(nil)
        NotificationCenter.default.post(name: .claudeBarPanelDidHide, object: nil)
    }

    func prepareForShutdown() {
        self.removeDismissMonitors()
        self.removeContentResizeObserver()
        self.panel?.orderOut(nil)
        NotificationCenter.default.post(name: .claudeBarPanelDidHide, object: nil)
        self.panel = nil
    }

    // MARK: - Costruzione

    private func makePanel() -> PanelWindow {
        let hosting = NSHostingController(rootView: self.makeRootView())
        // La dimensione preferita arriva dalla view (DS.Size.panelWidth/panelMaxHeight); il
        // contenuto SwiftUI auto-dimensiona, qui diamo un frame iniziale ragionevole.
        hosting.view.frame = NSRect(x: 0, y: 0, width: 360, height: 480)

        let panel = PanelWindow(
            contentRect: hosting.view.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        panel.contentViewController = hosting
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // L'ombra la disegna SwiftUI (GlassPanel/clipShape) seguendo gli angoli arrotondati.
        // L'ombra AppKit della finestra è rettangolare → darebbe l'angolo "squadrato" visibile.
        panel.hasShadow = false
        panel.level = .statusBar
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.animationBehavior = .utilityWindow
        return panel
    }

    private func positionPanel(_ panel: PanelWindow, below button: NSStatusBarButton) {
        guard let buttonWindow = button.window else { return }
        let buttonRectInScreen = buttonWindow.convertToScreen(
            button.convert(button.bounds, to: nil))

        // Lasciamo che il contenuto SwiftUI determini la dimensione effettiva.
        panel.layoutIfNeeded()
        let panelSize = panel.contentViewController?.view.fittingSize ?? panel.frame.size
        let size = NSSize(
            width: max(panelSize.width, 320),
            height: max(panelSize.height, 200))
        panel.setContentSize(size)

        let gap: CGFloat = 6
        var origin = NSPoint(
            x: buttonRectInScreen.midX - size.width / 2,
            y: buttonRectInScreen.minY - size.height - gap)

        // Mantieni il pannello dentro lo schermo dell'icona.
        if let screen = buttonWindow.screen ?? NSScreen.main {
            let visible = screen.visibleFrame
            origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
            if origin.y < visible.minY + 8 {
                origin.y = visible.minY + 8
            }
        }
        panel.setFrameOrigin(origin)
    }

    // MARK: - Resize live (collapse/expand fascia limiti a pannello aperto)
    //
    // La SwiftUI view cambia il suo maxHeight quando l'utente collassa/espande la fascia limiti:
    // il fitting size del contenuto cresce/si accorcia. Senza ri-dimensionare la finestra il
    // contenuto verrebbe clippato (o, ri-ancorando solo l'origin di default, crescerebbe verso
    // l'alto). Qui ri-dimensioniamo e ri-ancoriamo tenendo fermo il TOP edge (subito sotto il
    // bottone status) così il pannello cresce verso il basso, come un menu.

    private func installContentResizeObserver() {
        self.removeContentResizeObserver()
        self.contentResizeObserver = NotificationCenter.default.addObserver(
            forName: .claudeBarPanelContentDidResize, object: nil, queue: .main)
        { [weak self] _ in
            MainActor.assumeIsolated { self?.repositionToFitContent() }
        }
    }

    private func removeContentResizeObserver() {
        if let observer = self.contentResizeObserver {
            NotificationCenter.default.removeObserver(observer)
            self.contentResizeObserver = nil
        }
    }

    /// Ri-dimensiona il pannello alla nuova fitting size del contenuto mantenendo fermo il top
    /// edge: ricalcola l'origin sotto il bottone status (cresce verso il basso). No-op se il
    /// pannello non è visibile o il bottone d'ancoraggio non è più disponibile.
    private func repositionToFitContent() {
        guard let panel = self.panel, panel.isVisible,
              let button = self.anchorButton else { return }
        self.positionPanel(panel, below: button)
    }

    // MARK: - Dismissal (click-fuori + Esc)

    private func installDismissMonitors() {
        self.removeDismissMonitors()

        self.globalClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown])
        { [weak self] event in
            // Per gli eventi global `window` è nil e `locationInWindow` è in coordinate schermo.
            let screenLocation = event.locationInWindow
            Task { @MainActor in
                guard let self else { return }
                // Click sull'icona della status bar → lo gestisce il toggle al mouseUp,
                // il monitor NON deve chiudere (altrimenti il toggle riapre subito).
                if let button = self.anchorButton, let window = button.window {
                    let buttonRect = window.convertToScreen(button.convert(button.bounds, to: nil))
                    if buttonRect.contains(screenLocation) { return }
                }
                self.close()
            }
        }

        self.localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            if event.keyCode == 53 { // Esc
                Task { @MainActor in self?.close() }
                return nil
            }
            // cmd+, → apri Preferenze (onPreferences chiude il pannello e apre la finestra Settings).
            if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "," {
                Task { @MainActor in self?.onPreferences?() }
                return nil
            }
            return event
        }
    }

    private func removeDismissMonitors() {
        if let monitor = self.globalClickMonitor {
            NSEvent.removeMonitor(monitor)
            self.globalClickMonitor = nil
        }
        if let monitor = self.localKeyMonitor {
            NSEvent.removeMonitor(monitor)
            self.localKeyMonitor = nil
        }
    }
}

/// NSPanel borderless che può diventare key (necessario per Esc/interazioni della SwiftUI view)
/// pur restando non-activating (non porta l'app in foreground).
final class PanelWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

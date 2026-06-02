import AppKit
import SwiftUI

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
    private let makeRootView: @MainActor () -> AnyView

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
        self.positionPanel(panel, below: statusButton)
        panel.makeKeyAndOrderFront(nil)
        self.installDismissMonitors()
    }

    func close() {
        self.removeDismissMonitors()
        self.panel?.orderOut(nil)
    }

    func prepareForShutdown() {
        self.removeDismissMonitors()
        self.panel?.orderOut(nil)
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

    // MARK: - Dismissal (click-fuori + Esc)

    private func installDismissMonitors() {
        self.removeDismissMonitors()

        self.globalClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown])
        { [weak self] _ in
            Task { @MainActor in self?.close() }
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

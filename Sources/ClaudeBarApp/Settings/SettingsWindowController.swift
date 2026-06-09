import AppKit
import ClaudeBarCore
import SwiftUI

/// Gestisce una `NSWindow` dedicata per le Impostazioni.
///
/// Per un'app accessory (LSUIElement) la scene `Settings` di SwiftUI non si apre in modo
/// affidabile via `showSettingsWindow:`: senza una key window nella responder chain di SwiftUI,
/// `NSApp.sendAction(_:to:nil)` non trova l'handler e non succede nulla. Qui creiamo e mostriamo
/// una `NSWindow` nostra che ospita `SettingsRootView`, con controllo pieno su attivazione e
/// ordine di front. La finestra viene creata una volta e riusata (no rilascio alla chiusura).
@MainActor
final class SettingsWindowController {
    private var window: NSWindow?

    func show(settings: SettingsStore) {
        if self.window == nil {
            let hosting = NSHostingController(rootView: SettingsRootView(settings: settings))

            // Finestra Impostazioni look "System Settings" nativo: titlebar TRASPARENTE + contenuto a
            // tutta altezza (`.fullSizeContentView`), titolo nascosto. Così la sidebar `.sidebar`
            // sale fino in cima dietro ai semafori (niente "barra sopra" staccata col separatore) e
            // fonde col resto — esattamente la System Settings di macOS. Vetro NEUTRO (DECISIONS §3),
            // nessun NSVisualEffectView manuale.
            //
            // Il vecchio timore del clip ("Default provider …" tagliata in alto) non si applica più: il
            // detail è un `Form(.grouped)` scrollabile e con `.fullSizeContentView` SwiftUI inserisce
            // da sé la safe-area della titlebar in cima a sidebar e contenuto → niente taglio.
            let window = NSWindow(contentViewController: hosting)
            window.title = NSLocalizedString("Settings", comment: "Settings window title")
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            // Titolo VISIBILE (mostra la sezione via navigationTitle) ma titlebar TRASPARENTE: così
            // la titlebar riserva la sua altezza → il detail si inserisce sotto (niente clip), mentre
            // il materiale `.sidebar` sale dietro la titlebar trasparente (niente barra opaca/separatore).
            window.titleVisibility = .visible
            window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false
            window.identifier = NSUserInterfaceItemIdentifier("claudebar.settings")
            window.setContentSize(NSSize(width: 700, height: 560))
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        self.window?.makeKeyAndOrderFront(nil)
        self.window?.orderFrontRegardless()
    }
}

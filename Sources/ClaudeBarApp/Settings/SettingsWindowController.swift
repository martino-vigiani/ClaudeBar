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

            // Finestra Impostazioni NATIVA (look "System Settings"/Klack): style mask standard, senza
            // `.fullSizeContentView`/titlebar trasparente. Una NSWindow titled ha già angoli
            // arrotondati nativi; ospitando una `NavigationSplitView` la sidebar adotta da sé il
            // materiale translucido di sistema (`.sidebar`) che fonde con la titlebar — esattamente
            // il vetro NEUTRO voluto (DECISIONS §3), senza alcun NSVisualEffectView manuale.
            //
            // Niente `.fullSizeContentView` ⇒ il contenuto parte SOTTO la titlebar e non viene più
            // tagliato (era il bug della prima riga "Default provider …" mezza nascosta in alto).
            let window = NSWindow(contentViewController: hosting)
            window.title = NSLocalizedString("Settings", comment: "Settings window title")
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.titleVisibility = .visible
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

import SwiftUI

/// Entry point dell'app menu bar (LSUIElement, nessuna finestra principale).
///
/// L'`AppDelegate` è la composition root: costruisce AppModel, StatusItemController (NSStatusItem),
/// watcher, scheduler. La scene `Settings` ospita le Preferenze, aperte on-demand dal menu/pannello.
@main
struct ClaudeBarMain: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            SettingsRootView(settings: self.appDelegate.settingsStore)
        }
        // `.contentMinSize`: rispetta la dimensione minima della view ma lascia l'utente
        // ridimensionare la finestra Impostazioni (stile app vera), a differenza di `.contentSize`.
        .windowResizability(.contentMinSize)
    }
}

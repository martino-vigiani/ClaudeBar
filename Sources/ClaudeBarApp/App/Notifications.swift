import Foundation
import os
import UserNotifications

/// Notifiche di soglia sessione (50/75/90% USATO) con DE-DUP per ciclo di reset + celebrazione
/// reset settimanale (DECISIONS.md §4).
///
/// De-dup: una sola notifica per soglia per ciclo. Il ciclo è identificato dal `resetsAt` della
/// finestra: quando cambia (reset avvenuto) le soglie già notificate si azzerano.
@MainActor
final class AppNotifications {
    // `lazy`: `UNUserNotificationCenter.current()` richiede un bundle app valido e lancia in
    // ambiente headless/test (`bundleProxyForCurrentProcess is nil`). Rinviandone l'accesso al
    // primo uso reale, l'init resta innocuo e l'AppModel è costruibile nei test senza bundle.
    private lazy var center = UNUserNotificationCenter.current()
    private let logger = Logger(subsystem: AppInfo.bundleIdentifier, category: "notifications")

    /// Soglie di notifica sessione, in % USATO (DECISIONS §4).
    static let sessionThresholds: [Double] = [50, 75, 90]

    /// Soglie già notificate nel ciclo corrente, per chiave finestra.
    private var notifiedThresholds: [String: Set<Int>] = [:]
    /// Ultimo `resetsAt` visto per finestra → per rilevare il reset e riarmare le soglie.
    private var lastResetsAt: [String: Date] = [:]
    private var authorizationRequested = false

    /// Richiede l'autorizzazione in modo soft (non blocca l'avvio).
    func requestAuthorizationIfNeeded() {
        guard !self.authorizationRequested else { return }
        self.authorizationRequested = true
        self.center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, error in
            if let error {
                Task { @MainActor in
                    self?.logger.debug("authorization error: \(error.localizedDescription, privacy: .public)")
                }
            } else {
                Task { @MainActor in
                    self?.logger.debug("notifications granted=\(granted)")
                }
            }
        }
    }

    /// Valuta le soglie di una finestra sessione e, se superate per la prima volta nel ciclo,
    /// invia la notifica. `windowKey` identifica la finestra (es. "fiveHour").
    /// `enabled` riflette la preferenza utente. `thresholds` (% USATO) e `sound` sono
    /// configurabili dalle Impostazioni; i default replicano il comportamento storico (50/75/90,
    /// suono attivo) per non regredire i call site che non li passano.
    func evaluateSessionThresholds(
        windowKey: String,
        usedPercent: Double,
        resetsAt: Date?,
        enabled: Bool,
        thresholds: [Double] = AppNotifications.sessionThresholds,
        sound: Bool = true)
    {
        // Reset del ciclo: se il resetsAt è cambiato, riarma tutte le soglie.
        if let resetsAt {
            if let previous = self.lastResetsAt[windowKey], previous != resetsAt {
                self.notifiedThresholds[windowKey] = []
            }
            self.lastResetsAt[windowKey] = resetsAt
        }

        guard enabled else { return }

        var fired = self.notifiedThresholds[windowKey] ?? []
        for threshold in thresholds {
            let key = Int(threshold)
            if usedPercent >= threshold, !fired.contains(key) {
                fired.insert(key)
                self.sendSessionThresholdNotification(threshold: key, usedPercent: usedPercent, sound: sound)
            }
        }
        self.notifiedThresholds[windowKey] = fired
    }

    /// Celebrazione del reset settimanale. De-dup tramite il cambio di `resetsAt` della settimana.
    func evaluateWeeklyReset(
        windowKey: String,
        resetsAt: Date?,
        enabled: Bool,
        sound: Bool = true)
    {
        guard let resetsAt else { return }
        let previous = self.lastResetsAt[windowKey]
        self.lastResetsAt[windowKey] = resetsAt

        // Reset avvenuto = il resetsAt si è spostato in avanti rispetto a quello noto.
        guard let previous, resetsAt > previous else { return }
        guard enabled else { return }
        self.sendWeeklyResetNotification(sound: sound)
    }

    // MARK: - Invio

    private func sendSessionThresholdNotification(threshold: Int, usedPercent: Double, sound: Bool) {
        let content = UNMutableNotificationContent()
        content.title = AppInfo.displayName
        content.body = String(
            format: NSLocalizedString(
                "5h session at %lld%% used (%lld%%).",
                comment: "Notification body: 5-hour session usage threshold reached; first %lld is the threshold, second is the current used percent"),
            threshold,
            Int(usedPercent.rounded()))
        if sound { content.sound = .default }
        self.deliver(content, identifier: "session-threshold-\(threshold)")
    }

    private func sendWeeklyResetNotification(sound: Bool) {
        let content = UNMutableNotificationContent()
        content.title = AppInfo.displayName
        content.body = NSLocalizedString(
            "Weekly limit reset. Fresh start!",
            comment: "Notification body: celebrates the weekly limit reset")
        if sound { content.sound = .default }
        self.deliver(content, identifier: "weekly-reset")
    }

    private func deliver(_ content: UNMutableNotificationContent, identifier: String) {
        let request = UNNotificationRequest(
            identifier: "\(identifier)-\(Int(Date().timeIntervalSince1970))",
            content: content,
            trigger: nil)
        self.center.add(request) { [weak self] error in
            if let error {
                Task { @MainActor in
                    self?.logger.debug("delivery error: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }
}

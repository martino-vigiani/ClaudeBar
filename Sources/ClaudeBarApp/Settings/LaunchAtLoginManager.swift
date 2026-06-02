import Foundation
import os
import ServiceManagement

/// Launch at login via `SMAppService.mainApp` (macOS 13+; 02-app-architecture.md §9).
/// Disabilitato sotto test per non sporcare gli item di login.
enum LaunchAtLoginManager {
    private static let logger = Logger(subsystem: AppInfo.bundleIdentifier, category: "launch-at-login")

    /// Riflette lo `status` reale del servizio (non solo la preferenza salvata), così resta
    /// coerente se l'utente revoca da Impostazioni di Sistema.
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    private static var isRunningUnderTests: Bool {
        let env = ProcessInfo.processInfo.environment
        return env["XCTestConfigurationFilePath"] != nil
            || env["SWIFT_TESTING"] != nil
            || NSClassFromString("XCTestCase") != nil
    }

    /// Registra/deregistra l'app come login item. No-op sotto test.
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Bool {
        guard !self.isRunningUnderTests else { return false }
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                }
            }
            return true
        } catch {
            self.logger.error("launch-at-login \(enabled ? "register" : "unregister") fallito: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }
}

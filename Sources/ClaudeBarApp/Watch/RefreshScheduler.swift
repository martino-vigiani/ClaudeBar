import Foundation

/// Cadenza di refresh dei limiti ufficiali (rete). Allineato a 04-product-roadmap.md:
/// Manual · 1m · 2m · 5m · 15m · 30m. Default 5 minuti.
enum RefreshInterval: String, Sendable, CaseIterable, Identifiable {
    case manual
    case oneMinute
    case twoMinutes
    case fiveMinutes
    case fifteenMinutes
    case thirtyMinutes

    var id: String { self.rawValue }

    /// `nil` per `.manual` (nessun timer).
    var duration: Duration? {
        switch self {
        case .manual: nil
        case .oneMinute: .seconds(60)
        case .twoMinutes: .seconds(120)
        case .fiveMinutes: .seconds(300)
        case .fifteenMinutes: .seconds(900)
        case .thirtyMinutes: .seconds(1800)
        }
    }

    /// Etichetta per le Preferenze.
    var label: String {
        switch self {
        case .manual: "Manuale"
        case .oneMinute: "1 minuto"
        case .twoMinutes: "2 minuti"
        case .fiveMinutes: "5 minuti"
        case .fifteenMinutes: "15 minuti"
        case .thirtyMinutes: "30 minuti"
        }
    }
}

/// Scheduler dei refresh limiti, rate-limit-aware. Implementato con un `Task` che dorme in loop
/// (più pulito di `Timer`, niente retain di RunLoop). Lo scheduler NON ha un proprio backoff:
/// il gate 429 vive in `ClaudeLimitsService` e lo scheduler ne rispetta l'esito (§7.1).
@MainActor
final class RefreshScheduler {
    private var interval: RefreshInterval
    private let action: @Sendable () async -> Void
    private var loopTask: Task<Void, Never>?
    private var isSuspended = false

    init(interval: RefreshInterval, action: @escaping @Sendable () async -> Void) {
        self.interval = interval
        self.action = action
    }

    /// Avvia il loop periodico (no-op se `.manual`).
    func start() {
        self.restartLoop()
    }

    func setInterval(_ interval: RefreshInterval) {
        guard interval != self.interval else { return }
        self.interval = interval
        self.restartLoop()
    }

    /// Refresh manuale / on-demand. Esegue subito l'azione, indipendentemente dall'intervallo.
    func refreshNow() {
        Task { await self.action() }
    }

    /// Pausa il loop (offline / sleep). `resume()` lo riavvia.
    func suspend() {
        self.isSuspended = true
        self.loopTask?.cancel()
        self.loopTask = nil
    }

    func resume() {
        guard self.isSuspended else { return }
        self.isSuspended = false
        self.restartLoop()
    }

    func stop() {
        self.loopTask?.cancel()
        self.loopTask = nil
    }

    private func restartLoop() {
        self.loopTask?.cancel()
        self.loopTask = nil
        guard !self.isSuspended, let duration = self.interval.duration else { return }

        let action = self.action
        self.loopTask = Task { @MainActor in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: duration)
                } catch {
                    return // cancellato
                }
                if Task.isCancelled { return }
                await action()
            }
        }
    }
}

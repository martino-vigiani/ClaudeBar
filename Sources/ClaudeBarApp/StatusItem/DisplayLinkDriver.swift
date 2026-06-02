import AppKit
import QuartzCore

/// Pilota le animazioni dell'icona (pulse / refreshSpin / loadingSpin) a frequenza ridotta
/// (l'icona NON anima a 60fps). Attivo SOLO mentre serve: a riposo è fermo → 0% CPU
/// (02-app-architecture.md §3, budget §14).
///
/// Usa `CADisplayLink` (macOS 14+) con un cap di FPS, e fa hop esplicito sul MainActor a ogni tick.
@MainActor
final class DisplayLinkDriver {
    private var displayLink: CADisplayLink?
    private let onTick: @MainActor () -> Void
    private let fps: Double

    /// `fps`: cadenza target (12 di default per l'icona; refresh/loading possono volere 30).
    init(fps: Double = 12, onTick: @escaping @MainActor () -> Void) {
        self.fps = fps
        self.onTick = onTick
    }

    var isRunning: Bool { self.displayLink != nil }

    func start() {
        guard self.displayLink == nil else { return }
        // Un qualsiasi NSView/NSWindow va bene come sorgente del display link; usiamo una view
        // vuota associata alla main screen. Se non disponibile, fallback a un timer.
        let view = NSView(frame: .zero)
        let link = view.displayLink(target: self, selector: #selector(self.tick))
        link.preferredFrameRateRange = CAFrameRateRange(
            minimum: Float(self.fps),
            maximum: Float(self.fps),
            preferred: Float(self.fps))
        link.add(to: .main, forMode: .common)
        self.displayLink = link
    }

    func stop() {
        self.displayLink?.invalidate()
        self.displayLink = nil
    }

    @objc private func tick() {
        self.onTick()
    }

    // NB: `CADisplayLink` trattiene il `target`, quindi finché il link è attivo questo driver
    // non viene deallocato. Chi possiede il driver DEVE chiamare `stop()` per invalidare il link
    // e spezzare il ciclo (lo fa `StatusItemController.stopAnimation()`). Per questo non c'è un
    // `deinit` che tocca `displayLink` (vietato da nonisolated deinit sotto Swift 6 strict).
}

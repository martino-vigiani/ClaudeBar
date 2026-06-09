import AppKit
import ClaudeBarCore

// IconRenderer — disegno Core Graphics del glance della status bar.
//
// LOCK da DECISIONS.md §1 e "LOCK semantica glance" (fa fede): l'icona è ANELLO (ring gauge)
// + percentuale numerica accanto (es. `◕ 71%`). Anello, % e colore rappresentano tutti il
// % USATO (`used`) della finestra PIÙ CRITICA. Più usato → più rosso.
// Mapping colore sull'USATO: verde <60, ambra 60–85, rosso >85, pulsa ≥95.
//
// A differenza dell'upstream CodexBar (icona template monocroma, barre orizzontali), qui
// l'immagine NON è template: `isTemplate = false`, perché IL COLORE È L'INFORMAZIONE.
// La modalità `monochrome` produce un'icona template B/N (fallback contrasto/preferenza).

enum IconRenderer {
    // 18×18 pt è la dimensione standard della menu bar; rendiamo a 2× (36×36 px).
    private static let outputSize = NSSize(width: 18, height: 18)
    private static let outputScale: CGFloat = 2

    // MARK: - API pubblica

    /// Disegna l'icona della status bar (anello + % numerica). Pure function: stessa chiave
    /// quantizzata → stessa immagine (cache). Colore, riempimento e % sono funzione di `used`.
    static func render(_ spec: GlanceIconSpec, phase: CGFloat = 0) -> NSImage {
        // L'animazione (pulse/spin) varia `phase` di continuo → non cachabile per frame;
        // gli stati statici sì.
        let isAnimating = spec.animation != .none && abs(phase) > 0.0001
        if isAnimating {
            return self.draw(spec, phase: phase)
        }

        let key = IconCacheKey(spec: spec)
        if let cached = self.cache.image(for: key) {
            return cached
        }
        let image = self.draw(spec, phase: 0)
        self.cache.store(image, for: key)
        return image
    }

    // MARK: - Cache quantizzata

    /// Chiave di cache quantizzata: si ridisegna solo quando cambia il bucket (~3% di passo),
    /// non a ogni tick (design §3.6).
    private struct IconCacheKey: Hashable {
        let usedBucket: Int
        let weeklyBucket: Int
        let kind: Int
        let state: Int
        let style: Int
        let percentLabel: Int
        let monochrome: Bool
        let dim: Bool
        let appearance: Int

        init(spec: GlanceIconSpec) {
            self.usedBucket = Self.bucket(spec.used)
            self.weeklyBucket = spec.weeklyUsed.map(Self.bucket) ?? -1
            self.kind = Self.kindKey(spec.criticalKind)
            self.state = Self.stateKey(spec.state)
            self.style = spec.style == .ring ? 0 : 1
            self.percentLabel = Self.percentKey(spec.percentLabel)
            self.monochrome = spec.monochrome
            self.dim = spec.dim
            self.appearance = spec.appearance == .light ? 0 : 1
        }

        /// Quantizza 0...1 a passi di ~3% (33 bucket). La % numerica resta intera (vedi disegno).
        private static func bucket(_ value: Double) -> Int {
            let clamped = max(0, min(value, 1))
            return Int((clamped * 100).rounded())
        }

        private static func kindKey(_ kind: PaceWindowKind) -> Int {
            switch kind {
            case .fiveHour: 0
            case .sevenDay: 1
            case .sevenDayOpus: 2
            case .sevenDaySonnet: 3
            }
        }

        private static func stateKey(_ state: GlanceState) -> Int {
            switch state {
            case .ok: 0
            case .warn: 1
            case .low: 2
            case .critical: 3
            case .empty: 4
            }
        }

        private static func percentKey(_ label: PercentLabel) -> Int {
            switch label {
            case .used: 0
            case .remaining: 1
            case .hidden: 2
            }
        }
    }

    private final class IconCacheStore: @unchecked Sendable {
        private var entries: [IconCacheKey: NSImage] = [:]
        private var order: [IconCacheKey] = []
        private let lock = NSLock()
        private let limit = 96

        func image(for key: IconCacheKey) -> NSImage? {
            self.lock.lock()
            defer { self.lock.unlock() }
            guard let image = self.entries[key] else { return nil }
            if let idx = self.order.firstIndex(of: key) {
                self.order.remove(at: idx)
                self.order.append(key)
            }
            return image
        }

        func store(_ image: NSImage, for key: IconCacheKey) {
            self.lock.lock()
            defer { self.lock.unlock() }
            self.entries[key] = image
            self.order.removeAll { $0 == key }
            self.order.append(key)
            while self.order.count > self.limit {
                let oldest = self.order.removeFirst()
                self.entries.removeValue(forKey: oldest)
            }
        }
    }

    private static let cache = IconCacheStore()

    // MARK: - Colore sull'USATO (interpolazione continua verde→ambra→rosso)

    /// Mappa `used` (0...1) a un colore semantico interpolato.
    /// Ancore: 0.00 verde · 0.60 verde-ambra · 0.85 ambra-rosso · 1.00 rosso pieno.
    /// Più usato → più rosso (DECISIONS "LOCK semantica glance").
    ///
    /// SORGENTE UNICA condivisa icona↔pannello (`UsageColorScale`): la curva NON è parametrica
    /// sulle soglie utente, così l'anello del pannello e l'icona menu bar hanno SEMPRE lo stesso
    /// colore a parità di % usato (LOCK di coerenza, decisione DEFINITIVA team-lead "Option B").
    /// Le soglie `warn/critical` dell'utente pilotano solo lo STATO (ambra/rosso/pulsa/flag/etichetta)
    /// via `GlanceClassifier`, non il gradiente.
    static func color(forUsed used: Double) -> NSColor {
        let u = max(0, min(used, 1))
        // Ancore (sRGB). Verde acceso → giallo/ambra → rosso.
        let green = NSColor(srgbRed: 0.20, green: 0.78, blue: 0.35, alpha: 1)   // <60
        let amber = NSColor(srgbRed: 0.98, green: 0.74, blue: 0.02, alpha: 1)   // ~70
        let orange = NSColor(srgbRed: 0.96, green: 0.49, blue: 0.06, alpha: 1)  // ~88
        let red = NSColor(srgbRed: 0.92, green: 0.22, blue: 0.20, alpha: 1)     // 100

        switch u {
        case ..<0.60:
            return self.lerp(green, amber, t: u / 0.60 * 0.55) // resta prevalentemente verde
        case ..<0.85:
            return self.lerp(amber, orange, t: (u - 0.60) / 0.25)
        default:
            return self.lerp(orange, red, t: (u - 0.85) / 0.15)
        }
    }

    private static func lerp(_ a: NSColor, _ b: NSColor, t: CGFloat) -> NSColor {
        let t = max(0, min(t, 1))
        let ca = a.usingColorSpace(.sRGB) ?? a
        let cb = b.usingColorSpace(.sRGB) ?? b
        return NSColor(
            srgbRed: ca.redComponent + (cb.redComponent - ca.redComponent) * t,
            green: ca.greenComponent + (cb.greenComponent - ca.greenComponent) * t,
            blue: ca.blueComponent + (cb.blueComponent - ca.blueComponent) * t,
            alpha: 1)
    }

    /// Adatta il colore-dato al contrasto della menu bar. Su sfondo CHIARO (Tahoe light) il verde
    /// e l'ambra accesi staccano poco → li scuriamo del ~15% in luminanza (mantenendo la tinta,
    /// quindi la semantica della curva). Su scuro il colore resta invariato. Solo per il colore
    /// semantico: in monocromo è il sistema a gestire il template B/N.
    private static func contrastAdjusted(_ color: NSColor, light: Bool) -> NSColor {
        guard light else { return color }
        let c = color.usingColorSpace(.sRGB) ?? color
        let f: CGFloat = 0.85
        return NSColor(
            srgbRed: c.redComponent * f,
            green: c.greenComponent * f,
            blue: c.blueComponent * f,
            alpha: c.alphaComponent)
    }

    // MARK: - Disegno

    private static func draw(_ spec: GlanceIconSpec, phase: CGFloat) -> NSImage {
        // Quanto spazio per il testo? Se mostriamo la %, l'icona si allarga in orizzontale.
        let showsText = spec.percentLabel != .hidden
        let textWidth: CGFloat = showsText ? 17 : 0
        let ringDiameter: CGFloat = 14
        let leftPadding: CGFloat = 1
        let gap: CGFloat = showsText ? 2 : 0
        let width = leftPadding + ringDiameter + gap + textWidth + 1
        let size = NSSize(width: ceil(width), height: outputSize.height)

        return self.renderImage(size: size, monochrome: spec.monochrome) {
            let ringRect = NSRect(
                x: leftPadding,
                y: (size.height - ringDiameter) / 2,
                width: ringDiameter,
                height: ringDiameter)

            self.drawRing(spec: spec, in: ringRect, phase: phase)

            if showsText {
                let textRect = NSRect(
                    x: ringRect.maxX + gap,
                    y: 0,
                    width: textWidth,
                    height: size.height)
                self.drawPercentLabel(spec: spec, in: textRect)
            }
        }
    }

    private static func drawRing(spec: GlanceIconSpec, in rect: NSRect, phase: CGFloat) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let lineWidth: CGFloat = 2.4
        let radius = rect.width / 2 - lineWidth / 2

        // Colore semantico (o label color in monocromo). DIM abbassa l'opacità senza falsare il colore.
        let isLight = spec.appearance == .light
        let baseColor: NSColor = spec.monochrome
            ? .labelColor
            : self.contrastAdjusted(self.color(forUsed: spec.used), light: isLight)
        let dimFactor: CGFloat = spec.dim ? 0.45 : 1.0

        // Pulsazione: nello stato `.empty` (≥95%) l'opacità oscilla. Reduce Motion → gestito a monte
        // (lo StatusItemController passa animation = .none), qui rispettiamo solo `phase`.
        var pulseAlpha: CGFloat = 1
        if spec.animation == .pulse {
            pulseAlpha = 0.55 + 0.45 * (0.5 + 0.5 * sin(phase))
        }

        // Track di fondo (anello tenue).
        let trackColor = (spec.monochrome ? NSColor.labelColor : baseColor)
            .withAlphaComponent(0.22 * dimFactor)
        ctx.setLineWidth(lineWidth)
        ctx.setStrokeColor(trackColor.cgColor)
        ctx.addArc(center: center, radius: radius, startAngle: 0, endAngle: .pi * 2, clockwise: false)
        ctx.strokePath()

        // Arco di riempimento = frazione USATA, parte da ore 12 e va in senso orario.
        // In loadingSpin l'arco è un segmento fisso che ruota con `phase`.
        let used = max(0, min(spec.used, 1))
        let strokeColor = baseColor.withAlphaComponent(pulseAlpha * dimFactor)
        ctx.setStrokeColor(strokeColor.cgColor)
        ctx.setLineCap(.round)

        if spec.animation == .loadingSpin {
            let arcLength: CGFloat = .pi * 0.6
            let start = -.pi / 2 + phase
            ctx.addArc(
                center: center,
                radius: radius,
                startAngle: start,
                endAngle: start + arcLength,
                clockwise: false)
            ctx.strokePath()
        } else if used > 0.0001 {
            // 12 in punto = -90°; senso orario = clockwise true in coordinate flippate Core Graphics.
            let startAngle: CGFloat = .pi / 2
            let sweep = CGFloat(used) * .pi * 2
            var endAngle = startAngle - sweep
            if spec.animation == .refreshSpin {
                // Micro-rotazione dell'intero arco durante un refresh.
                endAngle -= phase
            }
            let spinOffset: CGFloat = spec.animation == .refreshSpin ? -phase : 0
            ctx.addArc(
                center: center,
                radius: radius,
                startAngle: startAngle + spinOffset,
                endAngle: endAngle,
                clockwise: true)
            ctx.strokePath()
        }

        // Secondo arco interno per lo stile dualBar (settimanale).
        if spec.style == .dualBar, let weekly = spec.weeklyUsed {
            let innerRadius = radius - lineWidth - 1.2
            if innerRadius > 1 {
                let weeklyColor = (spec.monochrome ? NSColor.labelColor : self.contrastAdjusted(self.color(forUsed: weekly), light: isLight))
                    .withAlphaComponent(0.30 * dimFactor)
                ctx.setLineWidth(1.6)
                ctx.setStrokeColor(weeklyColor.cgColor)
                ctx.addArc(center: center, radius: innerRadius, startAngle: 0, endAngle: .pi * 2, clockwise: false)
                ctx.strokePath()

                let w = max(0, min(weekly, 1))
                if w > 0.0001 {
                    let weeklyFill = (spec.monochrome ? NSColor.labelColor : self.contrastAdjusted(self.color(forUsed: weekly), light: isLight))
                        .withAlphaComponent(dimFactor)
                    ctx.setStrokeColor(weeklyFill.cgColor)
                    ctx.addArc(
                        center: center,
                        radius: innerRadius,
                        startAngle: .pi / 2,
                        endAngle: .pi / 2 - CGFloat(w) * .pi * 2,
                        clockwise: true)
                    ctx.strokePath()
                }
            }
        }
    }

    private static func drawPercentLabel(spec: GlanceIconSpec, in rect: NSRect) {
        let value: Int
        switch spec.percentLabel {
        case .used:
            value = Int((spec.used * 100).rounded())
        case .remaining:
            value = Int(((1 - spec.used) * 100).rounded())
        case .hidden:
            return
        }

        let dimFactor: CGFloat = spec.dim ? 0.5 : 1.0
        let textColor: NSColor = spec.monochrome
            ? .labelColor
            : self.contrastAdjusted(self.color(forUsed: spec.used), light: spec.appearance == .light)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9.5, weight: .semibold),
            .foregroundColor: textColor.withAlphaComponent(dimFactor),
        ]
        let text = "\(value)" as NSString
        let textSize = text.size(withAttributes: attributes)
        let origin = NSPoint(
            x: rect.minX,
            y: (rect.height - textSize.height) / 2)
        text.draw(at: origin, withAttributes: attributes)
    }

    // MARK: - Bitmap context

    private static func renderImage(size: NSSize, monochrome: Bool, _ draw: () -> Void) -> NSImage {
        let image = NSImage(size: size)
        if let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width * outputScale),
            pixelsHigh: Int(size.height * outputScale),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0)
        {
            rep.size = size
            image.addRepresentation(rep)
            NSGraphicsContext.saveGraphicsState()
            if let ctx = NSGraphicsContext(bitmapImageRep: rep) {
                NSGraphicsContext.current = ctx
                ctx.cgContext.setShouldAntialias(true)
                draw()
            }
            NSGraphicsContext.restoreGraphicsState()
        } else {
            image.lockFocus()
            draw()
            image.unlockFocus()
        }

        // isTemplate=false: il colore è l'informazione. In monocromo lasciamo che il sistema
        // ricolori l'icona come template (B/N).
        image.isTemplate = monochrome
        return image
    }
}

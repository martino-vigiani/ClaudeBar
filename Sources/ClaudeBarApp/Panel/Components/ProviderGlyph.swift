import AppKit
import SwiftUI

/// Glifo di un provider: logo brand monocromo (template PNG in `Resources/providers/`) se presente,
/// altrimenti l'SF Symbol di fallback del descriptor. L'immagine è renderizzata come **template**
/// → si tinge col `foregroundStyle` del contesto, esattamente come una SF Symbol (coerente col
/// design neutro). I loghi restano marchi dei rispettivi proprietari (uso nominativo, identificazione).
struct ProviderGlyph: View {
    /// `ProviderID.rawValue` (es. "claude", "codex", "openai_api").
    let providerID: String
    /// SF Symbol del branding, usato se manca l'asset brand.
    let fallbackSymbol: String
    var size: CGFloat = 15

    var body: some View {
        if let image = Self.brandImage(for: self.providerID) {
            Image(nsImage: image)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: self.size, height: self.size)
        } else {
            Image(systemName: self.fallbackSymbol)
                .font(.system(size: self.size))
        }
    }

    /// Mappa `ProviderID.rawValue` → nome file dell'asset brand. Codex usa il logo OpenAI; le API a
    /// consumo usano il logo del vendor (OpenAI / Anthropic).
    private static func assetName(for providerID: String) -> String? {
        switch providerID {
        case "claude": "claude"
        case "codex", "openai_api": "openai"
        case "gemini": "gemini"
        case "cursor": "cursor"
        case "anthropic_api": "anthropic"
        default: nil
        }
    }

    /// Cache delle `NSImage` template (evita di rileggere il PNG da disco a ogni body eval).
    /// Accesso solo dal `body` (MainActor) → niente race.
    @MainActor private static var cache: [String: NSImage] = [:]

    @MainActor private static func brandImage(for providerID: String) -> NSImage? {
        guard let name = self.assetName(for: providerID) else { return nil }
        if let cached = self.cache[name] { return cached }
        guard
            let url = Bundle.main.url(forResource: name, withExtension: "png", subdirectory: "providers"),
            let image = NSImage(contentsOf: url)
        else { return nil }
        image.isTemplate = true
        self.cache[name] = image
        return image
    }
}

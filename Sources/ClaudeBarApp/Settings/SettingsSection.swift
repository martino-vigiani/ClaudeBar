import SwiftUI

/// Sezioni della finestra Impostazioni, nell'ordine della sidebar (BRIEF §IA consigliata).
///
/// CONTRATTO (congelato dall'architetto): ogni caso ha una view di dettaglio dedicata,
/// risolta in `SettingsRootView.detail(for:)`. Gli implementatori riempiono il CORPO della
/// rispettiva view (`*SettingsSection`) SENZA toccare questo enum, lo shell o le firme del
/// `SettingsStore`. Per aggiungere un'opzione: si aggiunge una proprietà al `SettingsStore`
/// (con default + persistenza) e la si lega nella view di sezione.
enum SettingsSection: String, CaseIterable, Identifiable {
    case general
    case menuBar
    case providers
    case notifications
    case analytics
    case advanced
    case about

    var id: String { self.rawValue }

    /// Titolo nella sidebar e in cima al pannello di dettaglio.
    var title: String {
        switch self {
        case .general: "Generale"
        case .menuBar: "Menu bar"
        case .providers: "Provider"
        case .notifications: "Notifiche"
        case .analytics: "Analytics"
        case .advanced: "Avanzato"
        case .about: "Info"
        }
    }

    /// SF Symbol della riga di sidebar (monocromo, coerente con l'app).
    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .menuBar: "menubar.rectangle"
        case .providers: "square.stack.3d.up"
        case .notifications: "bell"
        case .analytics: "chart.bar"
        case .advanced: "wrench.and.screwdriver"
        case .about: "info.circle"
        }
    }

    /// Sottotitolo opzionale mostrato sotto il titolo della sezione (didascalia).
    var subtitle: String? {
        switch self {
        case .general: "Avvio, aggiornamento, aspetto"
        case .menuBar: "Icona, percentuale, soglie colore"
        case .providers: "Account, chiavi, default"
        case .notifications: "Soglie e celebrazioni"
        case .analytics: "Periodo, costi, pricing"
        case .advanced: "Dati, cache, esporta, reset"
        case .about: nil
        }
    }
}

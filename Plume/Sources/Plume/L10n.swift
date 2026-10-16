import AppKit

/// Langue de l'interface : français ou anglais. Le texte dicté,
/// lui, reste dans la langue où il a été prononcé.
enum AppLanguage: String, CaseIterable, Identifiable {
    case fr, en
    var id: String { rawValue }
    /// Chaque langue s'écrit dans sa propre langue.
    var label: String { self == .fr ? "Français" : "English" }
    var locale: Locale { Locale(identifier: self == .fr ? "fr_FR" : "en_US") }

    /// Réglage enregistré, sinon l'anglais (le français se choisit dès la
    /// première page de l'assistant).
    static var current: AppLanguage {
        if let raw = UserDefaults.standard.string(forKey: "appLanguage"), let l = AppLanguage(rawValue: raw) { return l }
        return .en
    }
}

/// Le texte de l'interface dans la langue choisie : `L("Annuler", "Cancel")`.
func L(_ fr: String, _ en: String) -> String { AppLanguage.current == .en ? en : fr }

/// Apparence de l'app : celle du Mac, ou forcée en clair / sombre.
enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return L("Système", "System")
        case .light: return L("Clair", "Light")
        case .dark: return L("Sombre", "Dark")
        }
    }

    var symbol: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light: return "sun.max"
        case .dark: return "moon"
        }
    }

    static var current: AppAppearance {
        AppAppearance(rawValue: UserDefaults.standard.string(forKey: "appAppearance") ?? "") ?? .system
    }

    /// Appliquée à toute l'app (fenêtres, pastille, assistant).
    @MainActor func apply() {
        switch self {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

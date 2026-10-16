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

/// Un nombre dans la langue de l'app (« 1 225 » / « 1,225 »), pas celle du Mac.
func formatNumber(_ n: Int) -> String {
    n.formatted(.number.locale(AppLanguage.current.locale))
}

/// Une taille de fichier dans la langue de l'app : « 632,3 Mo » / « 632.3 MB ».
func formatBytes(_ bytes: Int64) -> String {
    let fr = AppLanguage.current == .fr
    let units = fr ? ["octets", "Ko", "Mo", "Go"] : ["bytes", "KB", "MB", "GB"]
    var value = Double(bytes)
    var unit = 0
    while value >= 1000 && unit < units.count - 1 { value /= 1000; unit += 1 }
    let digits = unit >= 2 ? 1 : 0
    return value.formatted(.number.precision(.fractionLength(0...digits)).locale(AppLanguage.current.locale)) + " " + units[unit]
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

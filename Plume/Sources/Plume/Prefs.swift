import Foundation
import CoreGraphics
import SwiftUI
import AppKit

enum DictationLanguage: String, CaseIterable, Identifiable {
    case auto, fr, en, es, de, it, pt
    var id: String { rawValue }
    var label: String {
        switch self {
        case .auto: return L("Détection automatique (recommandé)", "Automatic detection (recommended)")
        case .fr: return L("Français", "French")
        case .en: return L("Anglais", "English")
        case .es: return L("Espagnol", "Spanish")
        case .de: return L("Allemand", "German")
        case .it: return L("Italien", "Italian")
        case .pt: return L("Portugais", "Portuguese")
        }
    }
    /// Nom de la langue pour la consigne du lissage.
    var promptName: String {
        switch self {
        case .auto: return "dans sa langue d'origine (souvent le français ou l'anglais, parfois une autre) — garde-la telle quelle, ne traduis jamais"
        case .fr: return "en français"
        case .en: return "en anglais"
        case .es: return "en espagnol"
        case .de: return "en allemand"
        case .it: return "en italien"
        case .pt: return "en portugais"
        }
    }
}

/// Les teintes proposées pour la pastille : vives mais douces. Une sélection
/// plutôt qu'un nuancier libre, pour que la pastille reste toujours lisible
/// sur son fond noir.
enum PillTint: String, CaseIterable, Identifiable {
    case cyan, blue, lavender, violet, pink, coral, red, amber, orange, yellow, mint, green

    var id: String { rawValue }

    var label: String {
        switch self {
        case .cyan: return "Cyan"
        case .blue: return L("Bleu", "Blue")
        case .lavender: return L("Lavande", "Lavender")
        case .violet: return L("Violet", "Purple")
        case .pink: return L("Rose", "Pink")
        case .coral: return L("Corail", "Coral")
        case .red: return L("Rouge", "Red")
        case .amber: return L("Ambre", "Amber")
        case .orange: return "Orange"
        case .yellow: return L("Jaune", "Yellow")
        case .mint: return L("Menthe", "Mint")
        case .green: return L("Vert", "Green")
        }
    }

    var color: Color {
        switch self {
        case .cyan: return Color(hex: 0x33D6E0)
        case .blue: return Color(hex: 0x4D9FFF)
        case .lavender: return Color(hex: 0xB4A7FF)
        case .violet: return Color(hex: 0x9D6BFF)
        case .pink: return Color(hex: 0xFF77B7)
        case .coral: return Color(hex: 0xFF8A7A)
        case .red: return Color(hex: 0xFF5A5F)
        case .amber: return Color(hex: 0xF5A623)
        case .orange: return Color(hex: 0xFF8C42)
        case .yellow: return Color(hex: 0xF7D04A)
        case .mint: return Color(hex: 0x5FD29A)
        case .green: return Color(hex: 0x8BD957)
        }
    }

    /// Lu sans passer par `Prefs` (qui vit sur le fil principal) : les vues de
    /// la pastille et de la fenêtre lisent la teinte au moment de se dessiner.
    static func stored(_ key: String, default fallback: PillTint) -> PillTint {
        PillTint(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? fallback
    }
}

/// Réglages de Plume, gardés dans les UserDefaults.
@MainActor
final class Prefs: ObservableObject {
    static let shared = Prefs()
    private let defaults = UserDefaults.standard

    /// Le raccourci de dictée (fn par défaut).
    @Published var shortcut: Shortcut {
        didSet {
            if let data = try? JSONEncoder().encode(shortcut) { defaults.set(data, forKey: "shortcut") }
        }
    }
    /// Langue de l'interface (le texte dicté n'est jamais traduit).
    @Published var appLanguage: AppLanguage {
        didSet {
            defaults.set(appLanguage.rawValue, forKey: "appLanguage")
            AppDelegate.shared?.rebuildMenu()
        }
    }
    /// Clair, sombre ou comme le Mac.
    @Published var appearance: AppAppearance {
        didSet {
            defaults.set(appearance.rawValue, forKey: "appAppearance")
            appearance.apply()
        }
    }
    /// Langue parlée : guide Whisper et le lissage (Parakeet détecte seul).
    @Published var language: DictationLanguage {
        didSet { defaults.set(language.rawValue, forKey: "language") }
    }
    /// Parakeet détecte toujours la langue seul ; la langue choisie sert alors au nettoyage.
    var effectiveLanguage: DictationLanguage { language }
    /// Nettoyage du texte par un modèle de langage, quand le réseau est là.
    @Published var polishEnabled: Bool {
        didSet { defaults.set(polishEnabled, forKey: "polishEnabled") }
    }
    /// Où se fait le nettoyage.
    @Published var polishService: PolishService {
        didSet {
            defaults.set(polishService.rawValue, forKey: "polishService")
            polishModel = defaults.string(forKey: "polishModel_\(polishService.rawValue)") ?? ""
        }
    }
    @Published var polishCustomURL: String {
        didSet { defaults.set(polishCustomURL, forKey: "polishCustomURL") }
    }
    /// Le modèle du service choisi (vide = celui par défaut).
    @Published var polishModel: String {
        didSet { defaults.set(polishModel, forKey: "polishModel_\(polishService.rawValue)") }
    }
    /// Transcription en ligne (modèle « En ligne ») : le service, son adresse, son modèle.
    @Published var sttService: TranscriptionService {
        didSet {
            defaults.set(sttService.rawValue, forKey: "sttService")
            sttModel = defaults.string(forKey: "sttModel_\(sttService.rawValue)") ?? ""
        }
    }
    @Published var sttCustomURL: String {
        didSet { defaults.set(sttCustomURL, forKey: "sttCustomURL") }
    }
    @Published var sttModel: String {
        didSet { defaults.set(sttModel, forKey: "sttModel_\(sttService.rawValue)") }
    }
    /// Icône dans la barre des menus (désactivée par défaut).
    @Published var showInMenuBar: Bool {
        didSet {
            defaults.set(showInMenuBar, forKey: "showInMenuBar")
            StatusItemController.shared.update()
        }
    }
    /// Petit son au début et à la fin d'une dictée.
    @Published var soundsEnabled: Bool {
        didSet { defaults.set(soundsEnabled, forKey: "soundsEnabled") }
    }

    /// Couleur des barres pendant l'écoute (cyan par défaut).
    @Published var listenTint: PillTint {
        didSet { defaults.set(listenTint.rawValue, forKey: "listenTint") }
    }
    /// Couleur des barres pendant le traitement, après le 2ᵉ appui (ambre).
    @Published var thinkTint: PillTint {
        didSet { defaults.set(thinkTint.rawValue, forKey: "thinkTint") }
    }

    /// Le moteur reste chargé ce temps après la dernière dictée, puis il est
    /// arrêté et rend sa mémoire (-1 = jamais). Lu aussi hors du fil principal
    /// par `Prefs.idleSeconds`.
    @Published var engineIdle: Double {
        didSet { defaults.set(engineIdle, forKey: "engineIdleSeconds") }
    }
    static let idleChoices: [Double] = [15, 35, 60, 120, 300, 900, -1]

    private init() {
        shortcut = Self.loadShortcut(defaults)
        appLanguage = AppLanguage.current
        appearance = AppAppearance.current
        language = DictationLanguage(rawValue: defaults.string(forKey: "language") ?? "") ?? .auto
        polishEnabled = defaults.object(forKey: "polishEnabled") as? Bool ?? true
        soundsEnabled = defaults.object(forKey: "soundsEnabled") as? Bool ?? false
        polishService = .current
        polishCustomURL = defaults.string(forKey: "polishCustomURL") ?? ""
        let service = PolishService.current
        polishModel = defaults.string(forKey: "polishModel_\(service.rawValue)")
            ?? (service == .custom ? defaults.string(forKey: "polishCustomModel") ?? "" : "")
        let stt = TranscriptionService.current
        sttService = stt
        sttCustomURL = defaults.string(forKey: "sttCustomURL") ?? ""
        sttModel = defaults.string(forKey: "sttModel_\(stt.rawValue)") ?? ""
        showInMenuBar = defaults.bool(forKey: "showInMenuBar")
        engineIdle = Prefs.idleSeconds
        listenTint = PillTint.stored("listenTint", default: .cyan)
        thinkTint = PillTint.stored("thinkTint", default: .amber)
    }

    /// Lit le raccourci ; reprend l'ancien réglage `trigger`.
    private static func loadShortcut(_ d: UserDefaults) -> Shortcut {
        if let data = d.data(forKey: "shortcut"), let s = try? JSONDecoder().decode(Shortcut.self, from: data) { return s }
        let old: [String: Int64] = ["leftOption": 58, "rightOption": 61, "rightCommand": 54, "rightControl": 62, "fn": 63]
        if let code = old[d.string(forKey: "trigger") ?? ""], let s = Shortcut.modifierKey(code) { return s }
        // Installée avant que fn devienne le défaut : on garde ⌥ gauche, et on l'enregistre.
        if d.bool(forKey: "onboardingDone"), let old = Shortcut.modifierKey(58) {
            if let data = try? JSONEncoder().encode(old) { d.set(data, forKey: "shortcut") }
            return old
        }
        return .default
    }

    /// L'assistant de premier lancement a été parcouru jusqu'au bout.
    var onboardingDone: Bool {
        get { defaults.bool(forKey: "onboardingDone") }
        set { defaults.set(newValue, forKey: "onboardingDone") }
    }

    var isFirstLaunch: Bool {
        get { !defaults.bool(forKey: "launchedOnce") }
        set { defaults.set(!newValue, forKey: "launchedOnce") }
    }
}

extension Color {
    /// La couleur de thème de Plume : l'indigo du logo (dégradé #7C8CFF →
    /// #4338CA), plus foncé en mode clair, plus lumineux en sombre.
    /// Icônes, accents, boutons et liens de la fenêtre. La pastille, elle,
    /// garde les couleurs choisies dans les réglages.
    static let plumeTheme = Color(nsColor: NSColor(name: "plumeTheme") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0x8B / 255.0, green: 0x93 / 255.0, blue: 0xFF / 255.0, alpha: 1)
            : NSColor(srgbRed: 0x4F / 255.0, green: 0x46 / 255.0, blue: 0xE5 / 255.0, alpha: 1)
    })
    /// Couleur d'écoute choisie dans les réglages (défaut : cyan #33D6E0).
    static var plumeAccent: Color { PillTint.stored("listenTint", default: .cyan).color }
    /// Couleur de traitement choisie dans les réglages (défaut : ambre #F5A623).
    static var plumeThinking: Color { PillTint.stored("thinkTint", default: .amber).color }
    /// Le vert « terminé » (#5FD29A).
    static let plumeDone = Color(red: 95 / 255, green: 210 / 255, blue: 154 / 255)

    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}

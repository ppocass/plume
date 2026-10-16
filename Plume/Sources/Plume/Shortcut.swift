import AppKit
import CoreGraphics

/// Le raccourci de dictée, choisi dans les réglages. Deux sortes :
///
/// - **une touche modificatrice appuyée et relâchée seule** (Option gauche,
///   fn par défaut, ⌥ gauche, ⌘ droite…) — ⌥ + une lettre continue de taper les
///   caractères spéciaux, rien n'est bloqué ;
/// - **une combinaison** (⌃⇧W, ⌥Espace, F5…) — elle est **interceptée** : elle
///   ne fait plus rien dans les autres apps.
///
/// Gardé dans les UserDefaults (clé `shortcut`, en JSON).
struct Shortcut: Codable, Equatable {
    enum Kind: String, Codable { case modifier, combo }

    var kind: Kind
    /// Code de touche macOS (kVK_…).
    var keyCode: Int64
    /// Combinaison : les modificateurs exigés (⌘ ⌃ ⌥ ⇧, masque CGEventFlags),
    /// ni plus ni moins. Touche seule : inutilisé.
    var modifiers: UInt64
    /// Ce que l'app affiche : « ⌥ gauche », « ⌃⇧W ».
    var display: String

    /// fn par défaut : la touche que la plupart des apps de dictée utilisent.
    static let `default` = Shortcut.modifierKey(63)!

    /// Ce que l'app affiche, dans la langue de l'interface (« ⌥ gauche » /
    /// « Left ⌥ », « ⌃⇧Espace » / « ⌃⇧Space »).
    var label: String {
        if kind == .modifier { return Self.mods[keyCode]?.name ?? display }
        let symbols = (CGEventFlags(rawValue: modifiers).contains(.maskControl) ? "⌃" : "")
            + (CGEventFlags(rawValue: modifiers).contains(.maskAlternate) ? "⌥" : "")
            + (CGEventFlags(rawValue: modifiers).contains(.maskShift) ? "⇧" : "")
            + (CGEventFlags(rawValue: modifiers).contains(.maskCommand) ? "⌘" : "")
        if let f = Self.fKeys[keyCode] { return symbols + f }
        if let n = Self.named[keyCode] { return symbols + L(n.fr, n.en) }
        return symbols + String(display.drop(while: { "⌃⌥⇧⌘".contains($0) }))
    }

    // MARK: Touches modificatrices seules

    /// Bit « côté » (NX_DEVICE…KEYMASK) qui distingue gauche et droite, le
    /// drapeau général du modificateur, et son nom.
    private struct ModInfo {
        let side: UInt64; let general: CGEventFlags; let fr: String; let en: String
        var name: String { L(fr, en) }
    }

    private static let mods: [Int64: ModInfo] = [
        58: ModInfo(side: 0x20, general: .maskAlternate, fr: "⌥ gauche", en: "Left ⌥"),
        61: ModInfo(side: 0x40, general: .maskAlternate, fr: "⌥ droite", en: "Right ⌥"),
        55: ModInfo(side: 0x08, general: .maskCommand, fr: "⌘ gauche", en: "Left ⌘"),
        54: ModInfo(side: 0x10, general: .maskCommand, fr: "⌘ droite", en: "Right ⌘"),
        59: ModInfo(side: 0x01, general: .maskControl, fr: "⌃ gauche", en: "Left ⌃"),
        62: ModInfo(side: 0x2000, general: .maskControl, fr: "⌃ droite", en: "Right ⌃"),
        56: ModInfo(side: 0x02, general: .maskShift, fr: "⇧ gauche", en: "Left ⇧"),
        60: ModInfo(side: 0x04, general: .maskShift, fr: "⇧ droite", en: "Right ⇧"),
        63: ModInfo(side: 0, general: .maskSecondaryFn, fr: "fn", en: "fn"),
    ]

    static func isModifierKey(_ code: Int64) -> Bool { mods[code] != nil }

    static func modifierKey(_ code: Int64) -> Shortcut? {
        guard let info = mods[code] else { return nil }
        return Shortcut(kind: .modifier, keyCode: code, modifiers: 0, display: info.name)
    }

    /// Les choix rapides proposés dans les réglages.
    static let presets: [Shortcut] = [58, 61, 54, 62, 63].compactMap { modifierKey($0) }

    /// La touche modificatrice est-elle enfoncée d'après ces drapeaux ?
    func isDown(_ flags: CGEventFlags) -> Bool {
        guard kind == .modifier, let info = Self.mods[keyCode] else { return false }
        if keyCode == 63 { return flags.contains(.maskSecondaryFn) }
        return flags.rawValue & info.side != 0
    }

    /// Un autre modificateur (ou l'autre côté du même) est-il déjà tenu ?
    func otherModifiersHeld(_ flags: CGEventFlags) -> Bool {
        guard let info = Self.mods[keyCode] else { return true }
        var others: CGEventFlags = [.maskCommand, .maskControl, .maskShift, .maskAlternate]
        others.remove(info.general)
        if !flags.intersection(others).isEmpty { return true }
        guard info.side != 0 else { return false }
        // Même modificateur, côté opposé (ex. Option droite pendant Option gauche).
        let sameKindSides = Self.mods.values.filter { $0.general == info.general && $0.side != 0 }.map(\.side)
        let otherSide = sameKindSides.filter { $0 != info.side }.reduce(0, |)
        return flags.rawValue & otherSide != 0
    }

    // MARK: Combinaisons

    static let comboMask: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]

    /// Une frappe correspond-elle à la combinaison (modificateurs exacts) ?
    func matches(keyCode code: Int64, flags: CGEventFlags) -> Bool {
        kind == .combo && code == keyCode && flags.intersection(Self.comboMask).rawValue == modifiers
    }

    /// Construit une combinaison depuis une frappe enregistrée. `nil` + raison
    /// si elle n'est pas utilisable.
    static func combo(from event: NSEvent) -> (Shortcut?, String?) {
        let code = Int64(event.keyCode)
        var cg: CGEventFlags = []
        let f = event.modifierFlags
        if f.contains(.command) { cg.insert(.maskCommand) }
        if f.contains(.control) { cg.insert(.maskControl) }
        if f.contains(.option) { cg.insert(.maskAlternate) }
        if f.contains(.shift) { cg.insert(.maskShift) }
        let isFKey = fKeys[code] != nil
        // Sans ⌘ ⌃ ou ⌥, une lettre (même avec ⇧) empêcherait de l'écrire.
        if !isFKey && cg.intersection([.maskCommand, .maskControl, .maskAlternate]).isEmpty {
            return (nil, L("Ajoutez ⌘, ⌃ ou ⌥.", "Add ⌘, ⌃ or ⌥."))
        }
        let key = keyName(code, event: event)
        let symbols = (cg.contains(.maskControl) ? "⌃" : "") + (cg.contains(.maskAlternate) ? "⌥" : "")
            + (cg.contains(.maskShift) ? "⇧" : "") + (cg.contains(.maskCommand) ? "⌘" : "")
        return (Shortcut(kind: .combo, keyCode: code, modifiers: cg.rawValue, display: symbols + key), nil)
    }

    private static let fKeys: [Int64: String] = [
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
        101: "F9", 109: "F10", 103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15",
    ]
    private static let named: [Int64: (fr: String, en: String)] = [
        49: ("Espace", "Space"), 36: ("↩", "↩"), 48: ("⇥", "⇥"), 51: ("⌫", "⌫"), 117: ("⌦", "⌦"), 53: ("Échap", "Esc"),
        123: ("←", "←"), 124: ("→", "→"), 125: ("↓", "↓"), 126: ("↑", "↑"), 115: ("↖", "↖"), 119: ("↘", "↘"),
        116: ("⇞", "⇞"), 121: ("⇟", "⇟"),
    ]

    private static func keyName(_ code: Int64, event: NSEvent) -> String {
        if let f = fKeys[code] { return f }
        if let n = named[code] { return n.fr }
        let chars = event.charactersIgnoringModifiers ?? ""
        return chars.isEmpty ? "#\(code)" : chars.uppercased()
    }

    // MARK: Textes de l'app

    /// Pied de la section Raccourci des réglages.
    var explanation: String {
        switch kind {
        case .modifier where keyCode == 63:
            return L("Appuyée seule. Pour que macOS ne réagisse pas en même temps, réglez Réglages Système → Clavier → « Appuyer sur la touche 🌐 » sur « Ne rien faire ».",
                     "Pressed on its own. So macOS doesn't react too, set System Settings → Keyboard → “Press 🌐 key to” to “Do Nothing”.")
        case .modifier: return L("Appuyée seule. Avec une autre touche, elle garde son rôle habituel.",
                                 "Pressed on its own. With other keys, it works as usual.")
        case .combo: return L("Réservée à Plume dans toutes les apps.", "Reserved for Plume in every app.")
        }
    }
}

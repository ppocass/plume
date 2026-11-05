import AppKit
import CoreGraphics

/// Le raccourci de dictée, choisi dans les réglages. Trois sortes :
///
/// - **une touche modificatrice appuyée et relâchée seule** (Option gauche,
///   fn par défaut, ⌥ gauche, ⌘ droite…) — ⌥ + une lettre continue de taper les
///   caractères spéciaux, rien n'est bloqué ;
/// - **une combinaison** (⌃⇧W, ⌥Espace, F5…) — elle est **interceptée** : elle
///   ne fait plus rien dans les autres apps ;
/// - **deux touches modificatrices tenues ensemble** (⌘ gauche + ⌥ gauche) —
///   le raccourci de la dictée 1337. Il se déclenche **au relâchement de l'une
///   des deux**, sans touche, et rien n'est avalé (⌘⌥+lettre garde son rôle).
///
/// Gardé dans les UserDefaults (clés `shortcut` et `leetShortcut`, en JSON).
struct Shortcut: Codable, Equatable {
    enum Kind: String, Codable { case modifier, combo, modifierCombo }

    var kind: Kind
    /// Code de touche macOS (kVK_…).
    var keyCode: Int64
    /// Combinaison : les modificateurs exigés (⌘ ⌃ ⌥ ⇧, masque CGEventFlags),
    /// ni plus ni moins. Touche seule : inutilisé.
    var modifiers: UInt64
    /// Ce que l'app affiche : « ⌥ gauche », « ⌃⇧W ».
    var display: String
    /// Deux touches modificatrices tenues ensemble : la seconde. (`nil` pour
    /// les deux autres sortes — et pour les raccourcis enregistrés avant
    /// l'arrivée du 1337, que le décodeur sait toujours lire.)
    var secondKeyCode: Int64? = nil

    /// fn par défaut : la touche que la plupart des apps de dictée utilisent.
    static let `default` = Shortcut.modifierKey(63)!

    /// Ce que l'app affiche, dans la langue de l'interface (« ⌥ gauche » /
    /// « Left ⌥ », « ⌃⇧Espace » / « ⌃⇧Space », « ⌘ gauche + ⌥ gauche »).
    var label: String {
        if kind == .modifier { return Self.mods[keyCode]?.name ?? display }
        if kind == .modifierCombo {
            let first = Self.mods[keyCode]?.name ?? display
            guard let second = secondKeyCode.flatMap({ Self.mods[$0] }) else { return first }
            return "\(first) + \(second.name)"
        }
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

    /// Quelles touches modificatrices (avec leur côté) sont enfoncées, dans
    /// l'ordre d'affichage ⌘ ⌥ ⌃ ⇧. Sert à l'enregistrement d'un couple :
    /// `NSEvent.modifierFlags` ne distingue pas gauche et droite, les drapeaux
    /// CoreGraphics si (bits NX_DEVICE…KEYMASK).
    static func downModifierKeys(_ flags: CGEventFlags) -> [Int64] {
        mods.filter { code, info in
            code != 63 && (code == 63 ? flags.contains(.maskSecondaryFn) : flags.rawValue & info.side != 0)
        }
        .sorted { pairOrder($0.value) < pairOrder($1.value) }
        .map(\.key)
    }

    static func modifierKey(_ code: Int64) -> Shortcut? {
        guard let info = mods[code] else { return nil }
        return Shortcut(kind: .modifier, keyCode: code, modifiers: 0, display: info.name)
    }

    /// Les choix rapides proposés dans les réglages.
    static let presets: [Shortcut] = [58, 61, 54, 62, 63].compactMap { modifierKey($0) }

    /// La touche modificatrice est-elle enfoncée d'après ces drapeaux ?
    /// (Vaut pour les deux sortes qui reposent sur une touche modificatrice.)
    func isDown(_ flags: CGEventFlags) -> Bool {
        guard kind != .combo, let info = Self.mods[keyCode] else { return false }
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

    // MARK: Deux modificateurs tenus ensemble

    /// ⌘ gauche + ⌥ gauche : le geste par défaut du 1337.
    /// Le raccourci 1337 d'origine : **⌘ gauche + ⌥ gauche**.
    ///
    /// ⚠️ Ce n'est **plus le défaut d'une nouvelle installation** : la dictée
    /// est sur **fn**, donc le 1337 se donne sur **⌘ + fn**, qui est le même
    /// geste plus une touche et évite d'aller chercher ⌥. Pierre a choisi ⌘⌥
    /// pour lui, et son réglage est conservé ; `leetPairFor(_:)` fait suivre
    /// un raccourci de dictée modifié.
    static let leetLegacyDefault = comboModifiers(55, 58)!

    /// Le couple 1337 qui correspond à une touche de dictée : **⌘ + cette
    /// touche**. fn → ⌘+fn. Refusé si la touche est déjà ⌘ (on ne peut pas
    /// appuyer deux fois dessus) ou si ce n'est pas un modificateur.
    static func leetPairFor(_ dictation: Shortcut) -> Shortcut? {
        guard dictation.kind == .modifier, dictation.keyCode != 55, dictation.keyCode != 54 else { return nil }
        return comboModifiers(55, dictation.keyCode, allowFn: true)
    }


    /// Un raccourci « deux modificateurs tenus ensemble ». Refusé (nil) si
    /// l'une des touches ne s'appuie pas seule (`fn`), si les deux sont la même,
    /// ou si c'est deux fois le même modificateur (⌘ gauche + ⌘ droite) : on ne
    /// saurait pas lequel garder appuyé avant de relâcher l'autre.
    static func comboModifiers(_ first: Int64, _ second: Int64) -> Shortcut? {
        comboModifiers(first, second, allowFn: false)
    }

    /// `allowFn` : accepte **⌘ + fn** (le couple 1337 par défaut). `fn` est
    /// refusé dans les autres couples parce qu'il sert de touche de dictée :
    /// le tenir avec ⌥ ou ⌃ n'a pas de sens, mais avec ⌘ il donne un second
    /// geste cohérent avec la touche de dictée.
    static func comboModifiers(_ first: Int64, _ second: Int64, allowFn: Bool) -> Shortcut? {
        let fn = { (c: Int64) in c == 63 }
        guard (allowFn || (!fn(first) && !fn(second))), first != second,
              let a = mods[first], let b = mods[second], a.general != b.general else { return nil }
        // Ordre fixe (⌘, ⌥, ⌃, ⇧) : ⌘⌥ et ⌥⌘ sont le même raccourci, et l'ordre
        // de frappe ne change ni l'égalité ni ce qui s'affiche.
        let (x, y) = Self.pairOrder(a) <= Self.pairOrder(b) ? (first, second) : (second, first)
        let ax = mods[x]!, ay = mods[y]!
        return Shortcut(kind: .modifierCombo, keyCode: x, modifiers: 0,
                        display: "\(ax.name) + \(ay.name)", secondKeyCode: y)
    }

    /// Rangement d'affichage : ⌘, puis ⌥, puis ⌃, puis ⇧.
    private static func pairOrder(_ m: ModInfo) -> Int {
        switch m.general {
        case .maskCommand: return 0
        case .maskAlternate: return 1
        case .maskControl: return 2
        default: return 3
        }
    }

    /// Les couples proposés en un clic dans les réglages du 1337.
    static let pairPresets: [Shortcut] = [(55, 58), (58, 56), (59, 58), (55, 56), (54, 61)]
        .compactMap { comboModifiers($0.0, $0.1) }

    /// Les deux touches sont-elles enfoncées d'après ces drapeaux ?
    func bothDown(_ flags: CGEventFlags) -> Bool {
        guard kind == .modifierCombo, let second = secondKeyCode else { return false }
        return isDown(flags) && Shortcut(kind: .modifier, keyCode: second, modifiers: 0, display: "").isDown(flags)
    }

    /// Une touche du couple est-elle enfoncée ?
    func anyDown(_ flags: CGEventFlags) -> Bool {
        guard kind == .modifierCombo, let second = secondKeyCode else { return false }
        let other = Shortcut(kind: .modifier, keyCode: second, modifiers: 0, display: "")
        return isDown(flags) || other.isDown(flags)
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
        case .modifierCombo: return L(
            "Tenez les deux touches ensemble, puis relâchez-en une. Avec une autre touche, elles gardent leur rôle habituel.",
            "Hold both keys together, then release one. With other keys, they work as usual.")
        }
    }
}

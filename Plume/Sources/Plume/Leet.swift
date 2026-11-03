import Foundation

/// Le second geste de dictée : le texte n'est pas rendu propre, il est maquillé
/// en **1337** (leet speak) — `a → 4`, `e → 3`, `i → 1`, `o → 0`, `s → 5`,
/// `t → 7`, plus une casse décorative.
///
/// Transformation **purement mécanique** (comme `VoiceCommands`), locale et
/// instantanée : aucun réseau, aucun modèle. Elle s'applique au texte **final**
/// (après le Vocabulaire, les commandes vocales et le lissage), juste avant le
/// collage.
///
/// Trois règles qui comptent :
///
/// - **le même texte donne toujours le même résultat** : la casse décorative
///   sort d'un générateur pseudo-aléatoire amorcé par une empreinte du texte
///   (pas du hasard d'exécution), sinon on ne pourrait pas se relire ;
/// - **rien n'est touché dans un lien, une adresse e-mail ou un chemin** : un
///   token qui contient `@`, `/`, `\` ou commence par `www.` reste intact —
///   coller un lien cassé serait pire que rater une blague ;
/// - **les accents et tout caractère non listé passent inchangés** (`é è ç à ù`).
enum Leet {
    enum Level: String, CaseIterable, Identifiable {
        case light, medium, full

        var id: String { rawValue }

        var label: String {
            switch self {
            case .light: return L("Léger", "Light")
            case .medium: return L("Moyen", "Medium")
            case .full: return L("Complet", "Full")
            }
        }
    }

    // MARK: Tables

    private static let light: [Character: String] = [
        "a": "4", "e": "3", "i": "1", "o": "0", "s": "5", "t": "7",
    ]

    /// `merging(_:uniquingKeysWith:)` rend (valeur actuelle, nouvelle) : c'est
    /// la **nouvelle** qu'on garde, sinon le niveau complet garderait le `s → 5`
    /// du moyen au lieu de son `s → $`.
    private static let medium: [Character: String] = light.merging([
        "b": "8", "g": "9", "l": "1", "z": "2",
    ]) { _, new in new }

    private static let full: [Character: String] = medium.merging([
        "c": "(", "k": "|<", "s": "$", "x": "><",
    ]) { _, new in new }

    private static func table(_ level: Level) -> [Character: String] {
        switch level {
        case .light: return light
        case .medium: return medium
        case .full: return full
        }
    }

    // MARK: Transformation

    /// Le texte maquillé. Déterministe : `transform(t, level:) == transform(t, level:)`.
    static func transform(_ text: String, level: Level) -> String {
        let map = table(level)
        var rng = RNG(seed: seed(text))
        var out = ""
        out.reserveCapacity(text.count + text.count / 4)

        var i = text.startIndex
        while i < text.endIndex {
            if text[i].isWhitespace {
                out.append(text[i])
                i = text.index(after: i)
                continue
            }
            var j = i
            while j < text.endIndex, !text[j].isWhitespace { j = text.index(after: j) }
            let token = text[i..<j]
            if isProtected(token) {
                out += token
            } else {
                out += disguise(token, map: map, rng: &rng)
            }
            i = j
        }
        return out
    }

    /// Un token qu'on ne touche pas : lien (`https://…`), adresse e-mail
    /// (`pierre@exemple.fr`), chemin de fichier (`/usr/local`, `C:\…`), adresse
    /// de site sans schéma (`www.exemple.fr`).
    private static func isProtected(_ token: Substring) -> Bool {
        token.contains("@") || token.contains("/") || token.contains("\\")
            || token.lowercased().hasPrefix("www.")
    }

    /// Lettre par lettre : substitution, puis casse décorative (une lettre sur
    /// deux, tirée par le générateur — donc stable pour un même texte).
    private static func disguise(_ token: Substring, map: [Character: String], rng: inout RNG) -> String {
        var out = ""
        for ch in token {
            // Accents et tout caractère non ASCII : inchangés.
            guard ch.isASCII else { out.append(ch); continue }
            guard ch.isLetter else { out.append(ch); continue }
            let upper = rng.bit()
            let lower = Character(ch.lowercased())
            if let replacement = map[lower] {
                out += upper ? replacement.uppercased() : replacement
            } else {
                out.append(upper ? Character(ch.uppercased()) : lower)
            }
        }
        return out
    }

    /// Empreinte FNV-1a du texte : la graine de la casse décorative.
    private static func seed(_ text: String) -> UInt64 {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            h = (h ^ UInt64(byte)) &* 0x0000_0100_0000_01b3
        }
        return h == 0 ? 0x9E37_79B9_7F4A_7C15 : h
    }

    /// xorshift64 : petit, rapide, et surtout **reproductible** d'une exécution
    /// à l'autre (contrairement au hasard de la bibliothèque standard).
    private struct RNG {
        var state: UInt64

        init(seed: UInt64) { state = seed }

        mutating func bit() -> Bool {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return state & 1 == 1
        }
    }
}

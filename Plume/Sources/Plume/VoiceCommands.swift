import Foundation

/// Commandes vocales, appliquées sur le Mac avant le nettoyage (instantané,
/// sans réseau) : « à la ligne », « nouveau paragraphe », « ouvrez la
/// parenthèse … fermez la parenthèse », « ouvrez les guillemets »,
/// « point d'interrogation »… et leurs équivalents anglais.
/// Désactivables (Réglages → Dictée) pour qui veut écrire ces mots tels quels.
enum VoiceCommands {
    private struct Rule {
        let pattern: String
        let replacement: String
        /// Ce qui précède la commande (espaces, virgule) est absorbé ; un point
        /// de fin de phrase reste.
        let eatBefore: Bool
        /// Ce qui suit : tout (espaces + ponctuation ajoutée par le moteur), une
        /// virgule seulement (fermetures), ou un point/une virgule (ponctuation).
        let eatAfter: After
    }

    enum After { case all, comma, dot
    }

    private static let a = "[àa]"
    private static let e = "[èe]"
    private static let apos = "['’]"

    private static let rules: [Rule] = [
        // Paragraphe avant ligne : « nouveau paragraphe » contient d'autres mots.
        Rule(pattern: "nouveau paragraphe|saut de ligne|saute[rz]? une ligne|new paragraph|skip a line",
             replacement: "\n\n", eatBefore: true, eatAfter: .all),
        Rule(pattern: "retour \(a) la ligne|\(a) la ligne|nouvelle ligne|new line|newline|next line",
             replacement: "\n", eatBefore: true, eatAfter: .all),
        Rule(pattern: "(?:ouvr(?:ez|e|ir|ons)) (?:la |une )?parenth\(e)se|parenth\(e)se ouvrante|open (?:parenthesis|paren|bracket)",
             replacement: " (", eatBefore: true, eatAfter: .all),
        Rule(pattern: "(?:ferm(?:ez|e|er|ons)) (?:la )?parenth\(e)se|parenth\(e)se fermante|close (?:parenthesis|paren|bracket)",
             replacement: ")", eatBefore: true, eatAfter: .comma),
        Rule(pattern: "(?:ouvr(?:ez|e|ir|ons)) les guillemets", replacement: " « ", eatBefore: true, eatAfter: .all),
        Rule(pattern: "(?:ferm(?:ez|e|er|ons)) les guillemets", replacement: " »", eatBefore: true, eatAfter: .comma),
        Rule(pattern: "open quote|begin quote", replacement: " \"", eatBefore: true, eatAfter: .all),
        Rule(pattern: "close quote|end quote|unquote", replacement: "\"", eatBefore: true, eatAfter: .comma),
        Rule(pattern: "point d\(apos)interrogation", replacement: " ?", eatBefore: true, eatAfter: .dot),
        Rule(pattern: "point d\(apos)exclamation", replacement: " !", eatBefore: true, eatAfter: .dot),
        Rule(pattern: "deux[- ]points", replacement: " :", eatBefore: true, eatAfter: .dot),
        Rule(pattern: "point[- ]virgule", replacement: " ;", eatBefore: true, eatAfter: .dot),
        Rule(pattern: "question mark", replacement: "?", eatBefore: true, eatAfter: .dot),
        Rule(pattern: "exclamation (?:mark|point)", replacement: "!", eatBefore: true, eatAfter: .dot),
        Rule(pattern: "semicolon", replacement: ";", eatBefore: true, eatAfter: .dot),
    ]

    private static let compiled: [(NSRegularExpression, String)] = rules.compactMap { r in
        let before = r.eatBefore ? "[ \\t,]*" : ""
        // La ponctuation ajoutée par le moteur juste après la commande (« À la ligne. ») part avec elle.
        let after: String
        switch r.eatAfter {
        case .all: after = "[ \\t.,;:!?]*"
        case .comma: after = ",?"
        case .dot: after = "[.,]?"
        }
        let pattern = before + "(?<![\\p{L}\\p{N}])(?:" + r.pattern + ")(?![\\p{L}\\p{N}])" + after
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        return (re, NSRegularExpression.escapedTemplate(for: r.replacement))
    }

    static var enabled: Bool { UserDefaults.standard.object(forKey: "voiceCommands") as? Bool ?? true }

    static func apply(to text: String) -> String {
        var t = text
        for (re, template) in compiled {
            t = re.stringByReplacingMatches(in: t, range: NSRange(t.startIndex..., in: t), withTemplate: template)
        }
        guard t != text else { return text }
        // Mise au propre des espaces autour de ce qui a été inséré.
        for (pattern, template) in [("([?!;:])[ \\t]*\\1+", "$1"), ("[ \\t]+\\n", "\n"), ("\\n[ \\t]+", "\n"), (" {2,}", " "), ("\\( ", "("), (" \\)", ")"),
                                    ("^[ \\t]+", ""), ("[ \\t]+$", ""), ("([?!;:])(?=\\p{L})", "$1 "),
                                    ("\\)(?=\\p{L})", ") ")] {
            t = t.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        // Majuscule au début d'une nouvelle ligne.
        var out = ""
        var capitalizeNext = false
        for ch in t {
            if capitalizeNext, ch.isLetter {
                out += ch.uppercased()
                capitalizeNext = false
            } else {
                out.append(ch)
                if ch == "\n" { capitalizeNext = true } else if !ch.isWhitespace { capitalizeNext = false }
            }
        }
        return out
    }
}

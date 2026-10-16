import Foundation

/// Un mot que le moteur doit bien écrire, et les façons dont il l'a déjà mal
/// entendu.
struct VocabEntry: Codable, Identifiable, Equatable {
    var id = UUID()
    var word: String
    var variants: [String] = []
    var addedAt = Date()
}

/// La mémoire des noms propres.
///
/// Trois couches, de la plus forte à la plus sûre :
/// 1. **la liste est donnée à Whisper** (`prompt` de la requête) : il écrit
///    directement le bon mot (Parakeet, lui, n'a pas de prompt) ;
/// 2. **les graphies déjà vues sont remplacées** mot à mot, sans dépendre du
///    réseau ;
/// 3. **le nettoyage reçoit l'orthographe exacte** des noms.
///
/// Fichier : `~/Library/Application Support/Plume/vocabulaire.json`.
@MainActor
final class VocabularyStore: ObservableObject {
    static let shared = VocabularyStore()

    @Published private(set) var items: [VocabEntry] = []
    private let file = HistoryStore.folder.appendingPathComponent("vocabulaire.json")

    /// Liste de départ : celle de `local.json` s'il y en a une, sinon vide.
    /// Semée une seule fois, ensuite la liste appartient à l'utilisateur.
    static var seed: [VocabEntry] {
        (LocalConfig.current?.vocabularySeed ?? []).map { VocabEntry(word: $0.word, variants: $0.variants ?? []) }
    }

    private init() {
        if let data = try? Data(contentsOf: file),
           let decoded = try? JSONDecoder.iso.decode([VocabEntry].self, from: data) {
            items = decoded
        } else {
            if FileManager.default.fileExists(atPath: file.path) {
                // Fichier abîmé : mis de côté plutôt qu'écrasé.
                try? FileManager.default.moveItem(at: file, to: file.deletingPathExtension()
                    .appendingPathExtension("illisible-\(Int(Date().timeIntervalSince1970)).json"))
            }
            items = Self.seed
            save()
        }
    }

    private func save() {
        guard let data = try? JSONEncoder.pretty.encode(items) else { return }
        try? data.write(to: file, options: .atomic)
    }

    // MARK: Édition

    /// Ajoute un mot, ou une graphie mal entendue à un mot existant.
    func add(word rawWord: String, variant rawVariant: String? = nil) {
        let word = rawWord.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !word.isEmpty else { return }
        let variant = rawVariant?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if let i = items.firstIndex(where: { $0.word.caseInsensitiveCompare(word) == .orderedSame }) {
            items[i].word = word
            if !variant.isEmpty, variant.caseInsensitiveCompare(word) != .orderedSame,
               !items[i].variants.contains(where: { $0.caseInsensitiveCompare(variant) == .orderedSame }) {
                items[i].variants.append(variant)
            }
        } else {
            let variants = (variant.isEmpty || variant.caseInsensitiveCompare(word) == .orderedSame) ? [] : [variant]
            items.insert(VocabEntry(word: word, variants: variants), at: 0)
        }
        save()
    }

    /// Enregistre un mot modifié dans la fiche (ou un nouveau mot).
    func save(_ entry: VocabEntry) {
        var e = entry
        e.word = e.word.trimmingCharacters(in: .whitespacesAndNewlines)
        var seen = Set<String>()
        e.variants = e.variants
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.caseInsensitiveCompare(e.word) != .orderedSame && seen.insert($0.lowercased()).inserted }
        guard !e.word.isEmpty else { return }
        if let i = items.firstIndex(where: { $0.id == e.id }) {
            items[i] = e
        } else if let i = items.firstIndex(where: { $0.word.caseInsensitiveCompare(e.word) == .orderedSame }) {
            // Le mot existe déjà : on fusionne les formes.
            for v in e.variants where !items[i].variants.contains(where: { $0.caseInsensitiveCompare(v) == .orderedSame }) {
                items[i].variants.append(v)
            }
        } else {
            items.insert(e, at: 0)
        }
        save()
    }

    func removeVariant(_ variant: String, from id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].variants.removeAll { $0 == variant }
        save()
    }

    func remove(_ id: UUID) {
        items.removeAll { $0.id == id }
        save()
    }

    // MARK: Utilisation pendant la dictée

    /// Instantané passé au traitement (qui tourne hors du fil principal).
    var snapshot: Vocabulary { Vocabulary(entries: items) }
}

/// Copie immuable du vocabulaire pour une dictée.
struct Vocabulary: Sendable {
    let entries: [VocabEntry]

    var isEmpty: Bool { entries.isEmpty }

    /// Le « prompt » de Whisper : les mots, comme une phrase déjà entendue.
    /// Limité (Whisper ne lit que ~220 jetons de prompt, et une très longue
    /// liste pourrait l'inciter à recaser des mots qui n'ont pas été dits).
    var whisperPrompt: String? {
        guard !entries.isEmpty else { return nil }
        var out = ""
        for e in entries {
            let next = out.isEmpty ? e.word : out + ", " + e.word
            if next.count > 500 { break }
            out = next
        }
        return out + "."
    }

    /// Pour la consigne du lissage.
    var spellingList: String { entries.map(\.word).joined(separator: ", ") }

    /// Remplace les graphies mal entendues connues, et remet la bonne casse
    /// (« plume » → « Plume »). Mots entiers seulement, insensible à la
    /// casse ; une espace dans une graphie accepte aussi un tiret.
    func apply(to text: String) -> String {
        var t = text
        for e in entries {
            for form in e.variants + [e.word] where !form.trimmingCharacters(in: .whitespaces).isEmpty {
                let pattern = "(?<![\\p{L}\\p{N}])"
                    + NSRegularExpression.escapedPattern(for: form)
                        .replacingOccurrences(of: "\\ ", with: "[\\s-]+")
                        .replacingOccurrences(of: " ", with: "[\\s-]+")
                    + "(?![\\p{L}\\p{N}])"
                guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
                t = re.stringByReplacingMatches(in: t, range: NSRange(t.startIndex..., in: t),
                                                withTemplate: NSRegularExpression.escapedTemplate(for: e.word))
            }
        }
        return t
    }
}

extension JSONDecoder {
    static let iso: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()
}
extension JSONEncoder {
    static let pretty: JSONEncoder = {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.prettyPrinted]; return e
    }()
}

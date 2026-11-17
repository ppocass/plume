import Foundation

/// Qui parle : le micro (« Moi ») ou le son du Mac (« Eux »). Les deux pistes
/// ne sont jamais mélangées : l'attribution est gratuite.
enum MeetingSpeaker: String, Codable, Sendable {
    case me, them
    var label: String { self == .me ? L("Moi", "Me") : L("Eux", "Them") }
}

/// Un paragraphe de réunion : une prise de parole d'une piste, coupée sur une
/// pause. Le brut est **toujours** gardé ; `text` est la version lissée quand
/// le nettoyage a pu se faire (sinon `text == raw` et `polished == false`).
struct MeetingParagraph: Codable, Identifiable, Equatable, Sendable {
    let id: Int
    let speaker: MeetingSpeaker
    /// Secondes depuis le début de la réunion (horloge commune aux deux pistes).
    let start: Double
    var end: Double
    var raw: String
    var text: String
    var polished: Bool
    /// Encore en train de s'écrire (le paragraphe n'est pas fermé).
    var open: Bool = false

    var words: Int { text.split(whereSeparator: { $0.isWhitespace }).count }
}

/// Ce qu'on sait d'une réunion sans lire son texte (fichier `.plume-meta.json`).
struct MeetingMeta: Codable, Equatable, Sendable {
    var startedAt: Date
    var endedAt: Date?
    var duration: Double
    /// « Zoom », « Teams », « Son du Mac »…
    var source: String
    /// Le modèle de transcription (`parakeet-ultra`…).
    var model: String
    var words: Int
    var paragraphs: Int
    /// Vrai tant que la réunion s'enregistre (ou si l'app s'est arrêtée net).
    var recording: Bool
}

/// Une réunion sur le disque : un dossier
/// `Reunions/2026-10-22 15h04 — Zoom/` qui contient
/// - `réunion.md` : le texte lisible, écrit au fil de l'eau ;
/// - `moi.wav`, `eux.wav` : les deux pistes (16 kHz mono 16 bits), supprimables ;
/// - `.plume-meta.json` : l'en-tête pour la liste ;
/// - `.plume-paragraphes.jsonl` : chaque paragraphe en JSON, une ligne par
///   version (la dernière ligne d'un `id` l'emporte : c'est ainsi qu'un
///   paragraphe lissé remplace son brut **sans réécrire le fichier**).
struct MeetingFolder: Identifiable, Hashable, Sendable {
    let url: URL
    var id: String { url.path }
    var name: String { url.lastPathComponent }

    var markdownURL: URL { url.appendingPathComponent("réunion.md") }
    var micURL: URL { url.appendingPathComponent("moi.wav") }
    var systemURL: URL { url.appendingPathComponent("eux.wav") }
    var metaURL: URL { url.appendingPathComponent(".plume-meta.json") }
    var paragraphsURL: URL { url.appendingPathComponent(".plume-paragraphes.jsonl") }

    /// Le dossier de toutes les réunions (`PLUME_DATA_DIR` le déplace pour les tests).
    static var root: URL { Setup.dataFolder.appendingPathComponent("Reunions", isDirectory: true) }

    /// Nom du dossier : « 2026-10-22 15h04 — Zoom ». Les caractères interdits
    /// dans un nom de fichier sont retirés de la source.
    static func folderName(date: Date, source: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH'h'mm"
        let clean = source.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespaces)
        return clean.isEmpty ? f.string(from: date) : "\(f.string(from: date)) — \(clean)"
    }

    /// Crée un dossier neuf (suffixe « (2) », « (3) »… si le nom existe déjà).
    static func create(date: Date, source: String) throws -> MeetingFolder {
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let base = folderName(date: date, source: source)
        var url = root.appendingPathComponent(base, isDirectory: true)
        var n = 2
        while fm.fileExists(atPath: url.path) {
            url = root.appendingPathComponent("\(base) (\(n))", isDirectory: true)
            n += 1
        }
        try fm.createDirectory(at: url, withIntermediateDirectories: false)
        return MeetingFolder(url: url)
    }

    // MARK: Lecture

    func readMeta() -> MeetingMeta? {
        guard let data = try? Data(contentsOf: metaURL) else { return nil }
        return try? MeetingFiles.decoder.decode(MeetingMeta.self, from: data)
    }

    /// Les paragraphes, la dernière version de chacun, dans l'ordre du temps.
    func readParagraphs() -> [MeetingParagraph] {
        guard let data = try? Data(contentsOf: paragraphsURL) else { return [] }
        var latest: [Int: MeetingParagraph] = [:]
        for line in data.split(separator: UInt8(ascii: "\n")) where !line.isEmpty {
            if let p = try? MeetingFiles.decoder.decode(MeetingParagraph.self, from: Data(line)) {
                latest[p.id] = p
            }
        }
        return latest.values.sorted { $0.start == $1.start ? $0.id < $1.id : $0.start < $1.start }
    }

    var hasAudio: Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: micURL.path) || fm.fileExists(atPath: systemURL.path)
    }

    /// Taille des deux pistes, en octets.
    var audioBytes: Int64 {
        [micURL, systemURL].reduce(0) { sum, url in
            sum + ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0)
        }
    }
}

enum MeetingFiles {
    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }()
    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    /// `[00:04:12]`
    static func timestamp(_ seconds: Double) -> String {
        let s = max(0, Int(seconds))
        return String(format: "%02d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
    }

    /// Durée lisible : « 42 min », « 1 h 05 », « 12 s ».
    static func duration(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded()))
        if s < 60 { return "\(s) s" }
        if s < 3600 { return "\(s / 60) min" }
        return String(format: "%d h %02d", s / 3600, (s / 60) % 60)
    }

    /// Le texte complet d'une réunion en Markdown (copier, exporter, fichier final).
    static func markdown(meta: MeetingMeta, paragraphs: [MeetingParagraph]) -> String {
        let date = DateFormatter.localizedString(from: meta.startedAt, dateStyle: .long, timeStyle: .short)
        let words = paragraphs.reduce(0) { $0 + $1.words }
        var out = "# " + L("Réunion du ", "Meeting on ") + date + "\n\n"
        // Deux-points à la française (espace avant) ou à l'anglaise.
        let colon = L(" : ", ": ")
        out += "- " + L("Durée", "Duration") + colon + duration(meta.duration) + "\n"
        out += "- Source" + colon + meta.source + "\n"
        out += "- " + L("Modèle", "Model") + colon + meta.model + "\n"
        out += "- " + L("Mots", "Words") + colon + "\(words)\n\n"
        for p in paragraphs where !p.text.isEmpty {
            out += paragraphLine(p) + "\n\n"
        }
        return out
    }

    /// `[00:04:12] **Moi** : …` (+ « *(non nettoyé)* » si le lissage n'a pas pu passer).
    static func paragraphLine(_ p: MeetingParagraph) -> String {
        var line = "[\(timestamp(p.start))] **\(p.speaker.label)**" + L(" : ", ": ") + p.text
        if !p.polished && Prefs.polishWanted { line += " *" + L("(non nettoyé)", "(not cleaned up)") + "*" }
        return line
    }
}

extension Prefs {
    /// Le lissage est-il demandé ? Lu hors du fil principal (pas de « non
    /// nettoyé » affiché à quelqu'un qui n'a pas activé le nettoyage).
    nonisolated static var polishWanted: Bool {
        UserDefaults.standard.object(forKey: "polishEnabled") as? Bool ?? true
    }
}

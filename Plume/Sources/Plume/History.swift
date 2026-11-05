import Foundation

/// Une dictée terminée.
struct Dictation: Codable, Identifiable, Equatable {
    var id = UUID()
    var date: Date
    /// Le texte final (nettoyé si le nettoyage a marché).
    var text: String
    /// Ce que le moteur a entendu, avant nettoyage.
    var raw: String
    var polished: Bool
    /// `true` : collé dans une app ; `false` : pas de champ de texte au bon
    /// moment, gardé ici.
    var pasted: Bool
    var appName: String?
    var audioSeconds: Double
    /// La transcription a échoué : l'audio est gardé pour « Réessayer ».
    var failed: Bool = false
    var audioFile: String?
    /// Dictée 1337 : `text` est le texte maquillé, `raw` garde l'original.
    var leet: Bool = false

    var wordCount: Int { text.split(whereSeparator: { $0.isWhitespace }).count }

    /// Décodage à la main pour une seule raison : `leet` est arrivé après coup,
    /// et les 200 dictées déjà écrites (sans cette clé) doivent se relire
    /// telles quelles, pas partir à la Corbeille comme un fichier abîmé.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        date = try c.decode(Date.self, forKey: .date)
        text = try c.decode(String.self, forKey: .text)
        raw = try c.decode(String.self, forKey: .raw)
        polished = try c.decode(Bool.self, forKey: .polished)
        pasted = try c.decode(Bool.self, forKey: .pasted)
        appName = try c.decodeIfPresent(String.self, forKey: .appName)
        audioSeconds = try c.decode(Double.self, forKey: .audioSeconds)
        failed = try c.decodeIfPresent(Bool.self, forKey: .failed) ?? false
        audioFile = try c.decodeIfPresent(String.self, forKey: .audioFile)
        leet = try c.decodeIfPresent(Bool.self, forKey: .leet) ?? false
    }

    init(id: UUID = UUID(), date: Date, text: String, raw: String, polished: Bool, pasted: Bool,
         appName: String?, audioSeconds: Double, failed: Bool = false, audioFile: String? = nil,
         leet: Bool = false) {
        self.id = id
        self.date = date
        self.text = text
        self.raw = raw
        self.polished = polished
        self.pasted = pasted
        self.appName = appName
        self.audioSeconds = audioSeconds
        self.failed = failed
        self.audioFile = audioFile
        self.leet = leet
    }
}

/// L'historique, dans `~/Library/Application Support/Plume/historique.json`.
/// **200 dictées au plus** : à la 201ᵉ, la plus ancienne part, avec son
/// éventuel audio d'échec. Le total de l'Accueil vient d'un compteur à part
/// (`totals.json`), qui ne baisse jamais.
@MainActor
final class HistoryStore: ObservableObject {
    static let shared = HistoryStore()
    static let limit = 200

    struct Totals: Codable, Equatable {
        var dictations = 0
        var words = 0
    }

    @Published private(set) var items: [Dictation] = []
    @Published private(set) var totals = Totals()

    nonisolated static var folder: URL { Setup.dataFolder }
    static var failedAudioFolder: URL { shared.audioFolder }

    /// Audio des dictées ratées, pour « Réessayer ».
    let audioFolder: URL
    private let file: URL
    private let totalsFile: URL

    /// `folder` : un autre dossier pour les tests.
    init(folder: URL = HistoryStore.folder) {
        audioFolder = folder.appendingPathComponent("audio-a-reessayer", isDirectory: true)
        try? FileManager.default.createDirectory(at: audioFolder, withIntermediateDirectories: true)
        file = folder.appendingPathComponent("historique.json")
        totalsFile = folder.appendingPathComponent("totals.json")
        load()
    }

    private func load() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: file) {
            do {
                items = try decoder.decode([Dictation].self, from: data)
            } catch {
                // Fichier abîmé : mis de côté plutôt qu'écrasé à la prochaine dictée.
                let aside = file.deletingPathExtension().appendingPathExtension("illisible-\(Int(Date().timeIntervalSince1970)).json")
                try? FileManager.default.moveItem(at: file, to: aside)
                Log.info("historique illisible, mis de côté : \(aside.lastPathComponent)")
                items = []
            }
        }
        if let data = try? Data(contentsOf: totalsFile), let t = try? JSONDecoder().decode(Totals.self, from: data) {
            totals = t
        } else {
            // Première fois : le compteur part de ce que l'historique contient déjà.
            let kept = items.filter { !$0.failed }
            totals = Totals(dictations: kept.count, words: kept.reduce(0) { $0 + $1.wordCount })
            saveTotals()
        }
        let before = items.count
        trimToLimit()
        removeOrphanAudio()
        if items.count != before { save() }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted]
        guard let data = try? encoder.encode(items) else { return }
        try? data.write(to: file, options: .atomic)
    }

    private func saveTotals() {
        guard let data = try? JSONEncoder().encode(totals) else { return }
        try? data.write(to: totalsFile, options: .atomic)
    }

    /// Garde les 200 plus récentes ; l'audio des dictées retirées part à la Corbeille.
    private func trimToLimit() {
        guard items.count > Self.limit else { return }
        items.sort { $0.date > $1.date }
        for old in items[Self.limit...] { trashAudio(of: old) }
        items.removeSubrange(Self.limit...)
    }

    /// Un audio d'échec qu'aucune dictée ne référence plus.
    private func removeOrphanAudio() {
        let fm = FileManager.default
        let used = Set(items.compactMap(\.audioFile))
        for name in (try? fm.contentsOfDirectory(atPath: audioFolder.path)) ?? []
        where name.hasSuffix(".wav") && !used.contains(name) {
            try? fm.trashItem(at: audioFolder.appendingPathComponent(name), resultingItemURL: nil)
        }
    }

    private func trashAudio(of d: Dictation) {
        guard let name = d.audioFile else { return }
        try? FileManager.default.trashItem(at: audioFolder.appendingPathComponent(name), resultingItemURL: nil)
    }

    func add(_ d: Dictation) {
        items.insert(d, at: 0)
        if !d.failed { count(d) }
        trimToLimit()
        save()
    }

    private func count(_ d: Dictation) {
        totals.dictations += 1
        totals.words += d.wordCount
        saveTotals()
    }

    /// Bascule une dictée entre texte normal et 1337 — le rattrapage demandé
    /// par Pierre le 05/11 (on s'aperçoit trop tard qu'on voulait du leet).
    ///
    /// **Réversible**, et sans jamais perdre le texte d'origine :
    /// - aller en 1337 → on maquille **`raw`** (le texte vraiment dit), pas
    ///   `text` (qui pourrait déjà être maquillé) ;
    /// - revenir → on remet `raw` tel quel.
    ///
    /// ⚠️ Le texte **lissé** n'est donc pas restauré au retour : on revient au
    /// brut. C'est un choix assumé — garder les deux versions demanderait un
    /// champ de plus dans l'historique, et le brut est justement ce que Pierre
    /// veut retrouver quand il regrette le 1337.
    func toggleLeet(_ item: Dictation) {
        var d = item
        guard !d.raw.isEmpty else { return }
        if d.leet {
            d.text = d.raw
            d.leet = false
        } else {
            d.text = Leet.transform(d.raw, level: Prefs.shared.leetLevel)
            d.leet = true
        }
        replace(d)
        Log.info("historique : dictée basculée en \(d.leet ? "1337" : "texte normal")")
    }

    func replace(_ d: Dictation) {
        guard let i = items.firstIndex(where: { $0.id == d.id }) else { return }
        // Une dictée ratée qui réussit au 2ᵉ essai compte à ce moment-là.
        if items[i].failed && !d.failed { count(d) }
        items[i] = d
        save()
    }

    /// Retire une dictée de l'historique. Son éventuel audio d'échec part à la
    /// Corbeille de macOS (récupérable), jamais effacé pour de bon.
    func remove(_ id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        trashAudio(of: items[i])
        items.remove(at: i)
        save()
    }

    func removeAll() {
        for item in items { trashAudio(of: item) }
        items.removeAll()
        save()
    }

    /// La dernière dictée réussie (barre des menus : « Copier la dernière dictée »).
    var latest: Dictation? { items.first { !$0.failed && !$0.text.isEmpty } }

    // MARK: Chiffres pour l'Accueil

    func words(since date: Date) -> Int {
        items.filter { $0.date >= date && !$0.failed }.reduce(0) { $0 + $1.wordCount }
    }

    func count(since date: Date) -> Int {
        items.filter { $0.date >= date && !$0.failed }.count
    }
}

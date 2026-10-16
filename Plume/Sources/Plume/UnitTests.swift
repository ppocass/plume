import CoreGraphics
import Foundation

/// Vérifications de la logique, sans micro ni réseau : `Plume --unit-tests`.
/// Écrit seulement dans un dossier temporaire (sauf les audios d'essai
/// retirés de l'historique, qui partent à la Corbeille comme dans l'app).
@MainActor
enum UnitTests {
    private static var failures = 0
    private static var passed = 0

    private static func check(_ ok: Bool, _ what: String) {
        if ok { passed += 1 } else { failures += 1; print("❌ \(what)") }
    }

    static func run() -> Int32 {
        history()
        corruptHistory()
        vocabulary()
        endpoints()
        catalog()
        recommendations()
        shortcuts()
        filter()
        updates()
        print("\(passed) vérifications réussies, \(failures) échec(s)")
        return Int32(failures)
    }

    private static func tempFolder() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("plume-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Un faux historique de 250 dictées : il doit être ramené à 200, sans
    /// que le total cumulé ne baisse.
    static func history() {
        let dir = tempFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let audio = dir.appendingPathComponent("audio-a-reessayer", isDirectory: true)
        try? FileManager.default.createDirectory(at: audio, withIntermediateDirectories: true)
        let now = Date()
        var items: [Dictation] = []
        for i in 0..<250 {
            var d = Dictation(date: now.addingTimeInterval(Double(-i) * 60), text: "un deux trois", raw: "un deux trois",
                              polished: false, pasted: true, appName: nil, audioSeconds: 2)
            if i == 249 {   // la plus ancienne : un échec avec son audio
                d.failed = true
                d.text = ""
                d.audioFile = "ancienne.wav"
            }
            items.append(d)
        }
        for name in ["ancienne.wav", "orpheline.wav"] {
            try? Data([0]).write(to: audio.appendingPathComponent(name))
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try? encoder.encode(items).write(to: dir.appendingPathComponent("historique.json"))

        let store = HistoryStore(folder: dir)
        check(store.items.count == 200, "historique ramené à 200 (\(store.items.count))")
        // Les dates sont écrites à la seconde près (ISO 8601).
        check(abs((store.items.first?.date ?? .distantPast).timeIntervalSince(items[0].date)) < 1
              && abs((store.items.last?.date ?? .distantPast).timeIntervalSince(items[199].date)) < 1, "les plus récentes sont gardées")
        check(store.totals.dictations == 249, "total repris de l'ancien historique (\(store.totals.dictations))")
        check(store.totals.words == 249 * 3, "mots repris (\(store.totals.words))")
        check(!FileManager.default.fileExists(atPath: audio.appendingPathComponent("ancienne.wav").path), "audio de la dictée retirée parti")
        check(!FileManager.default.fileExists(atPath: audio.appendingPathComponent("orpheline.wav").path), "audio orphelin parti")

        store.add(Dictation(date: Date(), text: "quatre cinq", raw: "quatre cinq", polished: false, pasted: true,
                            appName: nil, audioSeconds: 1))
        check(store.items.count == 200, "toujours 200 après une nouvelle dictée")
        check(store.totals.dictations == 250 && store.totals.words == 249 * 3 + 2, "le total continue de monter")

        let reopened = HistoryStore(folder: dir)
        check(reopened.items.count == 200 && reopened.totals.dictations == 250, "relu tel quel après relance")
    }

    /// Un historique illisible est mis de côté, pas écrasé.
    static func corruptHistory() {
        let dir = tempFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        try? Data("{pas du json".utf8).write(to: dir.appendingPathComponent("historique.json"))
        let store = HistoryStore(folder: dir)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        check(store.items.isEmpty, "historique illisible → liste vide")
        check(names.contains { $0.hasPrefix("historique.illisible-") }, "fichier illisible mis de côté")
    }

    static func vocabulary() {
        let v = Vocabulary(entries: [VocabEntry(word: "Plume", variants: ["", "plum", "  "]),
                                     VocabEntry(word: "Claude Code", variants: ["cloud code"])])
        check(v.apply(to: "le mot plum ici") == "le mot Plume ici", "graphie remplacée")
        check(v.apply(to: "rien à changer") == "rien à changer", "une forme vide ne remplace rien")
        check(v.apply(to: "ouvre cloud-code") == "ouvre Claude Code", "tiret accepté pour une espace")
        check(v.apply(to: "plumeau") == "plumeau", "mots entiers seulement")
    }

    static func endpoints() {
        let allowed = ["https://api.groq.com/openai/v1/chat/completions", "http://localhost:8080/v1", "http://127.0.0.1:1234",
                       "http://192.168.0.20:3001/v1", "http://10.0.0.2", "http://172.20.1.1", "http://100.100.0.1:3001",
                       "http://mon-serveur.local:3001"]
        let refused = ["http://example.com/v1", "http://8.8.8.8/v1", "ftp://192.168.1.2", "http://172.32.0.1", "http://100.128.0.1",
                       "file:///etc/passwd", "https://"]
        for u in allowed { check(URL(string: u).map(EndpointPolicy.isAllowed) == true, "autorisé : \(u)") }
        for u in refused { check(URL(string: u).map(EndpointPolicy.isAllowed) != true, "refusé : \(u)") }
    }

    static func catalog() {
        let ids = ModelCatalog.all.map(\.id)
        check(Set(ids).count == ids.count, "identifiants uniques")
        let ports = ModelCatalog.local.map(\.port)
        check(Set(ports).count == ports.count, "un port par modèle local")
        check(ModelCatalog.model(ModelCatalog.defaultID) != nil, "modèle par défaut présent")
        for m in ModelCatalog.local {
            check(!m.files.isEmpty && m.revision.count == 40, "\(m.id) : fichiers et révision figée")
            for f in m.files {
                check(f.sha256.count == 64 && f.sha256.allSatisfy(\.isHexDigit) && f.size > 0, "\(m.id) : empreinte de \(f.path)")
            }
            check(m.url(for: m.files[0]).scheme == "https" && m.url(for: m.files[0]).host == "huggingface.co", "\(m.id) : https vers Hugging Face")
        }
        check(ModelCatalog.model("parakeet-ultra")!.folder == "parakeet-ultra", "dossier Parakeet = celui de FluidAudio")
    }

    static func recommendations() {
        check(ModelCatalog.recommended(.parakeet, memoryGB: 8, availableGB: 3, pro: false, macOS: 26) == "parakeet-ultra", "8 Go → Ultra")
        check(ModelCatalog.recommended(.whisper, memoryGB: 8, availableGB: 3, pro: false, macOS: 26) == "whisper-turbo-q5", "Whisper 8 Go → compact")
        check(ModelCatalog.recommended(.whisper, memoryGB: 16, availableGB: 5, pro: false, macOS: 26) == "whisper-turbo", "Whisper 16 Go → Turbo")
        check(ModelCatalog.recommended(.whisper, memoryGB: 16, availableGB: 8, pro: true, macOS: 26) == "whisper-large-v3", "Whisper 16 Go Pro → Large v3")
        check(ModelCatalog.recommended(.whisper, memoryGB: 32, availableGB: 2, pro: true, macOS: 26) == "whisper-turbo-q5", "peu de mémoire libre → compact")
        check(ModelCatalog.recommendedDefault(language: "fr", memoryGB: 32, availableGB: 20, pro: true, macOS: 26, whisperAvailable: true)
              == "parakeet-ultra", "français → Parakeet")
        check(ModelCatalog.recommendedDefault(language: "ja", memoryGB: 32, availableGB: 20, pro: true, macOS: 26, whisperAvailable: true)
              == "whisper-large-v3", "japonais → Whisper")
        check(ModelCatalog.recommendedDefault(language: "ja", memoryGB: 8, availableGB: 3, pro: false, macOS: 26, whisperAvailable: false)
              == "parakeet-ultra", "sans Whisper → Parakeet")
    }

    static func shortcuts() {
        let left = Shortcut.modifierKey(58)!
        check(left.isDown(CGEventFlags(rawValue: 0x80000 | 0x20)), "⌥ gauche enfoncée")
        check(!left.isDown(CGEventFlags(rawValue: 0x80000 | 0x40)), "⌥ droite ≠ ⌥ gauche")
        let combo = Shortcut(kind: .combo, keyCode: 13, modifiers: CGEventFlags([.maskControl, .maskShift]).rawValue, display: "⌃⇧W")
        check(combo.matches(keyCode: 13, flags: [.maskControl, .maskShift]), "⌃⇧W reconnu")
        check(!combo.matches(keyCode: 13, flags: [.maskControl, .maskShift, .maskCommand]), "⌃⇧⌘W refusé")
    }

    static func updates() {
        check(Updater.isNewer("1.10", than: "1.9"), "1.10 > 1.9")
        check(Updater.isNewer("1.3", than: "1.2.2"), "1.3 > 1.2.2")
        check(!Updater.isNewer("1.2", than: "1.2.0"), "1.2 = 1.2.0")
        check(!Updater.isNewer("1.2.2", than: "1.3"), "1.2.2 < 1.3")
        let json = #"{"tag_name":"v1.3","body":"Fix.\n\nSHA-256 of Plume.dmg: `f28fd2cb01e87aa4a83c9d4c625e4f964abebe55acd4a99612e3bd251d8619de`\n","assets":[{"name":"Plume-1.3.dmg","browser_download_url":"https://github.com/a/b/x.dmg"},{"name":"Plume.dmg","browser_download_url":"https://github.com/ppocass/plume/releases/download/v1.3/Plume.dmg"}]}"#
        let r = try? Updater.parse(Data(json.utf8))
        check(r?.version == "1.3" && r?.dmg.lastPathComponent == "Plume.dmg", "release lue (version, fichier)")
        check(r?.sha256 == "f28fd2cb01e87aa4a83c9d4c625e4f964abebe55acd4a99612e3bd251d8619de", "empreinte lue dans les notes")
        check(ReleaseNotes.pages(from: "1.2.2", to: "1.3").count == 4, "nouveautés 1.2.2 → 1.3")
        check(ReleaseNotes.pages(from: "1.3", to: "1.3.1").isEmpty, "pas de nouveautés pour une petite version")
        let fr = Polisher.promptEN(for: .en)
        check(fr.contains("Reply with the cleaned text only") && fr.contains("in English"), "consigne anglaise")
    }

    static func filter() {
        check(TranscriptFilter.clean("Sous-titrage Société Radio-Canada", audioSeconds: 3).isEmpty, "générique retiré")
        check(TranscriptFilter.clean("Bonjour\nBonjour\nça va", audioSeconds: 3) == "Bonjour ça va", "segment répété retiré")
    }
}

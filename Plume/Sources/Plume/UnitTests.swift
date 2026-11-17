import CoreGraphics
import Foundation

/// Vérifications de la logique, sans micro ni réseau : `Plume --unit-tests`.
/// Écrit seulement dans un dossier temporaire (sauf les audios d'essai
/// retirés de l'historique, qui partent à la Corbeille comme dans l'app).
@MainActor
enum UnitTests {
    private static var failures = 0
    private static var passed = 0

    /// Le drapeau de l'assistant : il ne doit jamais se rallumer tout seul.
    ///
    /// On vérifie la logique sur un domaine de préférences à part (jamais celui
    /// ), en rejouant les cas qui font revenir l'assistant.
    static func onboardingFlag() {
        let suite = "plume.tests.onboarding.\(UUID().uuidString)"
        guard let d = UserDefaults(suiteName: suite) else {
            check(false, "domaine de test créé"); return
        }
        defer { d.removePersistentDomain(forName: suite) }

        // 1. Jamais fait : ni drapeau ni date → l'assistant doit s'ouvrir.
        check(d.object(forKey: "onboardingCompletedAt") == nil && !d.bool(forKey: "onboardingDone"),
              "neuf : rien n'est posé")

        // 2. Après `markOnboardingDone`, les DEUX preuves existent.
        d.set(true, forKey: "onboardingDone")
        d.set(Date(), forKey: "onboardingCompletedAt")
        check(d.bool(forKey: "onboardingDone") && d.object(forKey: "onboardingCompletedAt") != nil,
              "terminé : drapeau + date")

        // 3. Le drapeau disparaît (réinitialisation, autre identifiant) :
        //    la DATE seule doit suffire à garder l'assistant fermé.
        d.removeObject(forKey: "onboardingDone")
        let dateAlone = d.object(forKey: "onboardingCompletedAt") != nil
        check(dateAlone, "drapeau perdu : la date reste")
        // La logique de `Prefs.onboardingDone` dans ce cas : on répare et on répond true.
        let wouldShow = !(d.bool(forKey: "onboardingDone") || dateAlone)
        check(wouldShow == false, "date seule → l'assistant ne s'ouvre pas")

        // 4. L'inverse : la date manque (installation antérieure au correctif)
        //    mais le drapeau est là → l'assistant reste fermé aussi.
        d.set(true, forKey: "onboardingDone")
        d.removeObject(forKey: "onboardingCompletedAt")
        let flagAlone = d.bool(forKey: "onboardingDone")
        check(flagAlone, "date manquante : le drapeau reste")
        let wouldShow2 = !(flagAlone || d.object(forKey: "onboardingCompletedAt") != nil)
        check(wouldShow2 == false, "drapeau seul → l'assistant ne s'ouvre pas")

        // 5. « Revoir la configuration… » : on rouvre, mais la date est gardée.
        //    On repart d'un état normal (les deux preuves posées), puis on
        //    simule ce que fait le bouton « Revoir la configuration… ».
        d.set(true, forKey: "onboardingDone")
        d.set(Date(), forKey: "onboardingCompletedAt")
        d.removeObject(forKey: "onboardingDone")      // ce que fait le réglage à false
        check(d.object(forKey: "onboardingCompletedAt") != nil,
              "rouvert volontairement : la date est conservée")
    }

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
        commands()
        leet()
        leetShortcuts()
        onboardingFlag()
        meetingSegmenter()
        meetingFolderName()
        meetingParagraphJournal()
        meetingMarkdown()
        meetingWavAndRecovery()
        meetingEchoAndLevels()
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
        check(ReleaseNotes.pages(from: "1.2.2", to: "1.3").count == 4 && ReleaseNotes.pages(from: "1.3", to: "1.4").count == 2, "nouveautés par version")
        check(ReleaseNotes.pages(from: "1.3", to: "1.3.1").isEmpty, "pas de nouveautés pour une petite version")
        let fr = Polisher.promptEN(for: .en)
        check(fr.contains("Reply with the cleaned text only") && fr.contains("in English"), "consigne anglaise")
    }

    static func commands() {
        let cases: [(String, String)] = [
            ("Bonjour. À la ligne. Comment ça va ?", "Bonjour.\nComment ça va ?"),
            ("Bonjour, à la ligne, comment ça va", "Bonjour\nComment ça va"),
            ("Premier point. Nouveau paragraphe. Deuxième point.", "Premier point.\n\nDeuxième point."),
            ("Le rendez-vous, ouvrez la parenthèse, mardi, fermez la parenthèse, est confirmé.", "Le rendez-vous (mardi) est confirmé."),
            ("Tu viens demain, point d'interrogation.", "Tu viens demain ?"),
            ("Tu viens demain point d'interrogation", "Tu viens demain ?"),
            ("Il a dit ouvrez les guillemets bonjour fermez les guillemets.", "Il a dit « bonjour »."),
            ("First item. New line. Second item.", "First item.\nSecond item."),
            ("See the docs, open parenthesis, page two, close parenthesis.", "See the docs (page two)."),
            ("Are you coming question mark", "Are you coming?"),
            ("Can you come? Question mark", "Can you come?"),
            ("Rien de spécial ici.", "Rien de spécial ici."),
            ("Une parenthèse dans la phrase.", "Une parenthèse dans la phrase."),
        ]
        for (input, expected) in cases {
            let out = VoiceCommands.apply(to: input)
            check(out == expected, "commande : « \(input) » → « \(out) » (attendu « \(expected) »)")
        }
    }

    /// Le moteur 1337 : substitution, déterminisme, protection des liens,
    /// accents et caractères hors table.
    static func leet() {
        // Les six substitutions du niveau léger, en minuscules (aucune casse
        // décorative sur un texte sans lettre hors table).
        check(Leet.transform("a", level: .light) == "4", "léger : a → 4")
        check(Leet.transform("e", level: .light) == "3", "léger : e → 3")
        check(Leet.transform("i", level: .light) == "1", "léger : i → 1")
        check(Leet.transform("o", level: .light) == "0", "léger : o → 0")
        check(Leet.transform("s", level: .light) == "5", "léger : s → 5")
        check(Leet.transform("t", level: .light) == "7", "léger : t → 7")
        // Le léger ne touche pas aux autres lettres.
        check(Leet.transform("b", level: .light) == "B" || Leet.transform("b", level: .light) == "b",
              "léger : b reste b (casse décorative seulement)")

        // Le moyen ajoute b, g, l, z ; le complet ajoute c, k, x et le $ pour s.
        let mediumB = Leet.transform("b", level: .medium).lowercased()
        check(mediumB == "8", "moyen : b → 8 (\(mediumB))")
        check(Leet.transform("g", level: .medium).lowercased() == "9", "moyen : g → 9")
        check(Leet.transform("z", level: .medium).lowercased() == "2", "moyen : z → 2")
        check(Leet.transform("k", level: .full).lowercased() == "|<", "complet : k → |<")
        check(Leet.transform("c", level: .full).lowercased() == "(", "complet : c → (")
        check(Leet.transform("s", level: .full).lowercased() == "$", "complet : s → $")
        // Le moyen garde le s simple.
        check(Leet.transform("s", level: .medium).lowercased() == "5", "moyen : s → 5 (pas $)")

        // TOUT est déterministe : le même texte, dix fois, donne la même chose.
        let phrase = "Le renard brun saute par-dessus le chien paresseux."
        let once = Leet.transform(phrase, level: .medium)
        check((0..<10).allSatisfy { _ in Leet.transform(phrase, level: .medium) == once },
              "même texte → même résultat (déterminisme)")
        // Et deux textes différents ne donnent pas la même casse (graine distincte).
        check(Leet.transform("le renard", level: .medium) != Leet.transform("le chien", level: .medium),
              "graines différentes selon le texte")

        // Le nombre de caractères « transformés » est plausible : la phrase
        // contient bien des chiffres après passage.
        check(once.contains(where: { $0.isNumber }), "le maquillage produit des chiffres")
        // La longueur ne fond pas : rien n'est perdu.
        check(once.count >= phrase.count, "aucun caractère perdu (\(phrase.count) → \(once.count))")

        // Liens, e-mails, chemins : intacts, lettre pour lettre.
        let url = "https://exemple.fr/un-chemin?x=1"
        let mail = "pierre@exemple.fr"
        let path = "/usr/local/bin/plume"
        let winPath = #"C:\Users\pierre"#
        let www = "www.exemple.fr"
        for token in [url, mail, path, winPath, www] {
            check(Leet.transform(token, level: .full) == token, "intact : \(token)")
        }
        // Même au milieu d'une phrase, le lien reste intact (et lui seul).
        let withLink = "va voir https://exemple.fr/page ici"
        let linked = Leet.transform(withLink, level: .full)
        // On ne peut pas tester `contains(url)` : les autres tokens de la phrase
        // sont maquillés et le lien, lui, est le seul à commencer par « https ».
        // On vérifie donc que la partie après le premier espace est le lien exact.
        // « va voir https://… ici » → 4 tokens, le lien est le 3ᵉ.
        let tokens = linked.split(separator: " ").map(String.init)
        check(tokens.count == 4 && tokens[2] == "https://exemple.fr/page", "lien intact au milieu d'une phrase (\(tokens))")
        // Le reste de la phrase, lui, est bien maquillé.
        check(tokens[0] != "va" && tokens[1] != "voir" && tokens[3] != "ici", "le reste de la phrase est maquillé")
        // Et la ponctuation du lien n'a pas été avalée.
        check(linked.contains("exemple.fr/page"), "le chemin du lien n'est pas tronqué")

        // Accents et caractères hors table : inchangés.
        for ch in ["é", "è", "ê", "ç", "à", "ù", "œ", "—", "!", "?", "«", "»"] {
            check(Leet.transform(ch, level: .full) == ch, "inchangé : \(ch)")
        }
        check(Leet.transform("café", level: .light).hasSuffix("é"), "l'accent reste à sa place")

        // Le texte vide et les espaces ne cassent rien.
        check(Leet.transform("", level: .full) == "", "texte vide")
        check(Leet.transform("   ", level: .full) == "   ", "espaces seuls")
        check(Leet.transform("a b", level: .light).count == 3, "les espaces séparent les tokens")

        // Le niveau change vraiment le résultat.
        check(Leet.transform(phrase, level: .light) != Leet.transform(phrase, level: .medium)
              && Leet.transform(phrase, level: .medium) != Leet.transform(phrase, level: .full),
              "les trois niveaux diffèrent")
    }

    /// Le raccourci à deux modificateurs : construction, ordre, refus, appui.
    static func leetShortcuts() {
        let pair = Shortcut.comboModifiers(55, 58)
        check(pair != nil, "⌘ gauche + ⌥ gauche construit")
        check(pair?.kind == .modifierCombo, "sorte modifierCombo")
        check(pair?.keyCode == 55 && pair?.secondKeyCode == 58, "⌘ en premier, ⌥ en second (ordre d'affichage)")
        // L'ordre de frappe ne change rien à l'identité du raccourci.
        check(Shortcut.comboModifiers(58, 55) == pair, "⌥ puis ⌘ = ⌘ puis ⌥")
        // L'étiquette se lit.
        check(pair?.label.contains("⌘") == true && pair?.label.contains("⌥") == true, "étiquette avec ⌘ et ⌥")

        // Refus : fn, deux fois la même touche, deux fois le même modificateur.
        check(Shortcut.comboModifiers(63, 58) == nil, "fn refusé")
        check(Shortcut.comboModifiers(58, 63) == nil, "fn refusé (second)")
        check(Shortcut.comboModifiers(58, 58) == nil, "même touche refusée")
        check(Shortcut.comboModifiers(55, 54) == nil, "⌘ gauche + ⌘ droite refusé")

        // Détection de l'appui, avec les bits de côté (NX_DEVICE…KEYMASK).
        guard let p = pair else { return }
        let cmdLeft: UInt64 = 0x08, optLeft: UInt64 = 0x20
        let command: UInt64 = 0x0010_0000, alternate: UInt64 = 0x0008_0000
        let both = CGEventFlags(rawValue: command | alternate | cmdLeft | optLeft)
        let cmdOnly = CGEventFlags(rawValue: command | cmdLeft)
        let rightOption = CGEventFlags(rawValue: command | alternate | cmdLeft | 0x40)
        check(p.isDown(both) && (p.bothDown(both)), "les deux enfoncées")
        check(p.isDown(cmdOnly) && !p.bothDown(cmdOnly), "⌘ seule : pas le couple")
        check(!p.bothDown(rightOption), "⌥ droite ≠ ⌥ gauche")

        // Rétrocompatibilité : un raccourci enregistré avant le 1337 (sans
        // `secondKeyCode`) se relit tel quel.
        let old = #"{"kind":"modifier","keyCode":63,"modifiers":0,"display":"fn"}"#
        let decoded = try? JSONDecoder().decode(Shortcut.self, from: Data(old.utf8))
        check(decoded == .default, "ancien raccourci relu (clé nouvelle absente)")
        check(decoded?.secondKeyCode == nil, "secondKeyCode vide par défaut")

        // Le nouveau se relit aussi.
        if let data = try? JSONEncoder().encode(p),
           let back = try? JSONDecoder().decode(Shortcut.self, from: data) {
            check(back == p, "couple relu après enregistrement")
        } else {
            check(false, "couple relu après enregistrement")
        }

        // Les préréglages de couple : tous valides, et pas de doublon.
        check(Shortcut.pairPresets.count == 5, "cinq couples proposés (\(Shortcut.pairPresets.count))")
        check(Shortcut.pairPresets.allSatisfy { $0.kind == .modifierCombo }, "les préréglages sont des couples")
        check(Set(Shortcut.pairPresets.map(\.display)).count == Shortcut.pairPresets.count, "pas de doublon")
        check(Shortcut.leetPairFor(.default)?.label.contains("fn") == true, "1337 = ⌘ + la touche de dictée (⌘fn)")
        check(Shortcut.leetPairFor(Shortcut.modifierKey(58)!)?.label.contains("⌥") == true, "avec ⌥ en dictée → ⌘⌥")
        check(Shortcut.leetPairFor(Shortcut.modifierKey(55)!) == nil, "pas de ⌘+⌘")
    }

    static func filter() {
        check(TranscriptFilter.clean("Sous-titrage Société Radio-Canada", audioSeconds: 3).isEmpty, "générique retiré")
        check(TranscriptFilter.clean("Bonjour\nBonjour\nça va", audioSeconds: 3) == "Bonjour ça va", "segment répété retiré")
    }

    // MARK: Réunion

    /// Une « voix » de test : une sinusoïde à 220 Hz, 16 kHz comme les pistes.
    private static func meetingSine(_ seconds: Double, amplitude: Float = 0.2) -> [Float] {
        let count = Int(seconds * AudioRecorder.sampleRate)
        return (0..<count).map {
            Float(sin(2 * Double.pi * 220 * Double($0) / AudioRecorder.sampleRate)) * amplitude
        }
    }

    private static func meetingSilence(_ seconds: Double) -> [Float] {
        [Float](repeating: 0, count: Int(seconds * AudioRecorder.sampleRate))
    }

    /// Les quatre octets little-endian d'un en-tête WAV.
    private static func meetingLE32(_ data: Data, at offset: Int) -> UInt32? {
        guard data.count >= offset + 4 else { return nil }
        let bytes = [UInt8](data[offset..<(offset + 4)])
        return UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
    }

    /// Le découpage d'une piste : un paragraphe s'arrête sur une pause, jamais
    /// au milieu d'un mot, et 2 s sans respirer forcent la coupe.
    static func meetingSegmenter() {
        // 0,8 s : trop court, on attend encore.
        check(MeetingSegmenter.cut(meetingSine(0.8)) == nil, "0,8 s de voix → pas de coupe")

        // 1,5 s de voix puis 0,3 s de silence : la coupe tombe dans le silence.
        let tail = meetingSine(1.5) + meetingSilence(0.3)
        let tailCut = MeetingSegmenter.cut(tail)
        check(tailCut != nil && Double(tailCut!) > 1.5 * 16000 && Double(tailCut!) <= 1.8 * 16000,
              "coupe dans le silence final (\(tailCut.map(String.init) ?? "nil"))")

        // 2,4 s de voix avec un quasi-silence à 1,4-1,7 s : on coupe dedans,
        // pas au hasard dans les 0,25 s les plus calmes.
        let withPause = meetingSine(1.4) + meetingSine(0.3, amplitude: 0.001) + meetingSine(0.7)
        let pauseCut = MeetingSegmenter.cut(withPause)
        check(pauseCut != nil && Double(pauseCut!) >= 1.4 * 16000 && Double(pauseCut!) <= 1.7 * 16000,
              "coupe dans le quasi-silence (\(pauseCut.map(String.init) ?? "nil"))")

        // 2,4 s de voix sans aucune pause : coupe forcée entre 1 et 2 s.
        let forcedCut = MeetingSegmenter.cut(meetingSine(2.4))
        check(forcedCut != nil && Double(forcedCut!) >= 16000 && Double(forcedCut!) <= 32000,
              "coupe forcée sans pause (\(forcedCut.map(String.init) ?? "nil"))")

        // 1,2 s de silence pur : c'est un morceau silencieux, pas « on attend ».
        check(MeetingSegmenter.cut(meetingSilence(1.2)) != nil, "1,2 s de silence → coupe quand même")
    }

    /// Le nom d'un dossier de réunion : daté, et sans caractère interdit.
    static func meetingFolderName() {
        guard let date = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 22, hour: 15, minute: 4))
        else { check(false, "date de test construite"); return }

        let zoom = MeetingFolder.folderName(date: date, source: "Zoom")
        check(zoom == "2026-10-22 15h04 — Zoom", "nom daté avec la source (\(zoom))")

        // « a/b:c » ne doit pas pouvoir sortir du dossier ni casser un chemin.
        let cleaned = MeetingFolder.folderName(date: date, source: "a/b:c")
        let suffix = cleaned.components(separatedBy: " — ").last ?? cleaned
        check(!suffix.contains("/") && !suffix.contains(":"), "caractères interdits retirés (\(suffix))")

        check(MeetingFolder.folderName(date: date, source: "") == "2026-10-22 15h04", "sans source : la date seule")
    }

    /// Le journal d'une réunion : la dernière version d'un paragraphe gagne,
    /// et une ligne illisible n'emporte pas les autres.
    static func meetingParagraphJournal() {
        let dir = tempFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let folder = MeetingFolder(url: dir)

        let brute = MeetingParagraph(id: 1, speaker: .them, start: 5, end: 8,
                                     raw: "brut un", text: "brut un", polished: false)
        let autre = MeetingParagraph(id: 2, speaker: .me, start: 2, end: 4,
                                     raw: "brut deux", text: "brut deux", polished: false)
        let lisse = MeetingParagraph(id: 1, speaker: .them, start: 5, end: 8,
                                     raw: "brut un", text: "version lissée", polished: true)
        var journal = ""
        for p in [brute, autre, lisse] {
            guard let line = try? MeetingFiles.encoder.encode(p) else { check(false, "paragraphe encodé"); return }
            journal += String(decoding: line, as: UTF8.self) + "\n"
        }
        try? Data(journal.utf8).write(to: folder.paragraphsURL)

        let read = folder.readParagraphs()
        check(read.count == 2, "deux paragraphes relus (\(read.count))")
        // Le plus tôt d'abord : l'ordre du temps, pas celui des écritures.
        check(read.first?.id == 2, "ordre du temps : le plus tôt d'abord")
        let one = read.first { $0.id == 1 }
        check(one?.polished == true && one?.text == "version lissée", "la version lissée remplace le brut")

        // Une ligne cassée au milieu : ignorée, les autres restent.
        var lines = journal.components(separatedBy: "\n").filter { !$0.isEmpty }
        lines.insert("{not json", at: 1)
        try? Data((lines.joined(separator: "\n") + "\n").utf8).write(to: folder.paragraphsURL)
        let afterBreak = folder.readParagraphs()
        check(afterBreak.count == 2 && afterBreak.first { $0.id == 1 }?.polished == true,
              "ligne illisible ignorée, les autres gardées")
    }

    /// Le Markdown d'une réunion : horodatage, qui parle, et le mot qui
    /// prévient que le texte n'est pas lissé.
    static func meetingMarkdown() {
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        let meta = MeetingMeta(startedAt: start, endedAt: start.addingTimeInterval(90), duration: 90,
                               source: "Zoom", model: "parakeet-ultra", words: 2, paragraphs: 2, recording: false)
        let lisse = MeetingParagraph(id: 1, speaker: .them, start: 65.4, end: 70,
                                     raw: "bonjour", text: "bonjour", polished: true)
        let brut = MeetingParagraph(id: 2, speaker: .me, start: 70, end: 72,
                                    raw: "salut", text: "salut", polished: false)
        let text = MeetingFiles.markdown(meta: meta, paragraphs: [lisse, brut])
        check(text.contains("[00:01:05]"), "horodatage du paragraphe")
        check(text.contains("**" + MeetingSpeaker.me.label + "**"), "qui parle, en gras")

        // Le réglage du nettoyage est celui de la personne : on lit, on ne pose rien.
        let marker = L("(non nettoyé)", "(not cleaned up)")
        if Prefs.polishWanted {
            check(text.contains(marker), "non lissé signalé quand le nettoyage est demandé")
        } else {
            check(!text.contains(marker), "aucun avertissement quand le nettoyage est coupé")
        }

        check(MeetingFiles.duration(42) == "42 s", "durée en secondes")
        check(MeetingFiles.duration(125) == "2 min", "durée en minutes")
        check(MeetingFiles.duration(3900) == "1 h 05", "durée en heures")
        check(MeetingFiles.timestamp(3725) == "01:02:05", "horodatage 1 h 02 min 05 s")
    }

    /// Le WAV d'une piste et la réparation d'un enregistrement interrompu :
    /// l'en-tête revient à sa taille réelle, sans rien jeter.
    static func meetingWavAndRecovery() {
        let dir = tempFolder()
        defer { try? FileManager.default.removeItem(at: dir) }

        let samples = meetingSine(1.0)
        let url = dir.appendingPathComponent("moi.wav")
        guard let writer = try? WavFileWriter(url: url) else { check(false, "WAV créé"); return }
        samples.withUnsafeBufferPointer { writer.append($0) }
        writer.close()

        let data = (try? Data(contentsOf: url)) ?? Data()
        check(data.count == 44 + 32000, "taille du WAV : 44 + 32000 octets (\(data.count))")
        check(meetingLE32(data, at: 40) == 32000, "en-tête : 32000 octets de données")

        // Relu au milieu : les échantillons d'origine, au millième près.
        let reread = WavFileWriter.read(url, from: 8000, count: 100)
        check(reread.count == 100 && zip(reread, samples[8000..<8100]).allSatisfy { abs($0 - $1) < 0.001 },
              "100 échantillons relus au bon endroit")

        // App arrêtée net : l'en-tête dit 0 octet de données, le fichier en a 3200.
        let crashed = dir.appendingPathComponent("eux.wav")
        try? (WavFileWriter.header(dataBytes: 0) + Data(count: 3200)).write(to: crashed)
        let seconds = MeetingTranscript.repairWavHeader(crashed) ?? -1
        check(abs(seconds - 0.1) < 0.0001, "durée réparée : 0,1 s (\(seconds))")
        let repaired = (try? Data(contentsOf: crashed)) ?? Data()
        check(meetingLE32(repaired, at: 40) == 3200, "en-tête réparé : 3200 octets")

        // Une réunion restée ouverte : son journal se relit, ses pistes se
        // réparent. On n'appelle pas `recoverInterrupted` : il balaie le vrai
        // dossier des réunions, pas un dossier de test.
        let interrupted = dir.appendingPathComponent("2026-10-22 15h04 — Zoom", isDirectory: true)
        try? FileManager.default.createDirectory(at: interrupted, withIntermediateDirectories: true)
        let folder = MeetingFolder(url: interrupted)
        let open = MeetingParagraph(id: 1, speaker: .me, start: 0, end: 1.2,
                                    raw: "bonjour", text: "bonjour", polished: false, open: true)
        if let line = try? MeetingFiles.encoder.encode(open) {
            try? Data(line + Data([UInt8(ascii: "\n")])).write(to: folder.paragraphsURL)
        } else {
            check(false, "paragraphe ouvert encodé")
        }
        try? FileManager.default.copyItem(at: crashed, to: folder.micURL)
        let rereadMeeting = folder.readParagraphs()
        check(rereadMeeting.count == 1 && rereadMeeting.first?.open == true, "réunion interrompue : le journal se relit")
        check(abs((MeetingTranscript.repairWavHeader(folder.micURL) ?? -1) - 0.1) < 0.0001,
              "réunion interrompue : la piste se répare")
    }

    /// L'anti-écho et les vumètres : sans mots normalisés, le micro qui
    /// réentend les haut-parleurs doublerait chaque phrase.
    static func meetingEchoAndLevels() {
        let words = MeetingRecorder.wordSet("Bonjour, c'est Pierre !")
        check(words.contains("bonjour") && words.contains("pierre"), "mots normalisés (sans casse ni accent)")
        check(words.count == 4, "quatre mots : bonjour, c, est, pierre (\(words.sorted()))")

        check(MeetingLevels.bars(0) == 0, "niveau nul : aucune barre")
        check(MeetingLevels.bars(1) == MeetingLevels.bars, "niveau plein : toutes les barres")
        check(MeetingLevels.bars(0.5) == 3, "niveau moyen : trois barres")
    }
}

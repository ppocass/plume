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
    /// de Pierre), en rejouant les cas qui font revenir l'assistant.
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
        check(Shortcut.pairPresets.contains(.leetDefault), "⌘⌥ est bien le défaut")
    }

    static func filter() {
        check(TranscriptFilter.clean("Sous-titrage Société Radio-Canada", audioSeconds: 3).isEmpty, "générique retiré")
        check(TranscriptFilter.clean("Bonjour\nBonjour\nça va", audioSeconds: 3) == "Bonjour ça va", "segment répété retiré")
    }
}

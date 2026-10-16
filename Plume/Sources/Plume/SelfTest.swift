import Foundation

/// Autotest sans micro ni interface : `Plume --selftest fichier.wav [...]`.
/// Fait passer chaque WAV 16 kHz mono par exactement le même chemin qu'une
/// dictée (barrière, découpage, moteur, filtre, nettoyage) et affiche le
/// résultat. Sert à vérifier l'app sans toucher au clavier.
enum SelfTest {
    /// `Plume --selftest-polish "texte" ...` : le lissage seul.
    static func polishOnly(_ texts: [String]) async -> Int32 {
        // Diagnostic (jamais la clé elle-même).
        let ep = Polisher.endpoint()
        print("service : \(PolishService.current.rawValue) · adresse : \(ep?.url.absoluteString ?? "aucune") · modèle : \(ep?.model ?? "-") · clé : \(ep?.key == nil ? "absente" : "présente")")
        for text in texts {
            let started = Date()
            let out = await Polisher.polish(text, language: .fr)
            print(String(format: "— %@\n  → %@ (%.2f s)", text, out ?? "[indisponible]", Date().timeIntervalSince(started)))
        }
        return 0
    }

    /// `Plume --download-model <id>` : télécharge et vérifie un modèle du
    /// catalogue (même chemin que la page Modèles), en affichant la progression.
    static func download(_ id: String) async -> Int32 {
        guard let m = ModelCatalog.model(id), m.family != .cloud else { print("❌ modèle inconnu : \(id)"); return 1 }
        if ModelLocation.isInstalled(m) { print("déjà installé : \(ModelLocation.installedFolder(m)!.path)"); return 0 }
        let started = Date()
        let last = Counter()
        do {
            try await ModelDownloader.install(m) { fraction in
                let step = Int(fraction * 10)
                if last.bump(to: step) { print("  \(step * 10) %") }
            }
            print(String(format: "✅ %@ installé et vérifié en %.0f s : %@", m.id, Date().timeIntervalSince(started),
                         ModelLocation.installedFolder(m)?.path ?? "?"))
            return 0
        } catch {
            print("❌ \(error.localizedDescription)")
            return 1
        }
    }

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = -1
        func bump(to v: Int) -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard v > value else { return false }
            value = v
            return true
        }
    }

    static func run(_ files: [String]) async -> Int32 {
        var failures: Int32 = 0
        for path in files {
            guard let data = FileManager.default.contents(atPath: path), let samples = SpeechGate.readWav(data) else {
                print("❌ \(path) : WAV illisible"); failures += 1; continue
            }
            let seconds = Double(samples.count) / AudioRecorder.sampleRate
            let verdict = SpeechGate.analyse(samples)
            print("— \((path as NSString).lastPathComponent) : \(String(format: "%.1f", seconds)) s, barrière → \(verdict.reason)")
            guard let range = verdict.range else { continue }
            let started = Date()
            do {
                let vocab = await MainActor.run { VocabularyStore.shared.snapshot }
                let usePrompt = ProcessInfo.processInfo.environment["PLUME_NO_VOCAB"] == nil
                let engine = SpeechEngine.shared
                let pieces = try await DictationController.transcribe(samples, range: range, engine: engine, language: .fr,
                                                                      prompt: usePrompt ? vocab.whisperPrompt : nil)
                print("  \(engine.model.id), \(pieces.count) morceau·x")
                let parts = pieces.texts
                let raw = usePrompt ? vocab.apply(to: parts.joined(separator: " ")) : parts.joined(separator: " ")
                print(String(format: "  Texte (%.2f s) : %@", Date().timeIntervalSince(started), raw))
                let p0 = Date()
                if let polished = await Polisher.polish(raw, language: .fr, spelling: usePrompt ? vocab.spellingList : "") {
                    print(String(format: "  Lissé (%.2f s) : %@", Date().timeIntervalSince(p0), polished))
                } else {
                    print("  Lissage indisponible → brut")
                }
            } catch {
                print("❌ moteur : \(error.localizedDescription)"); failures += 1
            }
        }
        await SpeechEngine.shared.stopOwned()
        try? await Task.sleep(for: .milliseconds(500))
        return failures
    }
}

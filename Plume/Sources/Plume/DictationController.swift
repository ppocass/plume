import AppKit
import AVFoundation
import SwiftUI

/// Ce que montre la pastille.
enum PillPhase: Equatable {
    case hidden
    case recording
    case processing
    case pasted
    /// Pas de champ de texte : la pastille s'agrandit et montre le début du
    /// texte. **Clic dessus = copié dans le presse-papiers**, **double appui sur
    /// la touche = le pop-up se ferme** (le texte reste dans l'historique).
    case savedToHistory(String)
    /// Vient de partir dans le presse-papiers : ✓ le temps de le dire.
    case copied
    case message(String, isError: Bool)

    /// Le pop-up « rien à coller » reste tant qu'on ne le ferme pas.
    var staysUntilDismissed: Bool {
        if case .savedToHistory = self { return true }
        return false
    }

    /// Ce que la pastille montre mérite la fenêtre large (l'aperçu du texte).
    var showsPreview: Bool {
        if case .savedToHistory = self { return true }
        return false
    }

    /// Le texte gardé dans l'historique, s'il y en a un à montrer/copier.
    var previewText: String? {
        if case .savedToHistory(let t) = self { return t }
        return nil
    }
}

/// Les niveaux récents du micro, pour les barres de la pastille.
@MainActor
final class LevelMeter: ObservableObject {
    static let barCount = 13
    @Published var levels = [Float](repeating: 0, count: LevelMeter.barCount)

    func push(_ level: Float) {
        var l = levels
        l.removeFirst()
        l.append(level)
        levels = l
    }

    func reset() { levels = [Float](repeating: 0, count: Self.barCount) }
}

/// Le chef d'orchestre de la dictée, sur le raccourci choisi :
///
/// - **1 appui** : début de l'enregistrement, la pastille apparaît ;
/// - pendant ce temps on peut aller dans n'importe quelle app ;
/// - **1 appui** : fin → transcription → nettoyage si réseau → collé là où est
///   le curseur à ce moment-là (ou gardé dans l'historique s'il n'y a pas de champ) ;
/// - **2 appuis rapides** : annulé, rien n'est écrit.
///
/// L'appui de fin attend `doubleTapWindow` avant de lancer le traitement :
/// le temps de savoir si un deuxième appui (= annuler) arrive.
@MainActor
final class DictationController: ObservableObject {
    static let shared = DictationController()

    @Published private(set) var phase: PillPhase = .hidden
    @Published private(set) var recordingStartedAt: Date?
    let meter = LevelMeter()

    static let doubleTapWindow: TimeInterval = 0.3
    /// Garde-fou : une dictée oubliée s'arrête toute seule au bout de 10 min.
    static let maxRecordingSeconds: TimeInterval = 600

    private let recorder = AudioRecorder()
    private var pendingStop: Task<Void, Never>?
    /// Attend le second appui qui referme le pop-up « rien à coller ».
    private var pendingDismiss: Task<Void, Never>?
    private var hideTask: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?
    private var isProcessing = false
    private var live: LiveTranscriber?

    /// Une fenêtre (Réglages) demande à s'ouvrir.
    var onOpenWindow: (() -> Void)?

    private init() {
        recorder.onLevel = { [weak self] level in
            Task { @MainActor in self?.meter.push(level) }
        }
    }

    // MARK: Gestes

    func handleTap() {
        if isProcessing {
            // Pendant le traitement, un appui ne fait rien (la dictée en cours
            // va être collée) — on ne veut pas en démarrer une autre par erreur.
            return
        }
        // Le pop-up « rien à coller » est à l'écran : un appui seul ne fait
        // **rien** — il attend le second, car **deux appuis rapides le
        // referment**. Aucune dictée ne démarre tant qu'il est là.
        if phase.staysUntilDismissed {
            if let pendingDismiss {
                pendingDismiss.cancel()
                self.pendingDismiss = nil
                hide()
            } else {
                pendingDismiss = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(Self.doubleTapWindow))
                    guard !Task.isCancelled else { return }
                    self?.pendingDismiss = nil
                }
            }
            return
        }
        if isRecording {
            if let pendingStop {
                // Deuxième appui rapide : annuler.
                pendingStop.cancel()
                self.pendingStop = nil
                cancel()
            } else {
                pendingStop = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(Self.doubleTapWindow))
                    guard !Task.isCancelled else { return }
                    self?.pendingStop = nil
                    self?.finish()
                }
            }
        } else {
            start()
        }
    }

    /// La croix rouge de la pastille.
    func cancelFromPill() {
        pendingStop?.cancel()
        pendingStop = nil
        pendingDismiss?.cancel()
        pendingDismiss = nil
        if isRecording { cancel() } else if !isProcessing { hide() }
    }

    // MARK: Enregistrement

    /// Tests seulement : `PLUME_FAKE_AUDIO=fichier.wav` remplace le micro par ce
    /// fichier (pour vérifier touche → pastille → transcription → collage sans parler).
    private let fakeAudio: [Float]? = ProcessInfo.processInfo.environment["PLUME_FAKE_AUDIO"]
        .flatMap { FileManager.default.contents(atPath: $0) }.flatMap { SpeechGate.readWav($0) }
    private var fakeRecording = false

    private var isRecording: Bool { recorder.isRunning || fakeRecording }

    private func start() {
        if fakeAudio != nil {
            fakeRecording = true
            recordingStartedAt = Date()
            phase = .recording
            PillPanel.shared.present()
            Task.detached { try? await SpeechEngine.shared.ensureRunning() }
            return
        }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            break
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                Task { @MainActor in
                    if granted { self.start() } else { self.show(.message(L("Micro refusé", "Microphone denied"), isError: true), for: 2.5) }
                }
            }
            return
        default:
            show(.message(L("Autorisez le micro", "Allow the microphone"), isError: true), for: 3)
            onOpenWindow?()
            return
        }

        hideTask?.cancel()
        meter.reset()
        do {
            try recorder.start()
        } catch {
            Log.info("micro : \(error.localizedDescription)")
            show(.message(L("Micro indisponible", "Microphone unavailable"), isError: true), for: 2.5)
            return
        }
        recordingStartedAt = Date()
        phase = .recording
        PillPanel.shared.present()
        if Prefs.shared.soundsEnabled { NSSound(named: "Tink")?.play() }

        // Le modèle se charge PENDANT qu'on parle.
        let model = ModelStore.active
        Task.detached { try? await SpeechEngine.engine(for: model).ensureRunning() }
        // Whisper : les tranches de 8 s sont transcrites pendant qu'on parle,
        // à la fin il ne reste que la dernière. (Parakeet est assez rapide pour
        // tout faire d'un coup : 30 s en 0,4 s sur un M1.)
        live = nil
        if model.family == .whisper {
            let l = LiveTranscriber()
            l.start(recorder: recorder, engine: SpeechEngine.engine(for: model),
                    language: Prefs.shared.effectiveLanguage, prompt: VocabularyStore.shared.snapshot.whisperPrompt)
            live = l
        }

        watchdog?.cancel()
        watchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.maxRecordingSeconds))
            guard !Task.isCancelled, let self, self.recorder.isRunning else { return }
            Log.info("10 min d'enregistrement : arrêt automatique")
            self.finish()
        }
    }

    private func cancel() {
        watchdog?.cancel()
        live?.abandon()
        live = nil
        fakeRecording = false
        _ = recorder.stop()
        recordingStartedAt = nil
        Log.info("dictée annulée (double appui)")
        if Prefs.shared.soundsEnabled { NSSound(named: "Pop")?.play() }
        Task.detached { await SpeechEngine.shared.scheduleIdleRelease(after: Prefs.idleSeconds) }
        hide()
    }

    private func finish() {
        watchdog?.cancel()
        var samples = recorder.stop()
        if fakeRecording, let fakeAudio { samples = fakeAudio }
        fakeRecording = false
        recordingStartedAt = nil
        isProcessing = true
        phase = .processing
        if Prefs.shared.soundsEnabled { NSSound(named: "Bottle")?.play() }
        let language = Prefs.shared.effectiveLanguage
        let polishOn = Prefs.shared.polishEnabled
        let live = self.live
        self.live = nil
        Log.info(String(format: "fin de dictée (%.1f s), traitement…", Double(samples.count) / AudioRecorder.sampleRate))

        Task { [weak self] in
            guard let self else { return }
            defer {
                self.isProcessing = false
                Task.detached { await SpeechEngine.shared.scheduleIdleRelease(after: Prefs.idleSeconds) }
            }
            let t0 = Date()
            let done = await live?.finishLive()
            if live != nil { Log.info(String(format: "au fil de l'eau : terminé %.2f s après la fin", Date().timeIntervalSince(t0))) }
            await self.process(samples: samples, language: language, polishOn: polishOn, existing: nil, live: done)
        }
    }

    // MARK: Traitement

    /// Transcrit, lisse, colle (ou garde), et range dans l'historique.
    /// `existing` : une dictée ratée qu'on réessaie depuis l'historique (pas de collage).
    func process(samples: [Float], language: DictationLanguage, polishOn: Bool, existing: Dictation?,
                 live: LiveTranscriber.Result? = nil) async {
        let seconds = Double(samples.count) / AudioRecorder.sampleRate
        let engine = SpeechEngine.shared
        let vocabulary = VocabularyStore.shared.snapshot
        let started = Date()

        // Ce que la transcription au fil de l'eau a déjà fait (Whisper), et ce qu'il reste.
        var parts = live?.texts ?? []
        let tailStart = live?.cut ?? 0
        let rest = tailStart == 0 ? samples : Array(samples[min(tailStart, samples.count)...])

        let verdict = SpeechGate.analyse(rest)
        if verdict.range == nil {
            Log.info(String(format: "fin : rien à transcrire (%@, %.1f s d'audio)", verdict.reason, Double(rest.count) / 16_000))
        }
        var chunkCount = live?.chunks ?? 0
        if let range = verdict.range {
            do {
                let pieces = try await Self.transcribe(rest, range: range, engine: engine, language: language,
                                                       prompt: vocabulary.whisperPrompt)
                chunkCount += pieces.count
                parts += pieces.texts
            } catch {
                Log.info("\(engine.model.id) a échoué : \(error.localizedDescription)")
                if existing == nil { keepFailed(samples: samples, seconds: seconds) }
                show(.message(L("Moteur indisponible · gardé dans l'historique", "Engine unavailable · saved to History"), isError: true), for: 3)
                return
            }
        }
        var raw = vocabulary.apply(to: parts.joined(separator: " "))
        if VoiceCommands.enabled { raw = VoiceCommands.apply(to: raw) }
        Log.info(String(format: "%@ : %.1f s d'audio (%d morceau·x, %d déjà faits pendant la dictée) — %.2f s après la fin, %d caractères",
                        engine.model.id, seconds, chunkCount, live?.chunks ?? 0, Date().timeIntervalSince(started), raw.count))
        guard !raw.isEmpty else {
            if existing == nil { show(.message(L("Rien entendu", "Nothing heard"), isError: false), for: 1.6) }
            return
        }

        var final = raw
        var polished = false
        if polishOn, let out = await Polisher.polish(raw, language: language, spelling: vocabulary.spellingList) {
            final = vocabulary.apply(to: out)
            polished = true
        }

        if var retried = existing {
            if let name = retried.audioFile {
                try? FileManager.default.trashItem(at: HistoryStore.failedAudioFolder.appendingPathComponent(name), resultingItemURL: nil)
            }
            retried.text = final
            retried.raw = raw
            retried.polished = polished
            retried.failed = false
            retried.audioFile = nil
            HistoryStore.shared.replace(retried)
            return
        }

        // Le champ visé est celui où est le curseur MAINTENANT (on a pu
        // changer d'app pendant la dictée).
        let target = TextInserter.currentTarget()
        let shouldPaste = target.editable != false && target.bundleID != Bundle.main.bundleIdentifier
        Log.info("cible : \(target.appName ?? "?") rôle \(target.role ?? "?") éditable \(target.editable.map { String($0) } ?? "?") → \(shouldPaste ? "collage" : "historique")")
        if shouldPaste {
            TextInserter.paste(target.needsLeadingSpace ? " " + final : final)
        }
        // Champ de mot de passe : collé, mais jamais gardé en clair dans l'historique.
        let secret = target.role == "AXSecureTextField"
        HistoryStore.shared.add(Dictation(date: Date(), text: secret ? "••••••" : final, raw: secret ? "" : raw, polished: polished,
                                          pasted: shouldPaste, appName: target.appName, audioSeconds: seconds))
        if shouldPaste {
            show(.pasted, for: 0.9)
        } else {
            // Pas de champ : on montre le texte et on le laisse à l'écran — le
            // clic le copie, le double appui le ferme (voir `pillClicked` /
            // `handleTap`).
            showPersistent(.savedToHistory(final))
        }
    }

    private func keepFailed(samples: [Float], seconds: Double) {
        let name = "dictee-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(8)).wav"
        let url = HistoryStore.failedAudioFolder.appendingPathComponent(name)
        try? SpeechGate.wav(samples[...]).write(to: url)
        HistoryStore.shared.add(Dictation(date: Date(), text: "", raw: "", polished: false, pasted: false,
                                          appName: NSWorkspace.shared.frontmostApplication?.localizedName,
                                          audioSeconds: seconds, failed: true, audioFile: name))
    }

    /// « Réessayer » dans l'historique.
    func retry(_ d: Dictation) {
        guard let name = d.audioFile,
              let data = try? Data(contentsOf: HistoryStore.failedAudioFolder.appendingPathComponent(name)),
              let samples = SpeechGate.readWav(data) else { return }
        Task {
            await process(samples: samples, language: Prefs.shared.effectiveLanguage,
                          polishOn: Prefs.shared.polishEnabled, existing: d)
            await SpeechEngine.shared.scheduleIdleRelease(after: Prefs.idleSeconds)
        }
    }

    /// « Corriger un mot… » : retient la graphie mal entendue et corrige la
    /// dictée tout de suite.
    func learnCorrection(in item: Dictation, heard: String, wanted: String) {
        VocabularyStore.shared.add(word: wanted, variant: heard)
        let one = Vocabulary(entries: [VocabEntry(word: wanted.trimmingCharacters(in: .whitespaces),
                                                   variants: [heard.trimmingCharacters(in: .whitespaces)])])
        var fixed = item
        fixed.text = one.apply(to: item.text)
        fixed.raw = one.apply(to: item.raw)
        HistoryStore.shared.replace(fixed)
        Log.info("vocabulaire : nouvelle correction apprise depuis l'historique")
    }

    /// Transcrit la zone parlée selon le moteur : Parakeet et les services en
    /// ligne d'un seul coup ; Whisper local par tranches de 8 s (au-delà,
    /// `-ac 768` le fait répéter).
    nonisolated static func transcribe(_ samples: [Float], range: Range<Int>, engine: SpeechEngine,
                                       language: DictationLanguage, prompt: String?) async throws -> (texts: [String], count: Int) {
        let ranges = engine.model.family == .whisper ? SpeechGate.chunks(of: samples, range: range) : [range]
        var texts: [String] = []
        for r in ranges {
            let text = try await engine.transcribe(wav: SpeechGate.wav(samples[r]), language: language.rawValue, prompt: prompt)
            let cleaned = TranscriptFilter.clean(text, audioSeconds: Double(r.count) / AudioRecorder.sampleRate)
            if !cleaned.isEmpty { texts.append(cleaned) }
        }
        return (texts, ranges.count)
    }

    // MARK: Pastille

    private func show(_ p: PillPhase, for seconds: Double) {
        hideTask?.cancel()
        phase = p
        PillPanel.shared.present()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.hide()
        }
    }

    /// Comme `show`, mais **sans minuteur** : le pop-up reste tant qu'on ne le
    /// referme pas (clic du milieu de la pastille, clic sur la croix, ou
    /// double appui sur la touche).
    private func showPersistent(_ p: PillPhase) {
        hideTask?.cancel()
        hideTask = nil
        phase = p
        PillPanel.shared.present()
    }

    private func hide() {
        hideTask?.cancel()
        hideTask = nil
        phase = .hidden
        PillPanel.shared.dismiss()
    }

    /// Un clic sur la pastille (hors croix).
    ///
    /// - dictée en cours ou traitement : ouvre la fenêtre, comme avant ;
    /// - « rien à coller » : **copie le texte dans le presse-papiers**, dit ✓,
    ///   puis replie la pastille (la dictée est récupérée sans rouvrir l'app).
    func pillClicked() {
        switch phase {
        case .savedToHistory(let text):
            copyToClipboard(text)
            show(.copied, for: 1.2)
        case .recording, .processing:
            onOpenWindow?()
        default:
            break
        }
    }

    /// L'ancienne action « cliquer sur la pastille → fenêtre » (la croix de la
    /// vue l'appelle pour les autres états).
    func openWindow() { onOpenWindow?() }

    // MARK: Barre des menus

    var isRecordingNow: Bool { isRecording }
    var isBusy: Bool { isProcessing }

    /// « Démarrer / Terminer la dictée » du menu : sans attendre de second appui.
    func toggleFromMenu() {
        if isProcessing { return }
        if isRecording {
            pendingStop?.cancel()
            pendingStop = nil
            finish()
        } else {
            if phase.staysUntilDismissed { hide() }
            start()
        }
    }

    /// « Copier la dernière dictée » du menu.
    func copyLatest() {
        guard let latest = HistoryStore.shared.latest else { return }
        copyToClipboard(latest.text)
    }

    private func copyToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        pasteboard.writeObjects([item])
        Log.info("dictée copiée depuis le pop-up (\(text.count) caractères)")
    }
}

extension Prefs {
    /// Délai avant la mise en veille du moteur (réglable ; -1 = jamais).
    nonisolated static var idleSeconds: Double {
        let v = UserDefaults.standard.double(forKey: "engineIdleSeconds")
        return v == 0 ? 35 : v
    }
}

import AppKit
import AVFoundation
import Foundation

/// **Le chef d'orchestre d'une réunion.**
///
/// Deux pistes, jamais mélangées : le micro (« Moi », via `MicrophoneHub`,
/// le même flux que la dictée) et le son du Mac (« Eux », via
/// `SystemAudioTap`). Chacune est écrite **sur le disque** au fil de l'eau et
/// découpée **sur les micro-pauses** (morceaux de 1 à 2 s, coupe forcée à 2 s
/// dans la fenêtre de 0,25 s la plus calme). Chaque morceau part au moteur
/// local, dans l'ordre ; le texte brut s'affiche aussitôt.
///
/// Quand une piste se tait (1,5 s), son **paragraphe** se ferme : il est
/// retranscrit d'un bloc (le contexte complet corrige les mots coupés aux
/// jointures), puis lissé, et la version lissée **remplace** le brut sur place.
/// Hors connexion, le brut reste, marqué « non nettoyé » ; une passe unique à
/// la fin rattrape ce qui peut l'être.
///
/// Garde-fous : disque < 2 Go, durée maximale atteinte, app de visio fermée →
/// arrêt propre ; une piste muette depuis une minute → avertissement.
@MainActor
final class MeetingRecorder: ObservableObject {
    static let shared = MeetingRecorder()

    /// Le mode n'existe que si macOS sait écouter le son des autres apps (14.4+).
    nonisolated static var isSupported: Bool {
        if #available(macOS 14.4, *) { return true }
        return false
    }

    enum Phase: Equatable {
        case idle
        case starting
        case recording
        /// Arrêtée : on termine la transcription et le lissage.
        case finishing
    }

    /// Ce que le widget montre en direct (les derniers paragraphes seulement).
    struct Line: Identifiable, Equatable {
        let id: Int
        let speaker: MeetingSpeaker
        var text: String
        var open: Bool
        var polished: Bool
    }

    enum Warning: Hashable {
        case micSilent, systemSilent
    }

    /// Pourquoi la réunion s'est arrêtée toute seule (dit dans le pop-up de fin).
    enum StopReason: Equatable {
        case user, maxDuration, diskFull, appClosed

        var message: String? {
            switch self {
            case .user: return nil
            case .maxDuration: return L("Durée maximale atteinte", "Maximum length reached")
            case .diskFull: return L("Disque presque plein", "Disk almost full")
            case .appClosed: return L("L'app de visio s'est fermée", "The call app was closed")
            }
        }
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var startedAt: Date?
    /// La réunion en cours (son dossier sur le disque).
    @Published private(set) var folder: MeetingFolder?
    @Published private(set) var source = ""
    @Published private(set) var lines: [Line] = []
    @Published private(set) var warnings: Set<Warning> = []
    /// Les niveaux, à part : 15 rafraîchissements par seconde ne doivent pas
    /// redessiner le texte.
    let levels = MeetingLevels()

    var isRecording: Bool { phase == .recording || phase == .starting }

    /// Appelé à la fin, une fois tout écrit (le widget affiche « Copié · Ouvrir · Coller »).
    var onFinished: ((MeetingFolder, String, StopReason) -> Void)?
    /// Appelé quand le démarrage échoue (message court pour le widget).
    var onFailure: ((String) -> Void)?

    // MARK: Réglages fixes

    static let paragraphPause: Double = 1.5
    static let maxParagraphSeconds: Double = 30
    static let minFreeBytes: Int64 = 2_000_000_000
    static let silentWarningSeconds: Double = 60
    /// Une ligne de plus que ce que le widget peut montrer : la fenêtre complète est la page Réunions.
    static let maxLiveLines = 40

    // MARK: État d'une réunion

    private var mic: MeetingTrack?
    private var system: MeetingTrack?
    private var tapBox: AnyObject?
    private var micSubscription: UUID?
    private var transcript: MeetingTranscript?
    private var engine: SpeechEngine?
    private var meta: MeetingMeta?
    private var stopReason: StopReason = .user

    private var jobs: AsyncStream<Job>.Continuation?
    private var jobLoop: Task<Void, Never>?
    private var tickLoop: Task<Void, Never>?
    private var polishQueue: [MeetingParagraph] = []
    private var polishLoop: Task<Void, Never>?
    /// Après un échec du lissage, on n'attend plus de délai réseau pendant 30 s.
    private var polishPausedUntil = Date.distantPast

    private var nextID = 1
    private var open: [MeetingSpeaker: OpenParagraph] = [:]
    /// Tous les paragraphes terminés (texte seulement : 2 h ≈ 150 Ko).
    private var paragraphs: [MeetingParagraph] = []
    private var lastMetaWrite = Date.distantPast
    private var echoesDropped = 0
    /// Horloge commune (secondes depuis le démarrage du Mac) au début de la réunion.
    private var clock: TimeInterval = 0
    /// Délai entre la fin d'un morceau parlé et son texte à l'écran (journal + autotest).
    private(set) var textLags: [Double] = []

    private enum Job {
        case chunk(MeetingSpeaker, start: Int, samples: [Float])
        /// Fin de réunion : ferme les paragraphes ouverts, puis signale.
        case drain(CheckedContinuation<Void, Never>)
    }

    private struct OpenParagraph {
        let id: Int
        let speaker: MeetingSpeaker
        let start: Double
        var end: Double
        var audio: [Float] = []
        var texts: [String] = []
        var silence: Double = 0
        var lastJournal = Date()
        var liveText: String { texts.joined(separator: " ") }
    }

    // MARK: Démarrer, arrêter

    func toggle() {
        switch phase {
        case .idle: start()
        case .recording: stop()
        case .starting, .finishing: break
        }
    }

    func start() {
        guard phase == .idle, Self.isSupported else { return }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            onFailure?(L("Autorisez le micro", "Allow the microphone"))
            return
        }
        guard let model = Self.meetingModel() else {
            onFailure?(L("Il faut un modèle local (page Modèles)", "A local model is needed (Models page)"))
            return
        }
        phase = .starting
        warnings = []
        lines = []
        paragraphs = []
        open = [:]
        nextID = 1
        echoesDropped = 0
        stopReason = .user
        polishPausedUntil = .distantPast
        let engine = SpeechEngine.engine(for: model)
        self.engine = engine
        Task.detached(priority: .utility) {
            await engine.hold()
            try? await engine.ensureRunning()
        }

        // Le tap peut attendre la réponse de l'utilisateur à la demande
        // d'autorisation : jamais sur le fil principal.
        guard #available(macOS 14.4, *) else { return }
        let tap = SystemAudioTap()
        Task.detached(priority: .userInitiated) {
            do {
                try tap.start()
                await MainActor.run { self.didStartTap(tap, model: model) }
            } catch {
                Log.info("réunion : \(error.localizedDescription)")
                await MainActor.run { self.failStart(L("Son du Mac indisponible", "Mac audio unavailable")) }
            }
        }
    }

    @available(macOS 14.4, *)
    private func didStartTap(_ tap: SystemAudioTap, model: ModelInfo) {
        guard phase == .starting else { tap.stop(); return }
        let now = Date()
        let clock = ProcessInfo.processInfo.systemUptime
        self.clock = clock
        textLags = []
        do {
            let folder = try MeetingFolder.create(date: now, source: tap.sourceName)
            let meta = MeetingMeta(startedAt: now, endedAt: nil, duration: 0, source: tap.sourceName, model: model.id,
                                   words: 0, paragraphs: 0, recording: true)
            let transcript = try MeetingTranscript(folder: folder, meta: meta)
            let mic = try MeetingTrack(speaker: .me, url: folder.micURL, clock: clock)
            let system = try MeetingTrack(speaker: .them, url: folder.systemURL, clock: clock)
            let levels = self.levels
            tap.onSamples = { chunk, level in
                system.feed(chunk)
                levels.set(.them, level)
            }
            micSubscription = try MicrophoneHub.shared.subscribe { chunk, level in
                mic.feed(chunk)
                levels.set(.me, level)
            }
            self.folder = folder
            self.meta = meta
            self.transcript = transcript
            self.mic = mic
            self.system = system
            self.tapBox = tap
            self.source = tap.sourceName
            startedAt = now
            phase = .recording
            startLoops()
            Log.info("réunion démarrée : \(folder.name) (modèle \(model.id))")
        } catch {
            tap.stop()
            Log.info("réunion : démarrage impossible (\(error.localizedDescription))")
            failStart(L("Réunion impossible à démarrer", "Could not start the meeting"))
        }
    }

    private func failStart(_ message: String) {
        releaseCapture()
        if let folder, (folder.readParagraphs().isEmpty) { try? FileManager.default.trashItem(at: folder.url, resultingItemURL: nil) }
        folder = nil
        releaseEngine()
        phase = .idle
        onFailure?(message)
    }

    /// Arrête et garde tout. La fin (transcription, lissage, fichier) se fait derrière.
    func stop(reason: StopReason = .user) {
        guard phase == .recording else { return }
        stopReason = reason
        phase = .finishing
        tickLoop?.cancel()
        tickLoop = nil
        // Le dernier morceau de chaque piste, même sans pause.
        for track in [mic, system].compactMap({ $0 }) {
            track.padToNow()
            if let chunk = track.takeChunk(force: true) { jobs?.yield(.chunk(track.speaker, start: chunk.start, samples: chunk.samples)) }
        }
        releaseCapture()
        Log.info("réunion arrêtée (\(reason)), fin de la transcription…")
        Task { await finish() }
    }

    /// La croix : la réunion est abandonnée et son dossier part à la Corbeille
    /// (la confirmation, au-delà de 10 s, est demandée par le widget).
    func discard() {
        guard phase == .recording || phase == .starting else { return }
        let folder = self.folder
        tickLoop?.cancel()
        tickLoop = nil
        jobs?.finish()
        jobLoop?.cancel()
        polishLoop?.cancel()
        releaseCapture()
        transcript?.finish(meta: meta ?? Self.emptyMeta, paragraphs: [])
        if let folder { try? FileManager.default.trashItem(at: folder.url, resultingItemURL: nil) }
        Log.info("réunion abandonnée, dossier à la Corbeille")
        reset()
    }

    var elapsed: Double { startedAt.map { Date().timeIntervalSince($0) } ?? 0 }

    // MARK: Boucles

    private func startLoops() {
        let (stream, continuation) = AsyncStream<Job>.makeStream()
        jobs = continuation
        jobLoop = Task(priority: .utility) { [weak self] in
            for await job in stream {
                guard let self else { return }
                await self.handle(job)
            }
        }
        tickLoop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                self?.tick()
            }
        }
    }

    /// Quatre fois par seconde : découpe, garde-fous, niveaux, méta.
    private func tick() {
        guard phase == .recording, let mic, let system else { return }
        for track in [mic, system] {
            track.padToNow()
            while let chunk = track.takeChunk(force: false) {
                jobs?.yield(.chunk(track.speaker, start: chunk.start, samples: chunk.samples))
            }
        }
        let seconds = elapsed
        if seconds >= Prefs.shared.meetingMaxHours * 3600 { stop(reason: .maxDuration); return }
        if #available(macOS 14.4, *), let tap = tapBox as? SystemAudioTap, !tap.targetIsAlive {
            stop(reason: .appClosed); return
        }
        if Int(seconds * 4) % 120 == 0, let free = freeBytes(), free < Self.minFreeBytes {
            stop(reason: .diskFull); return
        }
        var w: Set<Warning> = []
        if Prefs.shared.meetingSilenceAlert {
            if mic.silentFor > Self.silentWarningSeconds { w.insert(.micSilent) }
            if system.silentFor > Self.silentWarningSeconds { w.insert(.systemSilent) }
        }
        if w != warnings { warnings = w }
        if Date().timeIntervalSince(lastMetaWrite) > 10 { writeMeta() }
    }

    private func freeBytes() -> Int64? {
        guard let folder else { return nil }
        let values = try? folder.url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    // MARK: Transcription (dans l'ordre, une file pour les deux pistes)

    private func handle(_ job: Job) async {
        switch job {
        case .chunk(let speaker, let start, let samples):
            await process(speaker, start: start, samples: samples)
        case .drain(let done):
            for speaker in [MeetingSpeaker.me, .them] {
                if let p = open[speaker] { await close(p) }
            }
            done.resume()
        }
    }

    private func process(_ speaker: MeetingSpeaker, start: Int, samples: [Float]) async {
        let rate = AudioRecorder.sampleRate
        let chunkStart = Double(start) / rate
        let chunkEnd = Double(start + samples.count) / rate
        var text = ""
        let verdict = SpeechGate.analyse(samples)
        if let range = verdict.range {
            text = await transcribe(samples, range: range)
        }

        guard verdict.range != nil else {
            // Une pause : le paragraphe ouvert se ferme après 1,5 s de silence.
            guard var p = open[speaker] else { return }
            p.audio += samples
            p.silence += chunkEnd - chunkStart
            p.end = max(p.end, chunkStart)
            if p.silence >= Self.paragraphPause { await close(p) } else { open[speaker] = p }
            return
        }

        var p = open[speaker] ?? OpenParagraph(id: takeID(), speaker: speaker,
                                                start: chunkStart + Double(verdict.range!.lowerBound) / rate,
                                                end: chunkEnd)
        p.audio += samples
        p.end = chunkEnd
        p.silence = 0
        if !text.isEmpty {
            p.texts.append(text)
            textLags.append(ProcessInfo.processInfo.systemUptime - clock - chunkEnd)
        }
        open[speaker] = p
        if !p.texts.isEmpty {
            showLive(p)
            if Date().timeIntervalSince(p.lastJournal) > 5 {
                transcript?.record(MeetingParagraph(id: p.id, speaker: speaker, start: p.start, end: p.end,
                                                    raw: p.liveText, text: p.liveText, polished: false, open: true))
                open[speaker]?.lastJournal = Date()
            }
        }
        if Double(p.audio.count) / rate >= Self.maxParagraphSeconds { await close(p) }
    }

    private func transcribe(_ samples: [Float], range: Range<Int>) async -> String {
        guard let engine else { return "" }
        do {
            let pieces = try await DictationController.transcribe(samples, range: range, engine: engine,
                                                                  language: Prefs.shared.effectiveLanguage, prompt: nil)
            return pieces.texts.joined(separator: " ")
        } catch {
            Log.info("réunion : morceau non transcrit (\(error.localizedDescription))")
            return ""
        }
    }

    private func takeID() -> Int {
        defer { nextID += 1 }
        return nextID
    }

    /// Paragraphe terminé : retranscrit d'un bloc, vérifié (écho), écrit, puis lissé.
    private func close(_ p: OpenParagraph) async {
        open[p.speaker] = nil
        var raw = p.liveText
        // Plusieurs morceaux : une seconde passe sur tout le paragraphe (30 s
        // en ~0,4 s) répare les mots coupés aux jointures.
        if p.texts.count > 1, let range = SpeechGate.analyse(p.audio).range {
            let whole = await transcribe(p.audio, range: range)
            if !whole.isEmpty { raw = whole }
        }
        raw = VocabularyStore.shared.snapshot.apply(to: raw).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { removeLine(p.id); return }
        let end = p.end - p.silence
        if p.speaker == .me, isEcho(raw, from: p.start, to: end) {
            echoesDropped += 1
            removeLine(p.id)
            Log.info("réunion : paragraphe du micro ignoré (écho du haut-parleur)")
            return
        }
        let paragraph = MeetingParagraph(id: p.id, speaker: p.speaker, start: p.start, end: max(p.start, end),
                                         raw: raw, text: raw, polished: false)
        paragraphs.append(paragraph)
        transcript?.record(paragraph)
        update(paragraph)
        enqueuePolish(paragraph)
    }

    /// Le micro a ré-enregistré ce que disaient les haut-parleurs : la plupart
    /// de ses mots sont dans ce que « Eux » disait au même moment.
    private func isEcho(_ text: String, from start: Double, to end: Double) -> Bool {
        let mine = Self.wordSet(text)
        guard mine.count >= 3 else { return false }
        var theirs = ""
        for q in paragraphs where q.speaker == .them && q.end >= start - 1 && q.start <= end + 1 { theirs += " " + q.raw }
        if let q = open[.them], q.end >= start - 1, q.start <= end + 1 { theirs += " " + q.liveText }
        let other = Self.wordSet(theirs)
        guard !other.isEmpty else { return false }
        return Double(mine.intersection(other).count) / Double(mine.count) >= 0.6
    }

    nonisolated static func wordSet(_ text: String) -> Set<String> {
        Set(text.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map { TranscriptFilter.normalize(String($0)) }
            .filter { !$0.isEmpty })
    }

    // MARK: Lissage (un paragraphe à la fois)

    private func enqueuePolish(_ p: MeetingParagraph) {
        guard Prefs.polishWanted else {
            transcript?.appendToMarkdown(p)
            return
        }
        polishQueue.append(p)
        guard polishLoop == nil else { return }
        polishLoop = Task { [weak self] in
            while let self, !self.polishQueue.isEmpty {
                let next = self.polishQueue.removeFirst()
                // En retard (réseau lent) : on écrit le brut tout de suite, la
                // passe de fin rattrapera. Le fichier ne prend jamais de retard.
                let skip = self.polishQueue.count > 3 || Date() < self.polishPausedUntil
                await self.polish(next, attempt: !skip)
            }
            self?.polishLoop = nil
        }
    }

    private func polish(_ p: MeetingParagraph, attempt: Bool) async {
        var p = p
        if attempt {
            let vocabulary = VocabularyStore.shared.snapshot
            if let out = await Polisher.polish(p.raw, language: Prefs.shared.effectiveLanguage, spelling: vocabulary.spellingList) {
                p.text = vocabulary.apply(to: out)
                p.polished = true
            } else {
                polishPausedUntil = Date().addingTimeInterval(30)
            }
        }
        if p.polished {
            replace(p)
            transcript?.record(p)
        }
        transcript?.appendToMarkdown(p)
    }

    /// Fin : tout ce qui reste est transcrit, les paragraphes fermés, puis une
    /// passe de lissage rattrape les « non nettoyés » (2 min au plus).
    private func finish() async {
        await withCheckedContinuation { done in
            if let jobs { jobs.yield(.drain(done)) } else { done.resume() }
        }
        jobs?.finish()
        await jobLoop?.value
        while polishLoop != nil { try? await Task.sleep(for: .milliseconds(100)) }

        if Prefs.polishWanted {
            let deadline = Date().addingTimeInterval(120)
            for p in paragraphs where !p.polished {
                guard Date() < deadline else { break }
                let vocabulary = VocabularyStore.shared.snapshot
                guard let out = await Polisher.polish(p.raw, language: Prefs.shared.effectiveLanguage,
                                                      spelling: vocabulary.spellingList) else { break }
                var fixed = p
                fixed.text = vocabulary.apply(to: out)
                fixed.polished = true
                replace(fixed)
                transcript?.record(fixed)
            }
        }

        guard let folder, var meta else { reset(); return }
        meta.recording = false
        meta.endedAt = Date()
        meta.duration = max(mic?.seconds ?? 0, system?.seconds ?? 0, elapsed)
        meta.paragraphs = paragraphs.count
        meta.words = paragraphs.reduce(0) { $0 + $1.words }
        let ordered = paragraphs.sorted { $0.start == $1.start ? $0.id < $1.id : $0.start < $1.start }
        transcript?.finish(meta: meta, paragraphs: ordered)
        if !Prefs.shared.meetingKeepAudio {
            for url in [folder.micURL, folder.systemURL] { try? FileManager.default.trashItem(at: url, resultingItemURL: nil) }
        }
        let text = MeetingFiles.markdown(meta: meta, paragraphs: ordered)
        Log.info(String(format: "réunion terminée : %@, %.0f s, %d paragraphes, %d mots, %d échos ignorés, texte %.2f s après la pause en moyenne (max %.2f s)",
                        folder.name, meta.duration, meta.paragraphs, meta.words, echoesDropped,
                        textLags.isEmpty ? 0 : textLags.reduce(0, +) / Double(textLags.count), textLags.max() ?? 0))
        let reason = stopReason
        reset()
        onFinished?(folder, text, reason)
    }

    private func reset() {
        releaseEngine()
        jobs = nil
        jobLoop = nil
        polishLoop = nil
        polishQueue = []
        transcript = nil
        mic = nil
        system = nil
        meta = nil
        folder = nil
        startedAt = nil
        source = ""
        warnings = []
        levels.reset()
        phase = .idle
    }

    /// Coupe le micro et le son du Mac, ferme les deux WAV.
    private func releaseCapture() {
        if let micSubscription { MicrophoneHub.shared.unsubscribe(micSubscription) }
        micSubscription = nil
        if #available(macOS 14.4, *), let tap = tapBox as? SystemAudioTap { tap.stop() }
        tapBox = nil
        mic?.close()
        system?.close()
    }

    private func releaseEngine() {
        guard let engine else { return }
        self.engine = nil
        Task.detached { await engine.unhold(idleAfter: Prefs.idleSeconds) }
    }

    private func writeMeta() {
        guard var meta else { return }
        meta.duration = elapsed
        meta.paragraphs = paragraphs.count
        meta.words = paragraphs.reduce(0) { $0 + $1.words }
        self.meta = meta
        transcript?.updateMeta(meta)
        lastMetaWrite = Date()
    }

    private static let emptyMeta = MeetingMeta(startedAt: Date(), endedAt: Date(), duration: 0, source: "", model: "",
                                               words: 0, paragraphs: 0, recording: false)

    // MARK: Lignes du widget (la fin seulement)

    private func showLive(_ p: OpenParagraph) {
        let line = Line(id: p.id, speaker: p.speaker, text: p.liveText, open: true, polished: false)
        if let i = lines.lastIndex(where: { $0.id == p.id }) { lines[i] = line } else { appendLine(line) }
    }

    private func update(_ p: MeetingParagraph) {
        let line = Line(id: p.id, speaker: p.speaker, text: p.text, open: false, polished: p.polished)
        if let i = lines.lastIndex(where: { $0.id == p.id }) { lines[i] = line } else { appendLine(line) }
    }

    private func replace(_ p: MeetingParagraph) {
        if let i = paragraphs.lastIndex(where: { $0.id == p.id }) { paragraphs[i] = p }
        if let i = lines.lastIndex(where: { $0.id == p.id }) {
            lines[i].text = p.text
            lines[i].polished = p.polished
        }
    }

    private func appendLine(_ line: Line) {
        lines.append(line)
        if lines.count > Self.maxLiveLines { lines.removeFirst(lines.count - Self.maxLiveLines) }
    }

    private func removeLine(_ id: Int) { lines.removeAll { $0.id == id } }

    // MARK: Modèle

    /// Le son ne quitte jamais le Mac : un modèle **local**, Parakeet de
    /// préférence (30 s en 0,4 s), sinon le Whisper local installé.
    static func meetingModel() -> ModelInfo? {
        let active = ModelStore.active
        if active.family == .parakeet, ModelLocation.isInstalled(active) { return active }
        if let parakeet = ModelCatalog.local.first(where: { $0.family == .parakeet && ModelLocation.isInstalled($0) }) {
            return parakeet
        }
        if active.family == .whisper, ModelLocation.isInstalled(active) { return active }
        return ModelCatalog.local.first { ModelLocation.isInstalled($0) }
    }
}

/// Les deux vumètres, en **nombre de barres allumées** (0…5) : publiés au plus
/// dix fois par seconde, et seulement quand une barre s'allume ou s'éteint.
/// (Publier le niveau brut redessinait le widget sans arrêt : 27 % de processeur.)
@MainActor
final class MeetingLevels: ObservableObject {
    nonisolated static let bars = 5
    @Published private(set) var me = 0
    @Published private(set) var them = 0
    private nonisolated(unsafe) var pending: (me: Float, them: Float) = (0, 0)
    private nonisolated(unsafe) var scheduled = false
    private let lock = NSLock()

    /// Depuis le fil audio : on garde le maximum, publié au prochain passage.
    nonisolated func set(_ speaker: MeetingSpeaker, _ level: Float) {
        lock.lock()
        if speaker == .me { pending.me = max(pending.me, level) } else { pending.them = max(pending.them, level) }
        let needs = !scheduled
        scheduled = true
        lock.unlock()
        guard needs else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            MainActor.assumeIsolated { self?.publish() }
        }
    }

    nonisolated static func bars(_ level: Float) -> Int {
        // Même échelle que les barres de la pastille (0 = pièce calme).
        min(bars, Int((level * Float(bars)).rounded(.up)))
    }

    private func publish() {
        lock.lock()
        let p = pending
        pending = (0, 0)
        scheduled = false
        lock.unlock()
        let m = Self.bars(p.me), t = Self.bars(p.them)
        if m != me { me = m }
        if t != them { them = t }
    }

    func reset() { me = 0; them = 0 }
}

/// Une piste : le WAV sur le disque, et les échantillons pas encore découpés
/// (deux secondes au plus en mémoire).
///
/// L'horloge commune est celle du Mac : quand une source se tait vraiment (le
/// son du Mac ne livre **rien** quand aucune app ne joue), la piste est
/// complétée par du silence pour que « Moi » et « Eux » restent alignés.
final class MeetingTrack: @unchecked Sendable {
    let speaker: MeetingSpeaker
    private let writer: WavFileWriter
    private let clock: TimeInterval
    private let lock = NSLock()
    private var pending: [Float] = []
    private var pendingStart = 0
    private var written = 0
    private var lastSignal: TimeInterval

    /// Au-dessus de ce niveau (≈ −52 dB), la piste « entend » quelque chose.
    static let signalFloor: Float = 0.0025
    static let maxLag: Double = 0.5

    init(speaker: MeetingSpeaker, url: URL, clock: TimeInterval) throws {
        self.speaker = speaker
        self.clock = clock
        lastSignal = clock
        writer = try WavFileWriter(url: url)
        pending.reserveCapacity(Int(AudioRecorder.sampleRate * 3))
    }

    /// Depuis le fil audio.
    func feed(_ chunk: UnsafeBufferPointer<Float>) {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock(); defer { lock.unlock() }
        let expectedEnd = Int((now - clock) * AudioRecorder.sampleRate)
        let gap = expectedEnd - chunk.count - written
        if Double(gap) > Self.maxLag * AudioRecorder.sampleRate { appendSilence(gap) }
        writer.append(chunk)
        pending.append(contentsOf: chunk)
        written += chunk.count
        if chunk.contains(where: { abs($0) > Self.signalFloor }) { lastSignal = now }
    }

    /// Rien reçu depuis un moment : du silence jusqu'à maintenant.
    func padToNow() {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock(); defer { lock.unlock() }
        let gap = Int((now - clock) * AudioRecorder.sampleRate) - written
        if Double(gap) > Self.maxLag * AudioRecorder.sampleRate { appendSilence(gap) }
    }

    private func appendSilence(_ count: Int) {
        let zeros = [Float](repeating: 0, count: count)
        zeros.withUnsafeBufferPointer { writer.append($0) }
        pending.append(contentsOf: zeros)
        written += count
    }

    /// Le prochain morceau à transcrire, s'il y en a un (voir `MeetingSegmenter`).
    func takeChunk(force: Bool) -> (start: Int, samples: [Float])? {
        lock.lock(); defer { lock.unlock() }
        let cut = force ? (pending.isEmpty ? nil : pending.count) : MeetingSegmenter.cut(pending)
        guard let cut, cut > 0 else { return nil }
        let chunk = Array(pending[0..<cut])
        let start = pendingStart
        pending.removeFirst(cut)
        pendingStart += cut
        return (start, chunk)
    }

    var silentFor: Double {
        lock.lock(); defer { lock.unlock() }
        return ProcessInfo.processInfo.systemUptime - lastSignal
    }

    var seconds: Double { Double(writer.sampleCount) / AudioRecorder.sampleRate }

    func close() { writer.close() }
}

/// Où couper le flux d'une piste. Pur et testable.
enum MeetingSegmenter {
    static let minSeconds = 1.0
    static let maxSeconds = 2.0
    static let window = 0.25

    /// Indice de coupe dans `samples` (les échantillons pas encore découpés), ou `nil` :
    /// - moins d'1 s : on attend ;
    /// - le dernier quart de seconde est calme (une micro-pause) : on coupe au
    ///   milieu de ce calme ;
    /// - 2 s sans respirer : coupe forcée dans les 0,25 s les plus calmes entre 1 et 2 s.
    static func cut(_ samples: [Float], sampleRate: Double = AudioRecorder.sampleRate) -> Int? {
        let count = samples.count
        let minLen = Int(minSeconds * sampleRate)
        guard count >= minLen else { return nil }
        let w = Int(window * sampleRate)
        let hop = Int(0.05 * sampleRate)
        var peak: Float = 0
        var start = 0
        while start + w <= count {
            peak = max(peak, rms(samples, start, w))
            start += hop
        }
        let trailing = rms(samples, count - w, w)
        if trailing < max(0.004, peak * 0.2) { return count - w / 2 }
        let maxLen = Int(maxSeconds * sampleRate)
        if count >= maxLen { return SpeechGate.quietestPoint(in: samples, from: minLen, to: maxLen, sampleRate: sampleRate) }
        return nil
    }

    static func rms(_ samples: [Float], _ start: Int, _ length: Int) -> Float {
        guard length > 0, start >= 0, start + length <= samples.count else { return 0 }
        var sum: Float = 0
        samples.withUnsafeBufferPointer { p in
            for i in start..<(start + length) { sum += p[i] * p[i] }
        }
        return (sum / Float(length)).squareRoot()
    }
}

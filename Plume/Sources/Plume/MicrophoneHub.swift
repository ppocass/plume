import AVFoundation
import Foundation

/// **Le seul micro de Plume.** Un producteur, plusieurs abonnés : la dictée et
/// la réunion lisent le même flux au lieu d'ouvrir chacune un `AVAudioEngine`
/// sur le même périphérique (deux moteurs sur un micro, c'est la bagarre de
/// format déjà payée avec un assistant vocal qui ouvrait l'entrée avec
/// l'anti-écho). Le micro s'ouvre au premier abonné et se ferme au dernier :
/// rien n'écoute entre deux usages.
///
/// Tout sort en **16 kHz mono** (`AudioRecorder.sampleRate`), sans traitement
/// de la voix (ni AEC ni AGC : un AGC peut baisser le gain matériel du micro et
/// le laisser bas après coup ; en visio, c'est l'app de visio qui fait l'AEC).
///
/// Si le périphérique change de format en cours de route (une autre app ouvre
/// le micro avec l'anti-écho, un casque se branche…), macOS envoie
/// `AVAudioEngineConfigurationChange` et arrête le moteur : on le relance avec
/// le nouveau format. Sans ça, une réunion de deux heures finirait sourde.
final class MicrophoneHub: @unchecked Sendable {
    static let shared = MicrophoneHub()

    /// Appelé sur le fil audio avec chaque morceau converti et son niveau (0…1).
    /// Doit rendre la main vite : copier, pas calculer.
    typealias Handler = @Sendable (_ samples: UnsafeBufferPointer<Float>, _ level: Float) -> Void

    enum HubError: LocalizedError {
        case noInput
        var errorDescription: String? { L("Aucun micro disponible", "No microphone available") }
    }

    private let lock = NSLock()
    private var handlers: [UUID: Handler] = [:]
    private var engine: AVAudioEngine?
    private var resampler: MonoResampler?
    private var configObserver: NSObjectProtocol?
    /// Silence numérique (que des zéros) : le moteur est ouvert mais n'entend
    /// rien (coreaudiod en panne, micro coupé matériellement). Dit une fois.
    private var zeroSince: TimeInterval?
    private var zeroReported = false

    /// S'abonne au micro (l'ouvre s'il ne l'est pas). À appeler sur le fil principal.
    func subscribe(_ handler: @escaping Handler) throws -> UUID {
        let id = UUID()
        lock.lock()
        let wasRunning = engine != nil || testTimer != nil
        handlers[id] = handler
        lock.unlock()
        if !wasRunning {
            do {
                try startEngine()
            } catch {
                lock.lock(); handlers[id] = nil; lock.unlock()
                throw error
            }
        }
        return id
    }

    /// Se désabonne ; le micro se ferme avec le dernier abonné.
    func unsubscribe(_ id: UUID) {
        lock.lock()
        handlers[id] = nil
        let empty = handlers.isEmpty
        lock.unlock()
        if empty { stopEngine() }
    }

    // MARK: Moteur

    private func startEngine() throws {
        if let testSignal {
            startTestSignal(testSignal)
            return
        }
        let engine = AVAudioEngine()
        let input = engine.inputNode
        // Micro choisi dans les réglages (sinon celui de macOS). S'il n'est
        // plus branché, on reste sur celui de macOS.
        if let uid = UserDefaults.standard.string(forKey: "microphoneUID"), !uid.isEmpty,
           var device = AudioDevices.deviceID(forUID: uid), let unit = input.audioUnit {
            let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                              &device, UInt32(MemoryLayout<AudioDeviceID>.size))
            if status != noErr { Log.info("micro choisi indisponible (\(status)) : celui de macOS") }
        }
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0,
              let resampler = MonoResampler(from: format) else { throw HubError.noInput }

        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            self?.deliver(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
        let observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange,
                                                              object: engine, queue: .main) { [weak self] _ in
            self?.restartAfterConfigurationChange()
        }
        lock.lock()
        self.engine = engine
        self.resampler = resampler
        self.configObserver = observer
        zeroSince = nil
        zeroReported = false
        lock.unlock()
        Log.info("micro ouvert (\(Int(format.sampleRate)) Hz, \(format.channelCount) canal/canaux)")
    }

    private func stopEngine() {
        testTimer?.cancel()
        testTimer = nil
        lock.lock()
        let engine = self.engine
        let observer = configObserver
        self.engine = nil
        resampler = nil
        configObserver = nil
        lock.unlock()
        if let observer { NotificationCenter.default.removeObserver(observer) }
        guard let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    /// Le format du périphérique a changé : macOS a arrêté le moteur. On le
    /// rouvre pour les abonnés en cours (ils ne voient qu'un petit trou).
    private func restartAfterConfigurationChange() {
        lock.lock()
        let stillWanted = !handlers.isEmpty
        lock.unlock()
        stopEngine()
        guard stillWanted else { return }
        do {
            try startEngine()
            Log.info("micro relancé après un changement de configuration audio")
        } catch {
            // On réessaie une fois, une seconde plus tard (le périphérique est
            // parfois encore en train de basculer).
            Log.info("relance du micro impossible (\(error.localizedDescription)), nouvel essai dans 1 s")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                guard let self else { return }
                self.lock.lock()
                let wanted = !self.handlers.isEmpty && self.engine == nil
                self.lock.unlock()
                guard wanted else { return }
                do { try self.startEngine() } catch { Log.info("micro perdu : \(error.localizedDescription)") }
            }
        }
    }

    // MARK: Autotest

    private var testSignal: [Float]?
    private var testTimer: DispatchSourceTimer?

    /// **Autotest seulement** (`--meeting-selftest` avec `PLUME_FAKE_MIC`) : le
    /// micro est remplacé par ce son (16 kHz mono), livré en temps réel et en
    /// boucle, par morceaux de 20 ms — exactement comme le vrai.
    func replaceWithTestSignal(_ samples: [Float]) {
        testSignal = samples.isEmpty ? nil : samples
    }

    private func startTestSignal(_ signal: [Float]) {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "plume.mic.test", qos: .userInitiated))
        let step = Int(AudioRecorder.sampleRate * 0.02)
        let begin = ProcessInfo.processInfo.systemUptime
        var position = 0
        timer.schedule(deadline: .now(), repeating: .milliseconds(20))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            // Rattrape l'horloge réelle (un minuteur peut glisser).
            let due = Int((ProcessInfo.processInfo.systemUptime - begin) * AudioRecorder.sampleRate)
            self.lock.lock()
            let targets = Array(self.handlers.values)
            self.lock.unlock()
            while position + step <= due {
                var chunk = [Float](repeating: 0, count: step)
                for i in 0..<step { chunk[i] = signal[(position + i) % signal.count] }
                position += step
                chunk.withUnsafeBufferPointer { p in
                    let level = MonoResampler.level(of: p)
                    for handler in targets { handler(p, level) }
                }
            }
        }
        timer.resume()
        testTimer = timer
        Log.info("micro remplacé par un son de test (\(signal.count / Int(AudioRecorder.sampleRate)) s en boucle)")
    }

    // MARK: Fil audio

    private func deliver(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let resampler = self.resampler
        let targets = Array(handlers.values)
        lock.unlock()
        guard let resampler, !targets.isEmpty else { return }
        resampler.convert(buffer) { chunk in
            let level = MonoResampler.level(of: chunk)
            if noteDigitalSilence(chunk) {
                DispatchQueue.main.async {
                    Log.info("micro ouvert mais silence numérique depuis 5 s (coreaudiod ou micro coupé ?)")
                }
            }
            for handler in targets { handler(chunk, level) }
        }
    }

    /// Vrai une seule fois, quand le micro ne rend que des zéros depuis 5 s
    /// (le message part sur le fil principal : rien d'autre ne s'écrit d'ici).
    private func noteDigitalSilence(_ chunk: UnsafeBufferPointer<Float>) -> Bool {
        let silent = !chunk.contains(where: { $0 != 0 })
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock(); defer { lock.unlock() }
        guard silent else { zeroSince = nil; return false }
        if zeroSince == nil { zeroSince = now }
        guard !zeroReported, let since = zeroSince, now - since > 5 else { return false }
        zeroReported = true
        return true
    }
}

/// Convertit un flux audio quelconque en **16 kHz mono Float32**, morceau par
/// morceau (le convertisseur garde son état d'un morceau à l'autre : pas de
/// clic aux jointures). Les canaux sont mélangés, pas seulement le premier gardé.
final class MonoResampler: @unchecked Sendable {
    static let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: AudioRecorder.sampleRate,
                                      channels: 1, interleaved: false)!
    private let converter: AVAudioConverter

    init?(from format: AVAudioFormat) {
        guard let converter = AVAudioConverter(from: format, to: Self.target) else { return nil }
        converter.downmix = true
        self.converter = converter
    }

    /// Convertit `buffer` et passe le résultat à `body` (mémoire valable
    /// seulement pendant l'appel).
    func convert(_ buffer: AVAudioPCMBuffer, _ body: (UnsafeBufferPointer<Float>) -> Void) {
        guard buffer.frameLength > 0 else { return }
        let ratio = Self.target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 64)
        guard let out = AVAudioPCMBuffer(pcmFormat: Self.target, frameCapacity: capacity) else { return }
        var given = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if given {
                status.pointee = .noDataNow
                return nil
            }
            given = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let data = out.floatChannelData?[0], out.frameLength > 0 else { return }
        body(UnsafeBufferPointer(start: data, count: Int(out.frameLength)))
    }

    /// Niveau pour les barres : −55 dB (pièce calme) → 0 ; −15 dB (voix forte) → 1.
    static func level(of chunk: UnsafeBufferPointer<Float>) -> Float {
        guard !chunk.isEmpty else { return 0 }
        var sum: Float = 0
        for v in chunk { sum += v * v }
        let rms = (sum / Float(chunk.count)).squareRoot()
        let db = 20 * log10(max(rms, 1e-7))
        return min(1, max(0, (db + 55) / 40))
    }
}

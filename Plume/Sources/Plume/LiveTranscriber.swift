import Foundation

/// Transcription **au fil de l'eau** pour Whisper : toutes les 0,5 s, dès que
/// plus de 8 s n'ont pas encore été transcrites, on coupe dans le creux de voix
/// le plus calme entre 3 et 8 s et on envoie ce morceau à Whisper pendant qu'on
/// continue de parler. À la fin, il ne reste que la dernière tranche : 20 s de
/// dictée → ~1,2 s d'attente au lieu de ~3,6 s sur un M1.
@MainActor
final class LiveTranscriber {
    struct Result: Sendable {
        let texts: [String]
        /// Indice (dans l'enregistrement) jusqu'où c'est déjà transcrit.
        let cut: Int
        let chunks: Int
    }

    private var texts: [String] = []
    private var cut = 0
    private var chunks = 0
    private var stopping = false
    private var failed = false
    private var loop: Task<Void, Never>?

    func start(recorder: AudioRecorder, engine: SpeechEngine, language: DictationLanguage, prompt: String?) {
        let rate = AudioRecorder.sampleRate
        let maxLen = Int(SpeechGate.maxChunkSeconds * rate)
        let minLen = Int(3 * rate)
        let margin = Int(0.5 * rate)
        loop = Task { [weak self] in
            while true {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self, !self.stopping, !self.failed else { return }
                let start = self.cut
                guard recorder.sampleCount - start > maxLen + margin else { continue }
                let window = recorder.copy(from: start, to: start + maxLen)
                let cutLocal = SpeechGate.quietestPoint(in: window, from: minLen, to: maxLen)
                let segment = Array(window[0..<cutLocal])
                self.cut = start + cutLocal
                self.chunks += 1
                guard let range = SpeechGate.analyse(segment).range else { continue }
                do {
                    let t0 = Date()
                    let piece = try await DictationController.transcribe(segment, range: range, engine: engine,
                                                                         language: language, prompt: prompt)
                    self.texts += piece.texts
                    Log.info(String(format: "au fil de l'eau : %.1f s transcrites en %.2f s (coupure à %.1f s)",
                                    Double(segment.count) / rate, Date().timeIntervalSince(t0), Double(self.cut) / rate))
                } catch {
                    // En cas d'échec, la fin reprend tout depuis le début (rien n'est perdu).
                    Log.info("transcription au fil de l'eau interrompue : \(error.localizedDescription)")
                    self.failed = true
                }
            }
        }
    }

    /// Fin de la dictée : attend le morceau en cours et rend ce qui est fait.
    func finishLive() async -> Result? {
        stopping = true
        await loop?.value
        if failed { return nil }
        return Result(texts: texts, cut: cut, chunks: chunks)
    }

    func abandon() {
        stopping = true
        loop?.cancel()
    }
}

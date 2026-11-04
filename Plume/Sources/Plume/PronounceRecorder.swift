import AVFoundation
import Foundation
import SwiftUI

/// « Enregistrer la phonétique » : on prononce le mot, Plume l'écrit.
///
/// Le geste est celui que Pierre a demandé le 04/11 : un bouton dans le menu de
/// chaque mot (et dans sa fiche), on parle, et le texte entendu vient se poser
/// dans la liste des graphies. C'est **le même moteur que la dictée** — donc le
/// résultat dépend de ce que la machine entend réellement, ce qui est
/// précisément le but : c'est la prononciation de Pierre qui compte, pas une
/// transcription idéale.
///
/// ⚠️ **Pas de moteur « prompté » ici.** On lance la transcription avec un
/// `prompt` **vide** : si on donnait le mot correct (DeepSeek), Whisper
/// l'écrirait lui-même et on n'apprendrait rien sur la façon dont Pierre
/// prononce. On veut la graphie **spontanée** du moteur.
@MainActor
final class PronounceRecorder: ObservableObject {
    static let shared = PronounceRecorder()

    enum State: Equatable {
        case idle
        case listening
        case working
        /// Le résultat, prêt à être ajouté au mot.
        case got(String)
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    /// Le mot auquel le prochain résultat s'applique.
    private(set) var targetWord: String = ""
    /// Appelé quand une graphie a été trouvée (pour l'ajouter au bon mot).
    var onResult: ((String) -> Void)?

    private let recorder = AudioRecorder()
    private var timeout: Task<Void, Never>?

    /// Une capture dure au plus `maxSeconds` : on prononce un mot, pas une phrase.
    static let maxSeconds: Double = 6

    var isBusy: Bool {
        if case .listening = state { return true }
        if case .working = state { return true }
        return false
    }

    func start(for word: String) {
        guard !isBusy else { return }
        targetWord = word
        state = .listening
        do {
            try recorder.start()
        } catch {
            state = .failed(L("Micro indisponible", "Microphone unavailable"))
            Log.info("phonétique : micro indisponible (\(error.localizedDescription))")
            return
        }
        // Le modèle se charge pendant qu'on parle.
        let model = ModelStore.active
        Task.detached { try? await SpeechEngine.engine(for: model).ensureRunning() }

        // Garde-fou : si on oublie d'arrêter, on coupe tout seul.
        timeout?.cancel()
        timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.maxSeconds))
            guard !Task.isCancelled, let self, case .listening = self.state else { return }
            self.finish()
        }
    }

    /// Arrête l'écoute et transcrit ce qui a été dit.
    func finish() {
        guard case .listening = state else { return }
        timeout?.cancel()
        timeout = nil
        let samples = recorder.stop()
        let verdict = SpeechGate.analyse(samples)
        guard let range = verdict.range else {
            Log.info("phonétique : rien entendu (\(verdict.reason))")
            state = .failed(L("Rien entendu — réessayez", "Nothing heard — try again"))
            return
        }
        state = .working
        let language = Prefs.shared.effectiveLanguage.rawValue
        let engine = SpeechEngine.shared
        let wav = SpeechGate.wav(samples[range])

        Task { [weak self] in
            guard let self else { return }
            do {
                let text = try await engine.transcribe(wav: wav, language: language, prompt: nil)
                let clean = self.cleanHeard(text)
                await MainActor.run {
                    guard !clean.isEmpty else {
                        self.state = .failed(L("Rien entendu — réessayez", "Nothing heard — try again"))
                        return
                    }
                    self.state = .got(clean)
                    self.onResult?(clean)
                    Log.info("phonétique : « \(clean) » pour \(self.targetWord)")
                }
            } catch {
                await MainActor.run {
                    self.state = .failed(L("Moteur indisponible", "Engine unavailable"))
                    Log.info("phonétique : échec (\(error.localizedDescription))")
                }
            }
            await SpeechEngine.shared.scheduleIdleRelease(after: Prefs.idleSeconds)
        }
    }

    /// Très court nettoyage : les moteurs ajoutent parfois un point ou une
    /// majuscule initiale. On veut une **graphie**, pas une phrase.
    func cleanHeard(_ text: String) -> String {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Ponctuation et guillemets des deux côtés : les moteurs en ajoutent
        // souvent (« Gexilax. », « "Dipsik" »). On boucle, car ils se cumulent
        // (« « Gexilax. » »).
        let junk = CharacterSet(charactersIn: ".,;:!?…\"«»\u{201C}\u{201D}\u{2018}\u{2019}'`")
        var before = ""
        while before != t {
            before = t
            t = t.trimmingCharacters(in: junk)
            t = t.trimmingCharacters(in: .whitespaces)
        }
        return t
    }

    func cancel() {
        timeout?.cancel()
        timeout = nil
        if case .listening = state { _ = recorder.stop() }
        state = .idle
    }

    func reset() { state = .idle }
}

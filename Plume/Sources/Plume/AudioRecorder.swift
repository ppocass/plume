import AVFoundation
import Foundation

/// Le micro, seulement pendant une dictée : `start()` à l'appui, `stop()` à la
/// fin. Rien n'écoute entre deux dictées (pas d'icône orange permanente).
///
/// Le micro lui-même appartient à `MicrophoneHub` : si une réunion
/// l'a déjà ouvert, la dictée s'abonne au même flux au lieu d'en ouvrir un
/// second. Tout arrive déjà en **16 kHz mono** (ce que mangent les moteurs).
final class AudioRecorder: @unchecked Sendable {
    static let sampleRate: Double = 16_000

    /// Niveau du son (0…1), appelé depuis le fil audio ~20 fois par seconde.
    var onLevel: (@Sendable (Float) -> Void)?

    private let lock = NSLock()
    private var samples: [Float] = []
    private var subscription: UUID?

    func start() throws {
        lock.lock()
        samples.removeAll(keepingCapacity: true)
        samples.reserveCapacity(Int(Self.sampleRate * 60))
        lock.unlock()
        subscription = try MicrophoneHub.shared.subscribe { [weak self] chunk, level in
            guard let self else { return }
            self.onLevel?(level)
            self.lock.lock()
            self.samples.append(contentsOf: chunk)
            self.lock.unlock()
        }
    }

    /// Arrête l'écoute et rend tout l'enregistrement (16 kHz mono).
    func stop() -> [Float] {
        if let subscription { MicrophoneHub.shared.unsubscribe(subscription) }
        subscription = nil
        lock.lock(); defer { lock.unlock() }
        let out = samples
        samples = []
        return out
    }

    var isRunning: Bool { subscription != nil }

    /// Nombre d'échantillons déjà enregistrés (pendant l'enregistrement).
    var sampleCount: Int {
        lock.lock(); defer { lock.unlock() }
        return samples.count
    }

    /// Copie d'une partie de l'enregistrement en cours (transcription au fil de l'eau).
    func copy(from start: Int, to end: Int) -> [Float] {
        lock.lock(); defer { lock.unlock() }
        let e = min(end, samples.count)
        guard start < e else { return [] }
        return Array(samples[start..<e])
    }
}

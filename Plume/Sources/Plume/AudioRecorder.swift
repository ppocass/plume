import AVFoundation
import Foundation

/// Le micro, seulement pendant une dictée : `start()` à l'appui, `stop()` à la
/// fin. Rien n'écoute entre deux dictées (pas d'icône orange permanente).
///
/// Tout est converti à la volée en **16 kHz mono** (ce que mange Whisper).
/// Pas de traitement de la voix (AEC/AGC) : un AGC peut baisser le gain
/// matériel du micro et le laisser bas après coup.
final class AudioRecorder: @unchecked Sendable {
    static let sampleRate: Double = 16_000

    /// Niveau du son (0…1), appelé depuis le fil audio ~20 fois par seconde.
    var onLevel: (@Sendable (Float) -> Void)?

    private var engine: AVAudioEngine?
    private var converter: AVAudioConverter?
    private let target = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                       sampleRate: AudioRecorder.sampleRate,
                                       channels: 1, interleaved: false)!
    private let lock = NSLock()
    private var samples: [Float] = []

    enum RecorderError: LocalizedError {
        case noInput
        var errorDescription: String? { "Aucun micro disponible" }
    }

    func start() throws {
        lock.lock(); samples.removeAll(keepingCapacity: true); lock.unlock()

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw RecorderError.noInput }
        converter = AVAudioConverter(from: format, to: target)
        samples.reserveCapacity(Int(Self.sampleRate * 60))

        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            self?.process(buffer)
        }
        engine.prepare()
        try engine.start()
        self.engine = engine
        Log.info("micro ouvert (\(Int(format.sampleRate)) Hz, \(format.channelCount) canal/canaux)")
    }

    /// Arrête le micro et rend tout l'enregistrement (16 kHz mono).
    func stop() -> [Float] {
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
        converter = nil
        lock.lock(); defer { lock.unlock() }
        let out = samples
        samples = []
        return out
    }

    var isRunning: Bool { engine?.isRunning ?? false }

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

    // MARK: Fil audio

    private func process(_ buffer: AVAudioPCMBuffer) {
        if let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 {
            var sum: Float = 0
            let n = Int(buffer.frameLength)
            for i in 0..<n { sum += channel[i] * channel[i] }
            let rms = (sum / Float(n)).squareRoot()
            // −55 dB (pièce calme) → 0 ; −15 dB (voix forte) → 1.
            let db = 20 * log10(max(rms, 1e-7))
            onLevel?(min(1, max(0, (db + 55) / 40)))
        }

        guard let converter else { return }
        let ratio = Self.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 64)
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
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
        let chunk = UnsafeBufferPointer(start: data, count: Int(out.frameLength))
        lock.lock()
        samples.append(contentsOf: chunk)
        lock.unlock()
    }
}

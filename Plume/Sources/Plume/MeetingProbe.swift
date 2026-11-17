import Foundation

/// Prototype (étape 0) : `Plume --meeting-probe <secondes> <dossier>` enregistre
/// le micro et le son du Mac dans deux WAV et écrit un petit rapport.
enum MeetingProbe {
    static func run(seconds: Double, folder: String) async -> Int32 {
        let dir = URL(fileURLWithPath: folder, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var report = ""
        func say(_ s: String) { report += s + "\n"; try? report.write(to: dir.appendingPathComponent("rapport.txt"), atomically: true, encoding: .utf8) }
        guard #available(macOS 14.4, *) else { say("macOS trop ancien"); return 2 }
        do {
            let mic = try WavFileWriter(url: dir.appendingPathComponent("moi.wav"))
            let sys = try WavFileWriter(url: dir.appendingPathComponent("eux.wav"))
            let micPeak = Peak(), sysPeak = Peak()
            let token = try MicrophoneHub.shared.subscribe { chunk, level in mic.append(chunk); micPeak.note(level) }
            let tap = SystemAudioTap()
            tap.onSamples = { chunk, level in sys.append(chunk); sysPeak.note(level) }
            try tap.start()
            say("source : \(tap.sourceName)")
            let t0 = Date()
            while Date().timeIntervalSince(t0) < seconds {
                try? await Task.sleep(for: .seconds(5))
                say(String(format: "t=%3.0f s  micro %.2f  mac %.2f  (éch. %d / %d)", Date().timeIntervalSince(t0), micPeak.take(), sysPeak.take(), mic.sampleCount, sys.sampleCount))
            }
            tap.stop()
            MicrophoneHub.shared.unsubscribe(token)
            mic.close(); sys.close()
            say("fini")
            return 0
        } catch {
            say("erreur : \(error.localizedDescription)")
            return 1
        }
    }

    final class Peak: @unchecked Sendable {
        private let lock = NSLock(); private var v: Float = 0
        func note(_ x: Float) { lock.lock(); v = max(v, x); lock.unlock() }
        func take() -> Float { lock.lock(); defer { v = 0; lock.unlock() }; return v }
    }
}

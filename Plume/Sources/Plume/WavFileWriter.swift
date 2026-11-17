import Foundation

/// Un WAV **16 kHz mono 16 bits écrit au fil de l'eau** sur le disque : rien
/// n'est gardé en mémoire (deux heures de réunion = 230 Mo par piste en
/// Float32, 115 Mo en 16 bits sur le disque).
///
/// Les écritures passent par une file série. L'en-tête (tailles RIFF/data)
/// est remis à jour toutes les 10 s : si l'app s'arrête net, le fichier reste
/// lisible jusqu'aux dix dernières secondes, et `close()` le termine proprement
/// (`fsync` compris).
final class WavFileWriter: @unchecked Sendable {
    let url: URL
    private let handle: FileHandle
    private let queue: DispatchQueue
    private var dataBytes: UInt32 = 0
    private var lastHeaderUpdate = Date()
    private var closed = false
    /// Échantillons écrits (lisible depuis n'importe quel fil).
    private let countLock = NSLock()
    private var written = 0

    init(url: URL) throws {
        self.url = url
        FileManager.default.createFile(atPath: url.path, contents: Self.header(dataBytes: 0))
        handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        queue = DispatchQueue(label: "plume.wav.\(url.lastPathComponent)", qos: .utility)
    }

    var sampleCount: Int {
        countLock.lock(); defer { countLock.unlock() }
        return written
    }

    /// Ajoute des échantillons (copiés tout de suite, écrits sur la file).
    func append(_ samples: UnsafeBufferPointer<Float>) {
        guard !samples.isEmpty else { return }
        var pcm = Data(count: samples.count * 2)
        pcm.withUnsafeMutableBytes { raw in
            let out = raw.bindMemory(to: Int16.self)
            for (i, s) in samples.enumerated() {
                out[i] = Int16(max(-1, min(1, s)) * 32767).littleEndian
            }
        }
        countLock.lock(); written += samples.count; countLock.unlock()
        queue.async { [self] in
            guard !closed else { return }
            do {
                try handle.write(contentsOf: pcm)
                dataBytes &+= UInt32(pcm.count)
                if Date().timeIntervalSince(lastHeaderUpdate) > 10 { try writeHeader() }
            } catch {
                Log.info("écriture de \(url.lastPathComponent) impossible : \(error.localizedDescription)")
            }
        }
    }

    /// Termine le fichier : en-tête final, `fsync`, fermeture. Attend la file.
    func close() {
        queue.sync {
            guard !closed else { return }
            closed = true
            try? writeHeader()
            try? handle.synchronize()
            try? handle.close()
        }
    }

    private func writeHeader() throws {
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: Self.header(dataBytes: dataBytes))
        try handle.seekToEnd()
        lastHeaderUpdate = Date()
    }

    static func header(dataBytes: UInt32, sampleRate: UInt32 = 16_000) -> Data {
        var data = Data(capacity: 44)
        func ascii(_ s: String) { data.append(contentsOf: Array(s.utf8)) }
        func le32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func le16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        ascii("RIFF"); le32(36 &+ dataBytes); ascii("WAVE")
        ascii("fmt "); le32(16); le16(1); le16(1); le32(sampleRate); le32(sampleRate * 2); le16(2); le16(16)
        ascii("data"); le32(dataBytes)
        return data
    }
}

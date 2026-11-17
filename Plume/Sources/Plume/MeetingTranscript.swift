import Foundation

/// Le texte d'une réunion **sur le disque, au fil de l'eau** : rien ne doit
/// pouvoir se perdre, même si l'app s'arrête net.
///
/// - `.plume-paragraphes.jsonl` : chaque version de chaque paragraphe, une
///   ligne JSON, **ajoutée** (jamais réécrite). Le paragraphe lissé est une
///   nouvelle ligne avec le même `id` : la lecture garde la dernière.
/// - `réunion.md` : l'en-tête au départ, puis chaque paragraphe **ajouté** dès
///   qu'il est terminé. À l'arrêt seulement, le fichier est réécrit une fois
///   (dans l'ordre du temps, avec la durée et le nombre de mots).
/// - `.plume-meta.json` : petit, réécrit en entier (atomiquement) de temps en temps.
///
/// Toutes les écritures passent par une file série : l'appelant ne bloque jamais.
final class MeetingTranscript: @unchecked Sendable {
    let folder: MeetingFolder
    private let queue = DispatchQueue(label: "plume.meeting.transcript", qos: .utility)
    private var journal: FileHandle?
    private var markdown: FileHandle?

    init(folder: MeetingFolder, meta: MeetingMeta) throws {
        self.folder = folder
        let fm = FileManager.default
        fm.createFile(atPath: folder.paragraphsURL.path, contents: nil)
        fm.createFile(atPath: folder.markdownURL.path, contents: Data(MeetingFiles.markdown(meta: meta, paragraphs: []).utf8))
        journal = try FileHandle(forWritingTo: folder.paragraphsURL)
        markdown = try FileHandle(forWritingTo: folder.markdownURL)
        try markdown?.seekToEnd()
        try Self.write(meta, to: folder.metaURL)
    }

    /// Une version d'un paragraphe (ouverte, brute ou lissée) dans le journal.
    func record(_ p: MeetingParagraph) {
        queue.async { [self] in
            guard let journal, var line = try? MeetingFiles.encoder.encode(p) else { return }
            line.append(UInt8(ascii: "\n"))
            Self.append(line, to: journal, name: "journal")
        }
    }

    /// Un paragraphe terminé, ajouté à la fin de `réunion.md`.
    func appendToMarkdown(_ p: MeetingParagraph) {
        queue.async { [self] in
            guard let markdown, !p.text.isEmpty else { return }
            Self.append(Data((MeetingFiles.paragraphLine(p) + "\n\n").utf8), to: markdown, name: "réunion.md")
        }
    }

    func updateMeta(_ meta: MeetingMeta) {
        queue.async { [self] in try? Self.write(meta, to: folder.metaURL) }
    }

    /// Fin de réunion : `réunion.md` réécrit une fois, dans l'ordre du temps,
    /// avec l'en-tête complet ; tout est `fsync`é. Attend la file.
    func finish(meta: MeetingMeta, paragraphs: [MeetingParagraph]) {
        queue.sync {
            try? journal?.synchronize()
            try? journal?.close()
            journal = nil
            try? markdown?.close()
            markdown = nil
            let text = MeetingFiles.markdown(meta: meta, paragraphs: paragraphs)
            do {
                try Data(text.utf8).write(to: folder.markdownURL, options: .atomic)
            } catch {
                Log.info("réunion : réécriture finale de réunion.md impossible (\(error.localizedDescription)), la version au fil de l'eau reste")
            }
            try? Self.write(meta, to: folder.metaURL)
        }
    }

    private static func append(_ data: Data, to handle: FileHandle, name: String) {
        do {
            try handle.write(contentsOf: data)
        } catch {
            Log.info("réunion : écriture dans \(name) impossible (\(error.localizedDescription))")
        }
    }

    private static func write(_ meta: MeetingMeta, to url: URL) throws {
        try MeetingFiles.encoder.encode(meta).write(to: url, options: .atomic)
    }

    // MARK: Réunion interrompue

    /// Au lancement : une réunion restée « en cours » (l'app s'est arrêtée net)
    /// est refermée à partir de son journal — texte remis en ordre, en-têtes
    /// WAV recalculés depuis la taille des fichiers. Rien n'est jeté.
    static func recoverInterrupted(except current: MeetingFolder? = nil) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: MeetingFolder.root, includingPropertiesForKeys: nil) else { return }
        for url in entries {
            let folder = MeetingFolder(url: url)
            guard folder != current, var meta = folder.readMeta(), meta.recording else { continue }
            var paragraphs = folder.readParagraphs()
            for i in paragraphs.indices { paragraphs[i].open = false }
            var seconds = paragraphs.map(\.end).max() ?? meta.duration
            for wav in [folder.micURL, folder.systemURL] {
                if let s = repairWavHeader(wav) { seconds = max(seconds, s) }
            }
            meta.recording = false
            meta.duration = seconds
            meta.endedAt = meta.startedAt.addingTimeInterval(seconds)
            meta.paragraphs = paragraphs.count
            meta.words = paragraphs.reduce(0) { $0 + $1.words }
            try? Data(MeetingFiles.markdown(meta: meta, paragraphs: paragraphs).utf8).write(to: folder.markdownURL, options: .atomic)
            try? write(meta, to: folder.metaURL)
            Log.info("réunion interrompue refermée : \(folder.name) (\(paragraphs.count) paragraphes)")
        }
    }

    /// Recalcule l'en-tête d'un WAV écrit par `WavFileWriter` ; rend sa durée.
    @discardableResult
    static func repairWavHeader(_ url: URL) -> Double? {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int), size >= 44,
              let handle = try? FileHandle(forWritingTo: url) else { return nil }
        defer { try? handle.close() }
        let dataBytes = UInt32((size - 44) / 2 * 2)
        try? handle.seek(toOffset: 0)
        try? handle.write(contentsOf: WavFileWriter.header(dataBytes: dataBytes))
        return Double(dataBytes / 2) / AudioRecorder.sampleRate
    }
}

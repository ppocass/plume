import Foundation

/// Journal de Plume : `~/Library/Logs/Plume.log`.
///
/// On n'y écrit JAMAIS le texte dicté (seulement des durées et des tailles) :
/// la dictée peut contenir n'importe quoi de personnel.
enum Log {
    static let url: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("Plume.log")
    }()

    private static let queue = DispatchQueue(label: "plume.log")
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    static func info(_ message: String) {
        let line = "\(formatter.string(from: Date())) \(message)\n"
        queue.async {
            // Rotation simple : au-delà de 2 Mo on repart d'un fichier vide.
            if let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int, size > 2_000_000 {
                try? FileManager.default.removeItem(at: url.appendingPathExtension("old"))
                try? FileManager.default.moveItem(at: url, to: url.appendingPathExtension("old"))
            }
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(line.data(using: .utf8)!)
                try? handle.close()
            } else {
                try? line.data(using: .utf8)!.write(to: url)
            }
        }
    }
}

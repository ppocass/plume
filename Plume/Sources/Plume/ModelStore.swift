import CryptoKit
import Foundation

/// Où vit un modèle sur ce Mac (fonctions pures : appelables depuis le moteur).
enum ModelLocation {
    /// Le dossier de Plume pour ce modèle (`Models/parakeet-ultra`, `Models/whisper`).
    static func plumeFolder(_ m: ModelInfo) -> URL {
        Setup.modelsFolder.appendingPathComponent(m.folder, isDirectory: true)
    }

    /// Copie déjà présente ailleurs (FluidAudio, `local.json`), réutilisée telle quelle.
    static func externalFolder(_ m: ModelInfo) -> URL? {
        guard !Setup.simulatePortable else { return nil }
        switch m.family {
        case .parakeet:
            let dir = Setup.fluidAudioModels.appendingPathComponent(m.folder, isDirectory: true)
            return filesPresent(m, in: dir) ? dir : nil
        case .whisper:
            guard let local = Setup.localWhisperModel, local.lastPathComponent == m.files.first?.path else { return nil }
            return local.deletingLastPathComponent()
        case .cloud:
            return nil
        }
    }

    /// Le dossier qui contient les fichiers du modèle, s'il est installé.
    static func installedFolder(_ m: ModelInfo) -> URL? {
        if m.family == .cloud { return nil }
        let own = plumeFolder(m)
        if filesPresent(m, in: own) { return own }
        return externalFolder(m)
    }

    static func isInstalled(_ m: ModelInfo) -> Bool { m.family == .cloud || installedFolder(m) != nil }

    /// Installé dans le dossier de Plume (on peut donc le supprimer).
    static func isOwned(_ m: ModelInfo) -> Bool { m.family != .cloud && filesPresent(m, in: plumeFolder(m)) }

    /// Le fichier `.bin` d'un modèle Whisper installé.
    static func whisperFile(_ m: ModelInfo) -> URL? {
        guard m.family == .whisper, let dir = installedFolder(m), let name = m.files.first?.path else { return nil }
        return dir.appendingPathComponent(name)
    }

    /// Tous les fichiers sont là, à la bonne taille. (L'empreinte, plus
    /// longue à calculer, est vérifiée au téléchargement.)
    static func filesPresent(_ m: ModelInfo, in dir: URL) -> Bool {
        guard !m.files.isEmpty else { return false }
        let fm = FileManager.default
        return m.files.allSatisfy { f in
            let size = (try? fm.attributesOfItem(atPath: dir.appendingPathComponent(f.path).path)[.size] as? NSNumber)?.int64Value
            return size == f.size
        }
    }
}

/// Le modèle choisi, et les téléchargements (progression, annulation,
/// contrôle sha256, suppression).
@MainActor
final class ModelStore: ObservableObject {
    static let shared = ModelStore()

    /// Progression (0…1) des téléchargements en cours.
    @Published private(set) var progress: [String: Double] = [:]
    @Published private(set) var errors: [String: String] = [:]
    /// Change à chaque installation / suppression (pour redessiner les vues).
    @Published private(set) var revision = 0
    @Published private(set) var selectedID: String

    private var tasks: [String: Task<Void, Never>] = [:]

    private init() {
        selectedID = Self.storedSelection
    }

    /// Le choix enregistré. La toute première fois : l'ancien réglage `engine`
    /// s'il existe, sinon le modèle conseillé pour ce Mac — enregistré aussitôt,
    /// pour que le choix ne change plus tout seul.
    nonisolated static var storedSelection: String {
        let d = UserDefaults.standard
        if let id = d.string(forKey: "model"), ModelCatalog.model(id) != nil { return id }
        let id: String
        if let old = d.string(forKey: "engine") {
            id = old == "whisper" ? "whisper-turbo-q5" : ModelCatalog.defaultID
        } else if d.bool(forKey: "onboardingDone") {
            id = ModelCatalog.defaultID   // déjà installé avant le choix des modèles
        } else {
            id = ModelCatalog.recommendedDefault()
        }
        d.set(id, forKey: "model")
        return id
    }

    /// Le modèle utilisé pour dicter : le choix, s'il est prêt, sinon Parakeet Ultra.
    nonisolated static var active: ModelInfo {
        if let forced = ProcessInfo.processInfo.environment["PLUME_MODEL"].flatMap(ModelCatalog.model) { return forced }
        let chosen = ModelCatalog.model(storedSelection) ?? ModelCatalog.model(ModelCatalog.defaultID)!
        if chosen.family == .cloud || ModelLocation.isInstalled(chosen) { return chosen }
        return ModelCatalog.model(ModelCatalog.defaultID)!
    }

    var selected: ModelInfo { ModelCatalog.model(selectedID) ?? ModelCatalog.model(ModelCatalog.defaultID)! }

    func isInstalled(_ m: ModelInfo) -> Bool { _ = revision; return ModelLocation.isInstalled(m) }
    func canDelete(_ m: ModelInfo) -> Bool { _ = revision; return ModelLocation.isOwned(m) && m.id != ModelStore.active.id }
    func isDownloading(_ m: ModelInfo) -> Bool { progress[m.id] != nil }

    /// Choisit le modèle (le télécharge d'abord s'il manque).
    func use(_ m: ModelInfo) {
        guard isSupported(m) else { return }
        UserDefaults.standard.set(m.id, forKey: "model")
        selectedID = m.id
        Log.info("modèle choisi : \(m.id)")
        if !isInstalled(m) { download(m) }
        Task { await SpeechEngine.shared.refreshState() }
    }

    func isSupported(_ m: ModelInfo) -> Bool {
        if m.family == .whisper && Setup.whisperBinary == nil { return false }
        if m.family == .parakeet && Setup.parakeetBinary == nil { return false }
        return Setup.macOSMajor >= m.minMacOS
    }

    // MARK: Téléchargement

    func download(_ m: ModelInfo) {
        guard m.family != .cloud, tasks[m.id] == nil, !isInstalled(m) else { return }
        errors[m.id] = nil
        progress[m.id] = 0
        Log.info("téléchargement du modèle \(m.id) (\(m.downloadSize / 1_000_000) Mo)")
        tasks[m.id] = Task { [weak self] in
            do {
                try await ModelDownloader.install(m) { fraction in
                    Task { @MainActor in if self?.progress[m.id] != nil { self?.progress[m.id] = fraction } }
                }
                Log.info("modèle \(m.id) installé et vérifié")
            } catch is CancellationError {
                Log.info("téléchargement de \(m.id) annulé")
            } catch {
                Log.info("téléchargement de \(m.id) impossible : \(error.localizedDescription)")
                self?.errors[m.id] = error.localizedDescription
            }
            self?.tasks[m.id] = nil
            self?.progress[m.id] = nil
            self?.revision += 1
            Task { await SpeechEngine.shared.refreshState() }
        }
    }

    func cancel(_ m: ModelInfo) {
        tasks[m.id]?.cancel()
    }

    /// Rend la place. Seulement une copie de Plume, jamais le modèle en service.
    func delete(_ m: ModelInfo) {
        guard canDelete(m) else { return }
        Task {
            await SpeechEngine.engine(for: m).stopOwned()
            let fm = FileManager.default
            let dir = ModelLocation.plumeFolder(m)
            if m.family == .whisper {
                for f in m.files { try? fm.removeItem(at: dir.appendingPathComponent(f.path)) }
            } else {
                try? fm.removeItem(at: dir)
            }
            Log.info("modèle \(m.id) supprimé")
            revision += 1
        }
    }

    /// Premier lancement : le modèle par défaut se télécharge tout de suite.
    func prefetchDefaultIfNeeded() {
        let m = selected
        if m.family != .cloud, !isInstalled(m), isSupported(m) { download(m) }
    }

    /// Le modèle à recommander dans cette famille pour ce Mac.
    func recommendedID(_ family: ModelFamily) -> String? { ModelCatalog.recommended(family) }
}

/// Télécharge un modèle fichier par fichier dans un dossier provisoire,
/// vérifie chaque sha256, puis le met en place d'un coup.
enum ModelDownloader {
    enum Failure: LocalizedError {
        case http(Int, String)
        case checksum(String)
        case diskSpace
        var errorDescription: String? {
            switch self {
            case .http(let code, let file): return L("Erreur \(code) sur \(file)", "Error \(code) on \(file)")
            case .checksum(let file): return L("Fichier corrompu : \(file)", "Corrupted file: \(file)")
            case .diskSpace: return L("Pas assez de place sur le disque", "Not enough disk space")
            }
        }
    }

    static func install(_ m: ModelInfo, progress: @escaping @Sendable (Double) -> Void) async throws {
        let fm = FileManager.default
        let target = ModelLocation.plumeFolder(m)
        let staging = Setup.modelsFolder.appendingPathComponent(".partiel-\(m.id)", isDirectory: true)
        try? fm.removeItem(at: staging)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        let free = (try? Setup.modelsFolder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage ?? Int64.max
        if free < m.downloadSize + 200_000_000 { throw Failure.diskSpace }

        let total = Double(max(m.downloadSize, 1))
        var done: Int64 = 0
        for file in m.files {
            try Task.checkCancellation()
            let dest = staging.appendingPathComponent(file.path)
            try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            let base = done
            let tmp = try await fetch(m.url(for: file), name: file.path) { written in
                progress(Double(base + written) / total)
            }
            // Vérifié avant d'être gardé : un fichier altéré ne sert jamais.
            guard try sha256(of: tmp) == file.sha256 else {
                try? fm.removeItem(at: tmp)
                throw Failure.checksum(file.path)
            }
            try fm.moveItem(at: tmp, to: dest)
            done += file.size
            progress(Double(done) / total)
        }

        // Mise en place : un seul dossier pour Parakeet, un fichier pour Whisper.
        if m.family == .whisper {
            try fm.createDirectory(at: target, withIntermediateDirectories: true)
            for file in m.files {
                let dest = target.appendingPathComponent(file.path)
                try? fm.removeItem(at: dest)
                try fm.moveItem(at: staging.appendingPathComponent(file.path), to: dest)
            }
        } else {
            try? fm.removeItem(at: target)
            try fm.moveItem(at: staging, to: target)
        }
    }

    /// Un fichier, avec la progression en octets. Annulable.
    private static func fetch(_ url: URL, name: String, written: @escaping @Sendable (Int64) -> Void) async throws -> URL {
        let kept = Setup.modelsFolder.appendingPathComponent(".dl-\(UUID().uuidString)")
        let delegate = DownloadDelegate(destination: kept, onWrite: written)
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let task = session.downloadTask(with: url)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                delegate.continuation = c
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
        try Task.checkCancellation()
        let code = delegate.statusCode
        guard code == 200 else {
            try? FileManager.default.removeItem(at: kept)
            throw Failure.http(code, name)
        }
        return kept
    }

    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 8 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Suit un téléchargement : progression, fichier reçu mis de côté, fin.
private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let destination: URL
    let onWrite: @Sendable (Int64) -> Void
    var continuation: CheckedContinuation<Void, Error>?
    var statusCode = 0
    private var moveError: Error?

    init(destination: URL, onWrite: @escaping @Sendable (Int64) -> Void) {
        self.destination = destination
        self.onWrite = onWrite
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        onWrite(totalBytesWritten)
    }

    /// Le fichier temporaire disparaît à la sortie de cette méthode : on le déplace ici.
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        statusCode = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        do { try FileManager.default.moveItem(at: location, to: destination) } catch { moveError = error }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let c = continuation
        continuation = nil
        if let error = error ?? moveError {
            c?.resume(throwing: (error as? URLError)?.code == .cancelled ? CancellationError() : error)
        } else {
            c?.resume()
        }
    }
}

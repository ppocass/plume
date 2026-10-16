import Foundation

/// État du moteur, pour la fenêtre (Accueil, Réglages).
enum EngineState: Equatable {
    case sleeping          // aucun serveur lancé : 0 Mo de RAM
    case loading           // on le lance, le modèle se charge
    case notInstalled      // le modèle n'est pas encore téléchargé
    case ready(owned: Bool) // owned = lancé par Plume (sinon : partagé avec une autre app)
    case online            // service en ligne
    case failed(String)

    var label: String {
        switch self {
        case .sleeping: return L("En veille", "Idle")
        case .loading: return L("Chargement…", "Loading…")
        case .notInstalled: return L("Modèle à télécharger", "Model not downloaded")
        case .ready(true): return L("Prêt", "Ready")
        case .ready(false): return L("Prêt (partagé)", "Ready (shared)")
        case .online: return L("En ligne", "Online")
        case .failed(let message): return L("Erreur : ", "Error: ") + message
        }
    }
}

@MainActor
final class EngineStatus: ObservableObject {
    static let shared = EngineStatus()
    @Published var state: EngineState = .sleeping
}

/// Le moteur d'un modèle. Pour un modèle local : un petit serveur HTTP
/// (`parakeet-server` ou `whisper-server`, même API : `GET /` pour sonder,
/// `POST /inference` multipart → `{"text": …}`) ; pour « En ligne » : le
/// service choisi dans les réglages.
///
/// Règle du moteur partagé : **s'attacher ou lancer**. Si le port répond, on
/// se sert du serveur déjà là et on n'y touche jamais. Sinon on le lance, et
/// on n'arrête que ce qu'on a lancé, après la dernière dictée (délai réglable). Le port
/// fait office de verrou : jamais deux fois le même modèle en mémoire.
actor SpeechEngine {
    /// Un moteur par modèle, créé à la demande.
    private static let registry = EngineRegistry()
    static func engine(for model: ModelInfo) -> SpeechEngine { registry.engine(for: model) }
    /// Le moteur du modèle actif.
    static var shared: SpeechEngine { engine(for: ModelStore.active) }

    let model: ModelInfo
    init(model: ModelInfo) { self.model = model }

    var family: ModelFamily { model.family }
    let host = "127.0.0.1"
    var port: Int { model.port }

    var binary: String? {
        switch family {
        case .parakeet: return Setup.parakeetBinary
        case .whisper: return Setup.whisperBinary
        case .cloud: return nil
        }
    }

    private func launchArgs(modelFolder: URL) -> [String] {
        switch family {
        case .parakeet:
            // `--models-dir` : le dossier parent de `parakeet-ultra/`… ; rien n'est téléchargé par le serveur.
            return ["--host", host, "--port", String(port), "--model", model.parakeetVersion ?? "ultra",
                    "--models-dir", modelFolder.deletingLastPathComponent().path]
        case .whisper:
            let file = modelFolder.appendingPathComponent(model.files.first?.path ?? "").path
            // `-ac 768` : fenêtre d'environ 15 s, deux fois plus rapide, mais
            // Whisper répète la fin d'un morceau de plus de ~9 s : les dictées
            // sont donc coupées en morceaux de 8 s (voir `SpeechGate`).
            // La langue est envoyée à chaque requête ; `-l` n'est qu'un défaut.
            let language = Setup.localWhisperModel?.path == file ? "fr" : "auto"
            return ["-m", file, "-l", language, "-sns", "-ac", "768", "--host", host, "--port", String(port)]
        case .cloud:
            return []
        }
    }

    private var process: Process?
    /// Un serveur orphelin (son lanceur est mort sans l'arrêter) : personne ne
    /// l'arrêterait jamais, donc Plume l'adopte et l'arrête comme le sien.
    /// Celui d'une autre app a toujours un parent vivant : jamais adopté.
    private var adoptedPID: pid_t?
    private var startTask: Task<Void, Error>?
    private var idleTask: Task<Void, Never>?
    private var busy = 0

    private var baseURL: URL { URL(string: "http://\(host):\(port)")! }

    enum EngineError: LocalizedError {
        case missing(String)
        case notInstalled(String)
        case exited(String)
        case timeout
        case http(Int, String)
        var errorDescription: String? {
            switch self {
            case .missing(let what): return L("\(what) introuvable", "\(what) not found")
            case .notInstalled(let name): return L("\(name) n'est pas téléchargé", "\(name) is not downloaded")
            case .exited(let tail): return L("arrêt au démarrage", "stopped at launch") + " \(tail)"
            case .timeout: return L("délai dépassé", "timed out")
            case .http(let code, let body): return "HTTP \(code) \(body)"
            }
        }
    }

    // MARK: Démarrage

    /// N'importe quelle réponse HTTP = le serveur écoute, donc son modèle est chargé.
    func probe() async -> Bool {
        guard family != .cloud else { return false }
        var request = URLRequest(url: baseURL)
        request.timeoutInterval = 1.5
        do {
            _ = try await URLSession.shared.data(for: request)
            return true
        } catch {
            return false
        }
    }

    /// Prêt à transcrire : s'attache au serveur existant ou lance le nôtre.
    func ensureRunning() async throws {
        guard family != .cloud else { return }
        idleTask?.cancel()
        idleTask = nil
        if let startTask {
            try await startTask.value
            return
        }
        let task = Task { try await self.startIfNeeded() }
        startTask = task
        defer { startTask = nil }
        try await task.value
    }

    private func startIfNeeded() async throws {
        if await probe() {
            if process?.isRunning != true { adoptOrphanIfAny() }
            await setState(.ready(owned: ownsEngine))
            return
        }
        if let process, process.isRunning {
            // Le nôtre tourne mais ne répond pas encore : il charge.
            try await waitUntilReady(process)
            return
        }
        try await launch()
    }

    private func launch() async throws {
        guard let binary, FileManager.default.isExecutableFile(atPath: binary) else {
            throw EngineError.missing(family == .parakeet ? "parakeet-server" : "whisper-server")
        }
        guard let folder = ModelLocation.installedFolder(model) else {
            await setState(.notInstalled)
            throw EngineError.notInstalled(model.name)
        }

        await setState(.loading)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: binary)
        p.arguments = launchArgs(modelFolder: folder)
        p.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        let errPipe = Pipe()
        p.standardOutput = FileHandle.nullDevice
        p.standardError = errPipe
        // On ne garde que la fin de la sortie d'erreur, pour un message utile.
        let tail = TailBuffer()
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil } else { tail.append(data) }
        }
        let name = (binary as NSString).lastPathComponent
        p.terminationHandler = { [weak self] proc in
            Log.info("\(name) (pid \(proc.processIdentifier)) arrêté, code \(proc.terminationStatus)")
            Task { await self?.processDidExit(proc) }
        }
        let started = Date()
        try p.run()
        process = p
        OwnedProcesses.set(model.id, p.processIdentifier)
        Log.info("\(name) lancé par Plume pour \(model.id) (pid \(p.processIdentifier))")
        do {
            try await waitUntilReady(p, tail: tail)
            Log.info(String(format: "moteur prêt en %.1f s", Date().timeIntervalSince(started)))
        } catch {
            stopOwned()
            await setState(.failed(error.localizedDescription))
            throw error
        }
    }

    private var ownsEngine: Bool { process?.isRunning == true || adoptedPID != nil }

    /// Le PID qui écoute sur le port, s'il est orphelin (parent = launchd) et
    /// que c'est bien notre binaire.
    private func adoptOrphanIfAny() {
        guard adoptedPID == nil, let binary, let pid = Self.listenerPID(port: port) else { return }
        guard Self.parentPID(of: pid) == 1,
              Self.executablePath(of: pid) == URL(fileURLWithPath: binary).resolvingSymlinksInPath().path else { return }
        adoptedPID = pid
        OwnedProcesses.set(model.id, pid)
        Log.info("serveur orphelin adopté sur le port \(port) (pid \(pid))")
    }

    /// Au démarrage de Plume : s'il traîne un serveur orphelin, on l'adopte et
    /// on programme son arrêt.
    func cleanUpOrphanAtLaunch(idleSeconds: Double) async {
        guard family != .cloud, await probe() else { return }
        adoptOrphanIfAny()
        if adoptedPID != nil { scheduleIdleRelease(after: idleSeconds) }
    }

    nonisolated static func listenerPID(port: Int) -> pid_t? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        p.arguments = ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-t"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        p.waitUntilExit()
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return text.split(whereSeparator: \.isNewline).first.flatMap { pid_t($0) }
    }

    nonisolated static func parentPID(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info.kp_eproc.e_ppid
    }

    nonisolated static func executablePath(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        // Comparé au chemin résolu (Homebrew : le binaire est un lien vers le Cellar).
        return URL(fileURLWithPath: String(cString: buffer)).resolvingSymlinksInPath().path
    }

    private func waitUntilReady(_ p: Process, tail: TailBuffer? = nil) async throws {
        // Le tout premier chargement compile le modèle pour la puce : plus long.
        let deadline = Date().addingTimeInterval(600)
        while true {
            if await probe() {
                await setState(.ready(owned: true))
                return
            }
            if !p.isRunning {
                throw EngineError.exited(String((tail?.text ?? "").suffix(300)))
            }
            if Date() > deadline { throw EngineError.timeout }
            try await Task.sleep(for: .milliseconds(300))
        }
    }

    private func processDidExit(_ p: Process) async {
        OwnedProcesses.clear(model.id, p.processIdentifier)
        guard p === process else { return }
        process = nil
        await setState(await probe() ? .ready(owned: false) : .sleeping)
    }

    // MARK: Transcription

    /// Une requête à la fois : le serveur est mono-requête (deux en parallèle =
    /// temps doublé), et un morceau suit l'autre dans l'ordre.
    func transcribe(wav: Data, language: String, prompt: String? = nil) async throws -> String {
        if family == .cloud {
            return try await CloudTranscriber.transcribe(wav: wav, language: language, prompt: prompt)
        }
        try await ensureRunning()
        busy += 1
        defer { busy -= 1 }

        let boundary = "plume-\(UUID().uuidString)"
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        // L'ordre compte pour le lecteur multipart du serveur : paramètres, puis fichier.
        field("language", language)
        field("response_format", "json")
        // Les mots du vocabulaire : Whisper les écrit alors correctement.
        // Valable pour cette requête seule (Parakeet l'ignore).
        if let prompt, !prompt.isEmpty { field("prompt", prompt) }
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8))
        body.append(wav)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))

        var request = URLRequest(url: baseURL.appendingPathComponent("inference"))
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await URLSession.shared.upload(for: request, from: body)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            throw EngineError.http(code, String(decoding: data.prefix(200), as: UTF8.self))
        }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return (json?["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Extinction

    /// À appeler après chaque dictée : passé le délai sans nouvelle dictée → le serveur
    /// que NOUS avons lancé est arrêté et rend sa RAM. Un serveur partagé
    /// n'est jamais touché.
    func scheduleIdleRelease(after seconds: Double) {
        idleTask?.cancel()
        guard seconds >= 0, process != nil || adoptedPID != nil else { return }
        idleTask = Task {
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self.releaseIfIdle()
        }
    }

    private func releaseIfIdle() {
        guard busy == 0, startTask == nil else { return }
        Log.info("pas de dictée depuis \(Int(Prefs.idleSeconds)) s : arrêt du moteur \(model.id), mémoire rendue")
        stopOwned()
    }

    func stopOwned() {
        idleTask?.cancel()
        idleTask = nil
        if let pid = adoptedPID {
            adoptedPID = nil
            OwnedProcesses.clear(model.id, pid)
            kill(pid, SIGTERM)
            Log.info("serveur adopté (pid \(pid)) arrêté")
            Task { await self.setState(.sleeping) }
        }
        guard let p = process else { return }
        process = nil
        if p.isRunning { p.terminate() }
        Task { await self.setState(.sleeping) }
    }

    /// Appelé au moment où l'app quitte (hors acteur, synchrone).
    nonisolated static func killOwnedNow() {
        for pid in OwnedProcesses.all where pid > 0 { kill(pid, SIGTERM) }
    }

    /// État pour l'affichage, rafraîchi quand la fenêtre est ouverte.
    func refreshState() async {
        if family == .cloud {
            await setState(.online)
        } else if let process, process.isRunning {
            await setState(await probe() ? .ready(owned: true) : .loading)
        } else if !ModelLocation.isInstalled(model) {
            await setState(.notInstalled)
        } else {
            await setState(await probe() ? .ready(owned: adoptedPID != nil) : .sleeping)
        }
    }

    /// La fenêtre montre l'état du modèle ACTIF.
    private func setState(_ s: EngineState) async {
        let id = model.id
        await MainActor.run {
            if id == ModelStore.active.id { EngineStatus.shared.state = s }
        }
    }
}

/// Les moteurs déjà créés (un par modèle).
private final class EngineRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var engines: [String: SpeechEngine] = [:]

    func engine(for model: ModelInfo) -> SpeechEngine {
        lock.lock(); defer { lock.unlock() }
        if let e = engines[model.id] { return e }
        let e = SpeechEngine(model: model)
        engines[model.id] = e
        return e
    }
}

/// Les PID des serveurs lancés ou adoptés par Plume, lisibles sans passer
/// par les acteurs (pour les arrêter quand l'app quitte). Protégé par un
/// verrou : plusieurs moteurs l'écrivent en même temps.
enum OwnedProcesses {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var pids: [String: Int32] = [:]

    static func set(_ id: String, _ pid: Int32) {
        lock.lock(); defer { lock.unlock() }
        pids[id] = pid
    }

    static func clear(_ id: String, _ pid: Int32) {
        lock.lock(); defer { lock.unlock() }
        if pids[id] == pid { pids[id] = nil }
    }

    static var all: [Int32] {
        lock.lock(); defer { lock.unlock() }
        return Array(pids.values)
    }
}

/// Garde les derniers Ko d'une sortie de processus.
final class TailBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func append(_ d: Data) {
        lock.lock(); defer { lock.unlock() }
        data.append(d)
        if data.count > 4096 { data = data.suffix(4096) }
    }
    var text: String {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }
}

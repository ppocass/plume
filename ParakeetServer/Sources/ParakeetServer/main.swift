import AVFoundation
import FluidAudio
import Foundation
import Network

// parakeet-server — NVIDIA Parakeet sur le Neural Engine, avec l'API de whisper-server.
//
//   parakeet-server [--host 127.0.0.1] [--port 8092] [--model ultra|redux|v3] [--models-dir DOSSIER]
//
// - `GET /`            → 200 dès que le modèle est chargé (le port n'écoute qu'APRÈS le
//                        chargement : « le port répond » = « prêt », comme whisper-server).
// - `POST /inference`  → multipart `file` (WAV, n'importe quelle fréquence) [+ `language`,
//                        `prompt`, ignorés : Parakeet détecte la langue seul] → {"text": "…"}.
//
// Sans `--models-dir`, FluidAudio télécharge le modèle dans son propre dossier au premier
// lancement. Avec `--models-dir`, le modèle doit déjà s'y trouver (Plume le télécharge et
// vérifie ses empreintes) : rien n'est téléchargé, le serveur échoue plutôt.
//
// Plusieurs apps peuvent partager le même serveur : elles s'y attachent si le port répond,
// sinon le lancent, et seule celle qui l'a lancé l'arrête.

setvbuf(stdout, nil, _IOLBF, 0)
nonisolated(unsafe) var _signalSources: [DispatchSourceSignal] = []
func log(_ s: String) { print("[parakeet-server] \(s)") }

/// Garde-fous contre une requête démesurée : 64 Ko d'en-têtes, 200 Mo de corps
/// (≈ 1 h 40 de WAV 16 kHz mono).
let maxHeaderBytes = 64 * 1024
let maxBodyBytes = 200 * 1024 * 1024

var host = "127.0.0.1"
var port: UInt16 = 8092
var version: AsrModelVersion = .ultra
var modelsDir: URL?
var argv = CommandLine.arguments.dropFirst().makeIterator()
while let a = argv.next() {
    switch a {
    case "--host": host = argv.next() ?? host
    case "--port": port = UInt16(argv.next() ?? "") ?? port
    case "--model":
        switch argv.next() {
        case "v3": version = .v3
        case "redux": version = .redux
        default: version = .ultra
        }
    case "--models-dir": modelsDir = argv.next().map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) }
    default: break
    }
}
guard port > 0, let nwPort = NWEndpoint.Port(rawValue: port) else {
    log("port invalide")
    exit(2)
}

var modelName: String {
    switch version {
    case .v3: return "parakeet-tdt-0.6b-v3"
    case .redux: return "parakeet-redux"
    default: return "parakeet-ultra"
    }
}

/// Le modèle et les requêtes, une à la fois (l'acteur sérialise).
actor Engine {
    let manager: AsrManager
    let layers: Int
    let converter = AudioConverter()

    init(models: AsrModels) async throws {
        manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        layers = models.version.decoderLayers
    }

    func transcribe(wavData: Data) async throws -> (String, Double, Double) {
        // Le fichier reçu peut être à 16 kHz ou 48 kHz : AVAudioFile + le
        // convertisseur de FluidAudio ramènent tout à 16 kHz mono.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("parakeet-\(UUID().uuidString).wav")
        try wavData.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let samples = try converter.resampleAudioFile(url)
        guard samples.count > 1600 else { return ("", Double(samples.count) / 16_000, 0) }
        let started = Date()
        var state = TdtDecoderState.make(decoderLayers: layers)
        let result = try await manager.transcribe(samples, decoderState: &state)
        return (result.text.trimmingCharacters(in: .whitespacesAndNewlines),
                Double(samples.count) / 16_000, Date().timeIntervalSince(started))
    }
}

// MARK: - HTTP minimal (une requête par connexion)

func respond(_ c: NWConnection, status: String, json: [String: Any]) {
    let body = (try? JSONSerialization.data(withJSONObject: json)) ?? Data("{}".utf8)
    let head = "HTTP/1.1 \(status)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
    c.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in c.cancel() })
}

/// Extrait les parties d'un corps multipart/form-data : nom → données.
func multipart(_ body: Data, boundary: String) -> [String: Data] {
    var parts: [String: Data] = [:]
    let delimiter = Data("--\(boundary)".utf8)
    var ranges: [Range<Data.Index>] = []
    var search = body.startIndex..<body.endIndex
    while let r = body.range(of: delimiter, in: search) {
        ranges.append(r)
        search = r.upperBound..<body.endIndex
    }
    for (i, r) in ranges.enumerated() where i + 1 < ranges.count {
        var chunk = body[r.upperBound..<ranges[i + 1].lowerBound]
        guard let headerEnd = chunk.range(of: Data("\r\n\r\n".utf8)) else { continue }
        let headers = String(decoding: chunk[chunk.startIndex..<headerEnd.lowerBound], as: UTF8.self)
        chunk = chunk[headerEnd.upperBound...]
        if chunk.suffix(2) == Data("\r\n".utf8) { chunk = chunk.dropLast(2) }
        if let n = headers.range(of: "name=\"") {
            let rest = headers[n.upperBound...]
            if let end = rest.firstIndex(of: "\"") { parts[String(rest[..<end])] = Data(chunk) }
        }
    }
    return parts
}

func handle(_ c: NWConnection, engine: Engine) {
    var buffer = Data()
    func receive() {
        c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { data, _, complete, error in
            if let data { buffer.append(data) }
            guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                if buffer.count > maxHeaderBytes {
                    respond(c, status: "431 Request Header Fields Too Large", json: ["error": "headers too large"])
                } else if complete || error != nil { c.cancel() } else { receive() }
                return
            }
            let head = String(decoding: buffer[buffer.startIndex..<headerEnd.lowerBound], as: UTF8.self)
            let lines = head.components(separatedBy: "\r\n")
            let requestLine = lines.first?.split(separator: " ") ?? []
            var headers: [String: String] = [:]
            for line in lines.dropFirst() {
                if let colon = line.firstIndex(of: ":") {
                    headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                }
            }
            let length = Int(headers["content-length"] ?? "0") ?? 0
            guard length >= 0, length <= maxBodyBytes else {
                respond(c, status: "413 Payload Too Large", json: ["error": "body too large"])
                return
            }
            let body = buffer[headerEnd.upperBound...]
            if body.count < length && !complete && error == nil { receive(); return }

            let method = requestLine.first.map(String.init) ?? ""
            let path = requestLine.count > 1 ? String(requestLine[1]) : "/"
            if method == "POST", path.hasPrefix("/inference") {
                let type = headers["content-type"] ?? ""
                guard let b = type.range(of: "boundary=") else { respond(c, status: "400 Bad Request", json: ["error": "multipart expected"]); return }
                let boundary = String(type[b.upperBound...]).trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
                let parts = multipart(Data(body.prefix(length)), boundary: boundary)
                guard let wav = parts["file"] else { respond(c, status: "400 Bad Request", json: ["error": "missing file field"]); return }
                Task {
                    do {
                        let (text, seconds, took) = try await engine.transcribe(wavData: wav)
                        log(String(format: "%.1f s d'audio en %.2f s", seconds, took))
                        respond(c, status: "200 OK", json: ["text": text])
                    } catch {
                        log("échec : \(error.localizedDescription)")
                        respond(c, status: "500 Internal Server Error", json: ["error": error.localizedDescription])
                    }
                }
            } else {
                respond(c, status: "200 OK", json: ["status": "ok", "model": modelName])
            }
        }
    }
    receive()
}

// MARK: - Démarrage : modèle d'abord, port ensuite

Task {
    do {
        let started = Date()
        log("chargement de \(modelName)…")
        let models: AsrModels
        if let modelsDir {
            // Modèle fourni (et vérifié) par l'app : aucun téléchargement.
            ModelHub.offlineMode = true
            let folder = modelsDir.appendingPathComponent(modelName == "parakeet-tdt-0.6b-v3" ? "parakeet-tdt-0.6b-v3" : modelName,
                                                         isDirectory: true)
            models = try await AsrModels.load(from: folder, version: version)
        } else {
            models = try await AsrModels.downloadAndLoad(version: version)
        }
        let engine = try await Engine(models: models)
        log(String(format: "modèle prêt en %.1f s", Date().timeIntervalSince(started)))

        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: nwPort)
        params.allowLocalEndpointReuse = true
        let listener = try NWListener(using: params)
        listener.newConnectionHandler = { c in
            c.start(queue: .global())
            handle(c, engine: engine)
        }
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready: log("écoute sur \(host):\(port)")
            case .failed(let e): log("port indisponible : \(e)"); exit(2)
            default: break
            }
        }
        listener.start(queue: .global())
    } catch {
        log("impossible de charger le modèle : \(error.localizedDescription)")
        exit(1)
    }
}

// Arrêt propre sur SIGTERM / SIGINT (envoyés après 35 s d'inactivité).
for sig in [SIGTERM, SIGINT] {
    signal(sig, SIG_IGN)
    let s = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    s.setEventHandler { log("arrêt"); exit(0) }
    s.resume()
    _signalSources.append(s)
}
dispatchMain()

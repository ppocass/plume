import Foundation

/// Les services de transcription en ligne (modèle « En ligne »). Tous parlent
/// l'API `audio/transcriptions` d'OpenAI. Chacun utilise **la clé de
/// l'utilisateur**, gardée dans le trousseau : Plume n'embarque aucune clé.
enum TranscriptionService: String, CaseIterable, Identifiable {
    case groq, openai, custom
    var id: String { rawValue }

    var label: String {
        switch self {
        case .groq: return "Groq"
        case .openai: return "OpenAI"
        case .custom: return L("Autre (compatible OpenAI)", "Other (OpenAI-compatible)")
        }
    }

    var defaultModel: String {
        switch self {
        case .groq: return "whisper-large-v3-turbo"
        case .openai: return "gpt-4o-mini-transcribe"
        case .custom: return "whisper-1"
        }
    }

    /// Compte du trousseau. Groq et OpenAI partagent la clé du nettoyage.
    var keyAccount: String { self == .custom ? "custom-stt" : rawValue }

    var keyPage: URL? {
        switch self {
        case .groq: return URL(string: "https://console.groq.com/keys")
        case .openai: return URL(string: "https://platform.openai.com/api-keys")
        case .custom: return nil
        }
    }

    static var current: TranscriptionService {
        TranscriptionService(rawValue: UserDefaults.standard.string(forKey: "sttService") ?? "") ?? .groq
    }

    var model: String {
        let m = (UserDefaults.standard.string(forKey: "sttModel_\(rawValue)") ?? "").trimmingCharacters(in: .whitespaces)
        return m.isEmpty ? defaultModel : m
    }

    var endpoint: URL? {
        switch self {
        case .groq: return URL(string: "https://api.groq.com/openai/v1/audio/transcriptions")
        case .openai: return URL(string: "https://api.openai.com/v1/audio/transcriptions")
        case .custom:
            var raw = (UserDefaults.standard.string(forKey: "sttCustomURL") ?? "").trimmingCharacters(in: .whitespaces)
            guard !raw.isEmpty else { return nil }
            if !raw.hasSuffix("/audio/transcriptions") {
                raw = raw.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/audio/transcriptions"
            }
            guard let url = URL(string: raw), EndpointPolicy.isAllowed(url) else { return nil }
            return url
        }
    }
}

enum CloudTranscriber {
    enum Failure: LocalizedError {
        case missingURL, missingKey, http(Int, String)
        var errorDescription: String? {
            switch self {
            case .missingURL: return L("Adresse manquante ou refusée (https requis)", "Missing or refused URL (https required)")
            case .missingKey: return L("Clé manquante", "Missing key")
            case .http(let code, let body): return "HTTP \(code) \(body)"
            }
        }
    }

    /// La voix part au service choisi : seulement quand l'utilisateur a choisi « En ligne ».
    static func transcribe(wav: Data, language: String, prompt: String?) async throws -> String {
        let service = TranscriptionService.current
        guard let url = service.endpoint else { throw Failure.missingURL }
        guard let key = KeychainStore.read(service.keyAccount) else { throw Failure.missingKey }

        let boundary = "plume-\(UUID().uuidString)"
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        field("model", service.model)
        field("response_format", "json")
        if language != "auto" { field("language", language) }
        if let prompt, !prompt.isEmpty { field("prompt", prompt) }
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8))
        body.append(wav)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let started = Date()
        let (data, response) = try await URLSession.shared.upload(for: request, from: body)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            Log.info("transcription en ligne : HTTP \(code)")
            throw Failure.http(code, String(decoding: data.prefix(160), as: UTF8.self))
        }
        Log.info(String(format: "transcription en ligne (%@) : %.2f s", service.rawValue, Date().timeIntervalSince(started)))
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return (json?["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Bouton « Tester » : envoie une seconde de silence (aucune voix).
    static func test() async -> Result<Double, Error> {
        let started = Date()
        do {
            _ = try await transcribe(wav: SpeechGate.wav([Float](repeating: 0, count: 16_000)[...]), language: "fr", prompt: nil)
            return .success(Date().timeIntervalSince(started))
        } catch {
            return .failure(error)
        }
    }
}

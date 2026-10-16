import Foundation

/// La liste des modèles de reconnaissance vocale. **Le seul fichier à toucher
/// pour en ajouter un** : une entrée ci-dessous, et sa liste de fichiers
/// produite par `Tools/model-manifest.py <dépôt> <fichiers…>` (révision figée
/// + sha256 de chaque fichier, vérifiés avant tout usage).
///
/// Les téléchargements viennent seulement de Hugging Face, en https, et sont
/// rangés dans `~/Library/Application Support/Plume/Models/`.
enum ModelFamily: String, Sendable {
    /// NVIDIA Parakeet par FluidAudio, sur la puce neuronale (Neural Engine).
    case parakeet
    /// whisper.cpp, sur la puce graphique (Metal).
    case whisper
    /// Un service en ligne compatible OpenAI, avec la clé de l'utilisateur.
    case cloud
}

struct ModelFile: Sendable, Equatable {
    let path: String
    let size: Int64
    let sha256: String
    init(_ path: String, _ size: Int64, _ sha256: String) {
        self.path = path
        self.size = size
        self.sha256 = sha256
    }
}

struct ModelInfo: Identifiable, Sendable, Equatable {
    let id: String
    let family: ModelFamily
    let name: String
    let summaryFR: String
    let summaryEN: String
    let languagesFR: String
    let languagesEN: String
    /// 1 à 3 (3 = le plus rapide).
    let speed: Int
    /// 1 à 3 (3 = le plus précis).
    let accuracy: Int
    /// Mémoire conseillée, en Go.
    let memoryGB: Int
    let minMacOS: Int
    /// Port local du serveur du modèle. 8092 (Parakeet Ultra) et 8090
    /// (Whisper Turbo compact) sont les ports partagés avec d'autres apps.
    let port: Int
    /// Parakeet : la version que charge `parakeet-server --model`.
    var parakeetVersion: String? = nil
    /// Dossier d'installation dans `Models/`.
    let folder: String
    var repo: String = ""
    var revision: String = ""
    var files: [ModelFile] = []

    var displayName: String { family == .cloud ? L("En ligne", "Online") : name }
    var summary: String { L(summaryFR, summaryEN) }
    var languages: String { L(languagesFR, languagesEN) }
    var downloadSize: Int64 { files.reduce(0) { $0 + $1.size } }

    func url(for file: ModelFile) -> URL {
        URL(string: "https://huggingface.co/\(repo)/resolve/\(revision)/\(file.path)")!
    }
}

enum ModelCatalog {
    static let defaultID = "parakeet-ultra"
    static let cloudID = "cloud"

    static func model(_ id: String) -> ModelInfo? { all.first { $0.id == id } }

    static var local: [ModelInfo] { all.filter { $0.family != .cloud } }

    /// Les 25 langues de Parakeet.
    static let parakeetLanguages: Set<String> = ["en", "de", "fr", "es", "it", "pt", "ru", "uk", "hr", "sl", "lv", "lt",
                                                 "et", "fi", "sv", "da", "nl", "pl", "cs", "sk", "hu", "ro", "bg", "el", "mt"]

    /// Le meilleur choix de chaque famille pour ce Mac : mémoire totale,
    /// mémoire libre au lancement, puce, version de macOS.
    static func recommended(_ family: ModelFamily, memoryGB: Int = Setup.memoryGB,
                            availableGB: Double = Setup.availableMemoryGB, pro: Bool = Setup.isProChip,
                            macOS: Int = Setup.macOSMajor) -> String? {
        switch family {
        case .parakeet:
            // La puce neuronale fait le travail : Ultra va bien dès 8 Go.
            return "parakeet-ultra"
        case .whisper:
            // Whisper vit dans la mémoire vive : Large v3 en prend ~4 Go, Turbo ~2 Go.
            if (memoryGB >= 32 || (memoryGB >= 16 && pro)) && availableGB >= 6 { return "whisper-large-v3" }
            if memoryGB >= 16 && availableGB >= 3 { return "whisper-turbo" }
            return "whisper-turbo-q5"
        case .cloud:
            return nil
        }
    }

    /// Le modèle présélectionné au premier lancement. Pour les 25 langues de
    /// Parakeet, c'est lui (le plus juste et le plus rapide d'après les
    /// mesures publiées) ; pour les autres langues, le meilleur Whisper que
    /// ce Mac peut faire tourner.
    static func recommendedDefault(language: String = Setup.systemLanguage, memoryGB: Int = Setup.memoryGB,
                                   availableGB: Double = Setup.availableMemoryGB, pro: Bool = Setup.isProChip,
                                   macOS: Int = Setup.macOSMajor, whisperAvailable: Bool = Setup.whisperBinary != nil) -> String {
        let family: ModelFamily = parakeetLanguages.contains(language) || !whisperAvailable ? .parakeet : .whisper
        return recommended(family, memoryGB: memoryGB, availableGB: availableGB, pro: pro, macOS: macOS) ?? defaultID
    }

    static let all: [ModelInfo] = [
        ModelInfo(
            id: "parakeet-ultra", family: .parakeet, name: "Parakeet Ultra",
            summaryFR: "Le plus précis pour les langues européennes, et très rapide.",
            summaryEN: "The most accurate for European languages, and very fast.",
            languagesFR: "25 langues européennes", languagesEN: "25 European languages",
            speed: 3, accuracy: 3, memoryGB: 8, minMacOS: 14, port: 8092,
            parakeetVersion: "ultra", folder: "parakeet-ultra",
            repo: "FluidInference/parakeet-ultra-coreml", revision: "95eaa59a39d4394f047a4dc5cce480388a60d1b6",
            files: [
                .init("Decoder.mlmodelc/analytics/coremldata.bin", 243, "fe92b6cfaa012abd5248c0bc877832f19807015abffc60d87b8ccc8ccb48b3b5"),
                .init("Decoder.mlmodelc/coremldata.bin", 560, "3b06e66768f0df7e21795f50e2b29300e33eeb1a2579dc42c695279c2d308497"),
                .init("Decoder.mlmodelc/model.mil", 13110, "956f600207f88396017ca5c96cfa3acd5bfee60835a5b44b762e033a8fb28955"),
                .init("Decoder.mlmodelc/weights/weight.bin", 23604992, "02a0d219f281b9665bc10c8768649403b2eebbbf4b44c627041d948e0de11bb4"),
                .init("Encoder.mlmodelc/analytics/coremldata.bin", 243, "d87101d824d6723cf95304da33755c3c60e762663b9ef2b0c4bd0aa166a09a0d"),
                .init("Encoder.mlmodelc/coremldata.bin", 514, "397a84a4062f563cbc5f56077c674f09a61d85be5090f61d2f1932afb92ac0fe"),
                .init("Encoder.mlmodelc/model.mil", 1002653, "f5d601568a4171d99a314c0fe3f6bc67715da2623732a3fb566e050ea83e5848"),
                .init("Encoder.mlmodelc/weights/weight.bin", 594211328, "315ba01f33cadbf601d43ac7f5c86208b7aa75fdaa34705c9869d5abe3521c9b"),
                .init("JointDecisionv3.mlmodelc/analytics/coremldata.bin", 243, "68d38ca646aebafa7a9329e2efda50f5767c49e89fdb5f77f212072bb66f97c4"),
                .init("JointDecisionv3.mlmodelc/coremldata.bin", 592, "5e3af5a4ce686f6c237cadbd9284e10d333bc0e1546633cd0e430e6194044bc4"),
                .init("JointDecisionv3.mlmodelc/model.mil", 11777, "791b3c3cf3eb2079c84623fc880f6bba008d1366e5f8b03e9a8ed8bd4d7194a0"),
                .init("JointDecisionv3.mlmodelc/weights/weight.bin", 12642764, "3f310b85b82341c53ec383025ab094a4e462ee1c592e1ad7c6bfe39cff66ca25"),
                .init("Preprocessor.mlmodelc/analytics/coremldata.bin", 243, "c9beeb989c8d66f8be11df59bc6df277ec76cee404f6865b46243835ef562f6d"),
                .init("Preprocessor.mlmodelc/coremldata.bin", 486, "dbde3f2300842c1fd51ef3ff948a0bcffe65ffd2dca10707f2509f32c1d65b1d"),
                .init("Preprocessor.mlmodelc/metadata.json", 2841, "2a98699e22d279dd37fa1d238aeb1c6db1df0d6fad687775324157689d8f3acf"),
                .init("Preprocessor.mlmodelc/model.mil", 28181, "4b8518a956450fec57f06c2a21bdffc26973f7f1fa6842fb38fe917f896b6b93"),
                .init("Preprocessor.mlmodelc/weights/weight.bin", 491072, "129b76e3aeafa8afa3ea76d995b964b145fe83700d579f6ff42c4c38fa0968ea"),
                .init("config.json", 414, "965c69bf500c7be18958df6438dc1ba897721690ae412937ca7c91e28cec1870"),
                .init("parakeet_v3_vocab.json", 151122, "7ec60e05f1b24480736ec0eed40900f4626bce1fa9a60fd700ec7e2a59198735"),
                .init("parakeet_vocab.json", 151122, "7ec60e05f1b24480736ec0eed40900f4626bce1fa9a60fd700ec7e2a59198735"),
            ],
        ),
        ModelInfo(
            id: "whisper-turbo-q5", family: .whisper, name: "Whisper Turbo compact",
            summaryFR: "Whisper léger : 99 langues et le vocabulaire pris en compte.",
            summaryEN: "Light Whisper: 99 languages, and it uses your vocabulary.",
            languagesFR: "99 langues", languagesEN: "99 languages",
            speed: 2, accuracy: 2, memoryGB: 8, minMacOS: 14, port: 8090,
            folder: "whisper",
            repo: "ggerganov/whisper.cpp", revision: "5359861c739e955e79d9a303bcbc70fb988958b1",
            files: [
                .init("ggml-large-v3-turbo-q5_0.bin", 574041195, "394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2"),
            ],
        ),
        ModelInfo(
            id: "whisper-turbo", family: .whisper, name: "Whisper Turbo",
            summaryFR: "Whisper Turbo complet, un peu plus juste que le compact.",
            summaryEN: "Full Whisper Turbo, a little more accurate than compact.",
            languagesFR: "99 langues", languagesEN: "99 languages",
            speed: 2, accuracy: 3, memoryGB: 16, minMacOS: 14, port: 8195,
            folder: "whisper",
            repo: "ggerganov/whisper.cpp", revision: "5359861c739e955e79d9a303bcbc70fb988958b1",
            files: [
                .init("ggml-large-v3-turbo.bin", 1624555275, "1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69"),
            ],
        ),
        ModelInfo(
            id: "whisper-large-v3", family: .whisper, name: "Whisper Large v3",
            summaryFR: "Le plus précis de Whisper, mais lent. Pour un Mac puissant.",
            summaryEN: "The most accurate Whisper, but slow. For a powerful Mac.",
            languagesFR: "99 langues", languagesEN: "99 languages",
            speed: 1, accuracy: 3, memoryGB: 16, minMacOS: 14, port: 8196,
            folder: "whisper",
            repo: "ggerganov/whisper.cpp", revision: "5359861c739e955e79d9a303bcbc70fb988958b1",
            files: [
                .init("ggml-large-v3.bin", 3095033483, "64d182b440b98d5203c4f9bd541544d84c605196c4f7b845dfa11fb23594d1e2"),
            ],
        ),
        ModelInfo(
            id: "cloud", family: .cloud, name: "En ligne",
            summaryFR: "Un service de transcription en ligne, avec votre propre clé API. La voix quitte le Mac.",
            summaryEN: "An online transcription service, with your own API key. Your voice leaves the Mac.",
            languagesFR: "Selon le service", languagesEN: "Depends on the service",
            speed: 2, accuracy: 3, memoryGB: 0, minMacOS: 14, port: 0, folder: ""
        ),
    ]
}

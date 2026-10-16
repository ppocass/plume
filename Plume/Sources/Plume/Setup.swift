import Foundation
import Security

/// Réglages propres à un Mac, hors de l'app et du dépôt :
/// `~/.config/plume/local.json`. Sans ce fichier, Plume se comporte comme la
/// version téléchargée (moteurs rangés dans l'app, modèles téléchargés,
/// nettoyage avec sa propre clé API, vocabulaire vide).
///
/// Toutes les clés sont facultatives :
/// ```json
/// {
///   "polish": { "name": "My server", "url": "http://10.0.0.2:3001/v1/chat/completions",
///               "model": "my-model", "keyFile": "~/.config/my-server/key", "reasoning": true },
///   "whisper": { "binary": "/opt/homebrew/bin/whisper-server", "model": "~/models/ggml-large-v3-turbo-q5_0.bin" },
///   "parakeetBinary": "~/bin/parakeet-server",
///   "sharedEngineNote": { "fr": "…", "en": "…" },
///   "vocabularySeed": [ { "word": "Plume", "variants": ["plum"] } ],
///   "bundleIdentifier": "…", "signingIdentity": "…"
/// }
/// ```
/// Les deux dernières ne servent qu'à `make-app.sh` / `make-dmg.sh`.
struct LocalConfig: Decodable {
    struct Polish: Decodable {
        var name: String?
        var url: String
        var model: String
        var keyFile: String?
        var reasoning: Bool?
    }
    struct Whisper: Decodable {
        var binary: String?
        var model: String?
    }
    struct Text: Decodable {
        var fr: String
        var en: String
    }
    struct Seed: Decodable {
        var word: String
        var variants: [String]?
    }

    var polish: Polish?
    var whisper: Whisper?
    var parakeetBinary: String?
    var sharedEngineNote: Text?
    var vocabularySeed: [Seed]?

    static let url: URL = {
        if let path = ProcessInfo.processInfo.environment["PLUME_LOCAL_CONFIG"] { return URL(fileURLWithPath: path) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/plume/local.json")
    }()

    /// `nil` si le fichier manque, est illisible, ou si on simule un autre Mac.
    static let current: LocalConfig? = {
        guard !Setup.simulatePortable, let data = try? Data(contentsOf: url) else { return nil }
        do {
            return try JSONDecoder().decode(LocalConfig.self, from: data)
        } catch {
            Log.info("local.json ignored: \(error.localizedDescription)")
            return nil
        }
    }()

    static func expand(_ path: String) -> String { (path as NSString).expandingTildeInPath }
}

/// Ce que Plume trouve sur le Mac où elle tourne.
enum Setup {
    static let home = FileManager.default.homeDirectoryForCurrentUser
    private static let fm = FileManager.default

    /// `PLUME_DEMO=1` : pour les captures d'écran — pas de raccourci, pas
    /// d'ouverture de session ni de mise à jour, autorisations affichées comme
    /// accordées. À lancer avec `PLUME_DATA_DIR` vers des données de démo.
    static let demo = ProcessInfo.processInfo.environment["PLUME_DEMO"] == "1"

    /// `PLUME_PORTABLE=1` : se comporter comme sur un Mac neuf (tests, captures).
    static let simulatePortable = ProcessInfo.processInfo.environment["PLUME_PORTABLE"] == "1"

    /// Historique, vocabulaire et modèles. `PLUME_DATA_DIR` le déplace (tests).
    static let dataFolder: URL = {
        let dir: URL
        if let custom = ProcessInfo.processInfo.environment["PLUME_DATA_DIR"] {
            dir = URL(fileURLWithPath: custom, isDirectory: true)
        } else {
            dir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Plume", isDirectory: true)
        }
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static var modelsFolder: URL {
        let dir = dataFolder.appendingPathComponent("Models", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Le serveur de nettoyage de `local.json`, si son fichier de clé existe.
    static var localPolish: LocalConfig.Polish? {
        guard let p = LocalConfig.current?.polish else { return nil }
        if let keyFile = p.keyFile, !fm.fileExists(atPath: LocalConfig.expand(keyFile)) { return nil }
        return p
    }

    /// Texte sous la section Moteur (par exemple les autres apps qui le partagent).
    static var sharedEngineNote: String? {
        LocalConfig.current?.sharedEngineNote.map { L($0.fr, $0.en) }
    }

    private static func bundled(_ name: String) -> String? {
        let path = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/\(name)").path
        return fm.isExecutableFile(atPath: path) ? path : nil
    }

    /// `local.json` d'abord (moteur partagé avec d'autres apps), sinon la copie rangée dans Plume.app.
    static var parakeetBinary: String? {
        if let p = LocalConfig.current?.parakeetBinary.map(LocalConfig.expand), fm.isExecutableFile(atPath: p) { return p }
        return bundled("parakeet-server")
    }

    static var whisperBinary: String? {
        if let p = LocalConfig.current?.whisper?.binary.map(LocalConfig.expand), fm.isExecutableFile(atPath: p) { return p }
        return bundled("whisper-server")
    }

    /// Un fichier de modèle Whisper donné par `local.json` (utilisé à la place
    /// du modèle du catalogue qui porte le même nom).
    static var localWhisperModel: URL? {
        guard let p = LocalConfig.current?.whisper?.model.map(LocalConfig.expand), fm.fileExists(atPath: p) else { return nil }
        return URL(fileURLWithPath: p)
    }

    /// Là où FluidAudio range les modèles qu'il télécharge lui-même. Plume en
    /// réutilise la copie plutôt que de la télécharger deux fois.
    static var fluidAudioModels: URL {
        home.appendingPathComponent("Library/Application Support/FluidAudio/Models", isDirectory: true)
    }

    /// Mémoire du Mac en Go (8, 16, 24…).
    static var memoryGB: Int { Int((Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824).rounded()) }

    /// "Apple M1", "Apple M3 Pro"…
    static var chipName: String {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        guard size > 0 else { return "" }
        var buffer = [CChar](repeating: 0, count: size)
        sysctlbyname("machdep.cpu.brand_string", &buffer, &size, nil, 0)
        return String(cString: buffer)
    }

    /// Puce Pro, Max ou Ultra (plus de cœurs graphiques pour Whisper).
    static var isProChip: Bool {
        let name = chipName
        return name.contains("Pro") || name.contains("Max") || name.contains("Ultra")
    }

    static var macOSMajor: Int { ProcessInfo.processInfo.operatingSystemVersion.majorVersion }

    /// Mémoire libre ou récupérable tout de suite, en Go (pages libres,
    /// inactives, purgeables). Relevée une fois au lancement : le conseil de
    /// modèle ne doit pas changer d'une minute à l'autre.
    static let availableMemoryGB: Double = {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return Double(memoryGB) / 2 }
        let pages = UInt64(stats.free_count) + UInt64(stats.inactive_count) + UInt64(stats.purgeable_count)
            + UInt64(stats.speculative_count)
        return Double(pages) * Double(vm_kernel_page_size) / 1_073_741_824
    }()

    /// La langue du Mac (« fr », « en »…).
    static var systemLanguage: String { String((Locale.preferredLanguages.first ?? "en").prefix(2)) }
}

/// Les clés API, dans le trousseau (jamais dans les réglages ni dans le journal).
enum KeychainStore {
    private static var service: String { (Bundle.main.bundleIdentifier ?? "plume") + ".polish" }

    static func read(_ account: String) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account,
                                    kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data, let s = String(data: data, encoding: .utf8) else { return nil }
        return s.isEmpty ? nil : s
    }

    static func write(_ account: String, _ value: String) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service,
                                   kSecAttrAccount as String: account]
        SecItemDelete(base as CFDictionary)
        guard !value.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }
}

/// Les adresses joignables sans HTTPS : ce Mac et les réseaux privés
/// seulement. Tout ce qui est sur Internet doit être en HTTPS (la clé API et
/// le texte partent avec la requête).
enum EndpointPolicy {
    static func isAllowed(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased(), !host.isEmpty else { return false }
        if scheme == "https" { return true }
        guard scheme == "http" else { return false }
        return isLocal(host)
    }

    static func isLocal(_ host: String) -> Bool {
        if host == "localhost" || host.hasSuffix(".local") || host == "::1" || host == "[::1]" { return true }
        let parts = host.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4, parts.allSatisfy({ (0...255).contains($0) }) else { return false }
        switch (parts[0], parts[1]) {
        case (127, _), (10, _), (192, 168): return true
        case (172, 16...31): return true
        case (100, 64...127): return true   // plage CGNAT des réseaux privés virtuels (Tailscale…)
        case (169, 254): return true
        default: return false
        }
    }
}

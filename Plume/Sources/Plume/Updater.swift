import AppKit
import Security

/// Mises à jour depuis les releases GitHub du projet.
///
/// - Vérification au lancement (une fois par jour au plus, désactivable) et
///   à la demande (Réglages, menu Plume).
/// - Installation : le `Plume.dmg` de la dernière release est téléchargé en
///   https, son empreinte comparée à celle des notes de version, puis la
///   nouvelle app n'est installée **que si elle est signée par le même
///   certificat** que celle qui tourne (exigence de signature de l'app
///   actuelle). Elle remplace l'ancienne au même endroit, puis Plume redémarre.
/// - **La configuration est conservée** : réglages (UserDefaults, liés à
///   l'identifiant de l'app), historique, vocabulaire et modèles
///   (`~/Library/Application Support/Plume`), clés (trousseau) vivent hors
///   de l'app. Même identifiant + même signature → macOS garde aussi les
///   autorisations Micro et Accessibilité.
/// - Seulement pour la version publiée (`io.github.ppocass.plume`) : une app
///   compilée sur place (`make-app.sh`) se met à jour par ses sources.
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()
    nonisolated static let repo = "ppocass/plume"
    static let publicBundleID = "io.github.ppocass.plume"

    enum State: Equatable {
        case idle, checking, upToDate
        case available(String)
        case downloading, installing
        case failed(String)
    }

    struct Release: Equatable {
        let version: String
        let dmg: URL
        let sha256: String?
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var latest: Release?
    @Published var autoCheck: Bool {
        didSet { UserDefaults.standard.set(autoCheck, forKey: "autoCheckUpdates") }
    }

    private init() {
        autoCheck = UserDefaults.standard.object(forKey: "autoCheckUpdates") as? Bool ?? true
    }

    var isSupported: Bool { Bundle.main.bundleIdentifier == Self.publicBundleID }
    static var currentVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0" }

    /// « 1.10 » > « 1.9 » ; les parties manquantes valent 0.
    nonisolated static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// Au lancement : une vérification par jour, sans rien montrer s'il n'y a rien.
    func checkAtLaunchIfNeeded() {
        guard isSupported, autoCheck else { return }
        let last = UserDefaults.standard.double(forKey: "lastUpdateCheck")
        guard Date().timeIntervalSince1970 - last > 86_400 else { return }
        Task { await check(userInitiated: false) }
    }

    func check(userInitiated: Bool) async {
        guard isSupported else { return }
        state = .checking
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "lastUpdateCheck")
        do {
            let release = try await Self.fetchLatest()
            latest = release
            if Self.isNewer(release.version, than: Self.currentVersion) {
                state = .available(release.version)
                Log.info("mise à jour disponible : \(release.version)")
                if !userInitiated { offer(release) }
            } else {
                state = .upToDate
            }
        } catch {
            Log.info("vérification des mises à jour impossible : \(error.localizedDescription)")
            state = userInitiated ? .failed(error.localizedDescription) : .idle
        }
    }

    /// Propose la mise à jour trouvée en arrière-plan.
    private func offer(_ release: Release) {
        let alert = NSAlert()
        alert.messageText = L("Plume \(release.version) est disponible", "Plume \(release.version) is available")
        alert.informativeText = L("Vous avez la version \(Self.currentVersion). Vos réglages, votre historique et vos modèles sont conservés.",
                                  "You have version \(Self.currentVersion). Your settings, history and models are kept.")
        alert.addButton(withTitle: L("Mettre à jour", "Update"))
        alert.addButton(withTitle: L("Plus tard", "Later"))
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn { Task { await install() } }
    }

    // MARK: Installation

    enum Failure: LocalizedError {
        case noAsset, badLocation, checksum, signature, mount, copy(String)
        var errorDescription: String? {
            switch self {
            case .noAsset: return L("Aucun fichier Plume.dmg dans la dernière version", "No Plume.dmg in the latest release")
            case .badLocation: return L("Glissez d'abord Plume dans le dossier Applications", "Move Plume to the Applications folder first")
            case .checksum: return L("Fichier téléchargé corrompu", "Downloaded file is corrupted")
            case .signature: return L("Signature de la nouvelle version refusée", "The new version's signature was refused")
            case .mount: return L("Impossible d'ouvrir l'image disque", "Couldn't open the disk image")
            case .copy(let why): return L("Installation impossible : ", "Couldn't install: ") + why
            }
        }
    }

    func install() async {
        guard let release = latest, isSupported else { return }
        let appURL = Bundle.main.bundleURL
        let path = appURL.path
        // Lancée depuis l'image disque ou « mise en quarantaine » par macOS : rien à remplacer.
        if path.hasPrefix("/Volumes/") || path.contains("/AppTranslocation/")
            || !FileManager.default.isWritableFile(atPath: appURL.deletingLastPathComponent().path) {
            state = .failed(Failure.badLocation.localizedDescription)
            return
        }
        state = .downloading
        do {
            let (tmp, response) = try await URLSession.shared.download(from: release.dmg)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw Failure.noAsset }
            let work = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                                   appropriateFor: appURL, create: true)
            let dmg = work.appendingPathComponent("Plume.dmg")
            try FileManager.default.moveItem(at: tmp, to: dmg)
            if let expected = release.sha256, try ModelDownloader.sha256(of: dmg) != expected { throw Failure.checksum }

            state = .installing
            let mount = work.appendingPathComponent("volume", isDirectory: true)
            try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
            guard Self.run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-noverify", "-mountpoint", mount.path, dmg.path]) else {
                throw Failure.mount
            }
            defer { _ = Self.run("/usr/bin/hdiutil", ["detach", "-quiet", mount.path]) }
            let fresh = work.appendingPathComponent("Plume.app")
            try FileManager.default.copyItem(at: mount.appendingPathComponent("Plume.app"), to: fresh)
            guard Self.signedLikeMe(fresh) else { throw Failure.signature }

            _ = try FileManager.default.replaceItemAt(appURL, withItemAt: fresh)
            Log.info("mise à jour installée : \(release.version), redémarrage")
            relaunch(appURL)
        } catch {
            Log.info("mise à jour impossible : \(error.localizedDescription)")
            state = .failed(error.localizedDescription)
        }
    }

    /// `Plume --update-dry-run` : tout le chemin d'une mise à jour (dernière
    /// release, téléchargement, empreinte, image disque, signature), sans
    /// remplacer l'app.
    nonisolated static func dryRun() async -> Int32 {
        do {
            let r = try await fetchLatest()
            print("dernière version : \(r.version) · \(r.dmg.absoluteString) · empreinte \(r.sha256 ?? "absente")")
            let (tmp, _) = try await URLSession.shared.download(from: r.dmg)
            let sum = try ModelDownloader.sha256(of: tmp)
            print("empreinte du fichier téléchargé : \(sum == r.sha256 ? "conforme" : "DIFFÉRENTE")")
            let mount = FileManager.default.temporaryDirectory.appendingPathComponent("plume-maj-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
            guard run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-noverify", "-mountpoint", mount.path, tmp.path]) else {
                print("❌ image disque illisible"); return 1
            }
            defer { run("/usr/bin/hdiutil", ["detach", "-quiet", mount.path]); try? FileManager.default.removeItem(at: tmp) }
            let ok = signedLikeMe(mount.appendingPathComponent("Plume.app"))
            print("signature de la nouvelle app : \(ok ? "même certificat, acceptée" : "REFUSÉE")")
            return sum == r.sha256 && ok ? 0 : 1
        } catch {
            print("❌ \(error.localizedDescription)")
            return 1
        }
    }

    /// La nouvelle app satisfait l'exigence de signature de celle qui tourne
    /// (même identifiant, même certificat).
    nonisolated static func signedLikeMe(_ app: URL) -> Bool {
        var me: SecCode?
        var meStatic: SecStaticCode?
        var requirement: SecRequirement?
        var other: SecStaticCode?
        guard SecCodeCopySelf([], &me) == errSecSuccess, let me,
              SecCodeCopyStaticCode(me, [], &meStatic) == errSecSuccess, let meStatic,
              SecCodeCopyDesignatedRequirement(meStatic, [], &requirement) == errSecSuccess, let requirement,
              SecStaticCodeCreateWithPath(app as CFURL, [], &other) == errSecSuccess, let other else { return false }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate)
        return SecStaticCodeCheckValidity(other, flags, requirement) == errSecSuccess
    }

    private func relaunch(_ app: URL) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 1.5; /usr/bin/open \"$0\"", app.path]
        try? p.run()
        NSApp.terminate(nil)
    }

    @discardableResult
    nonisolated static func run(_ tool: String, _ args: [String]) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    // MARK: GitHub

    nonisolated static func fetchLatest() async throws -> Release {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Plume/\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalCacheData   // sinon une réponse d'il y a une minute
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw Failure.noAsset }
        return try parse(data)
    }

    /// Lit la réponse de l'API : version (`v1.3` → `1.3`), fichier `Plume.dmg`,
    /// et l'empreinte écrite dans les notes (« SHA-256 of Plume.dmg: `…` »).
    nonisolated static func parse(_ data: Data) throws -> Release {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String,
              let assets = json["assets"] as? [[String: Any]],
              let asset = assets.first(where: { $0["name"] as? String == "Plume.dmg" }),
              let link = (asset["browser_download_url"] as? String).flatMap(URL.init(string:)),
              link.scheme == "https" else { throw Failure.noAsset }
        let body = json["body"] as? String ?? ""
        var sha: String?
        if let r = body.range(of: #"SHA-256 of Plume\.dmg: `([0-9a-f]{64})`"#, options: .regularExpression) {
            sha = String(body[r].suffix(66).dropFirst().dropLast())
        }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        return Release(version: version, dmg: link, sha256: sha)
    }
}

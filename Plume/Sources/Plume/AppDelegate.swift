import AppKit
import ApplicationServices
import SwiftUI

@main
enum PlumeMain {
    static func main() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--selftest-polish") {
            let texts = Array(args[(i + 1)...])
            Task { exit(await SelfTest.polishOnly(texts)) }
            dispatchMain()
        }
        if let i = args.firstIndex(of: "--download-model"), i + 1 < args.count {
            let id = args[i + 1]
            Task { exit(await SelfTest.download(id)) }
            dispatchMain()
        }
        if let i = args.firstIndex(of: "--update-install-test"), i + 1 < args.count {
            let target = args[i + 1]
            Task { exit(await Updater.installTest(target)) }
            dispatchMain()
        }
        if args.contains("--update-dry-run") {
            Task { exit(await Updater.dryRun()) }
            dispatchMain()
        }
        if args.contains("--unit-tests") {
            MainActor.assumeIsolated { exit(UnitTests.run()) }
        }
        if let i = args.firstIndex(of: "--selftest") {
            let files = Array(args[(i + 1)...])
            Task {
                let failures = await SelfTest.run(files)
                exit(failures)
            }
            dispatchMain()
        }
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            let app = NSApplication.shared
            app.setActivationPolicy(.prohibited)
            MainActor.assumeIsolated { Snapshot.run(into: args[i + 1]) }
            exit(0)
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static var shared: AppDelegate?

    let hotkey = HotkeyMonitor()
    private var hotkeyRetry: Timer?
    private var launchedAsLoginItem = false

    override init() {
        super.init()
        AppDelegate.shared = self
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Lancée à l'ouverture de session → on reste invisible.
        if let event = NSAppleEventManager.shared().currentAppleEvent,
           event.eventID == kAEOpenApplication,
           event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem {
            launchedAsLoginItem = true
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Une seule Plume à la fois.
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        if let other = others.first {
            other.activate()
            NSApp.terminate(nil)
            return
        }

        Log.info("Plume démarre (\(launchedAsLoginItem ? "ouverture de session" : "lancement manuel"))")
        installTerminationSignals()
        Task.detached {
            for model in ModelCatalog.local {
                await SpeechEngine.engine(for: model).cleanUpOrphanAtLaunch(idleSeconds: Prefs.idleSeconds)
            }
        }
        // Modèle manquant (supprimé, ou mise à jour d'une ancienne version) : on
        // le télécharge. Au tout premier lancement, c'est l'assistant qui s'en charge.
        if Prefs.shared.onboardingDone { ModelStore.shared.prefetchDefaultIfNeeded() }
        NSApp.mainMenu = buildMenu()

        let controller = DictationController.shared
        controller.onOpenWindow = { MainWindowController.shared.show() }
        hotkey.shortcut = Prefs.shared.shortcut
        hotkey.onTap = { DictationController.shared.handleTap() }
        startHotkey()

        // Les apps Electron n'exposent leurs champs de texte qu'à la demande.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { note in
            if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
                TextInserter.enableManualAccessibility(pid: app.processIdentifier)
            }
        }
        if let front = NSWorkspace.shared.frontmostApplication {
            TextInserter.enableManualAccessibility(pid: front.processIdentifier)
        }
        StatusItemController.shared.update()

        let prefs = Prefs.shared
        prefs.appearance.apply()
        if prefs.isFirstLaunch {
            prefs.isFirstLaunch = false
            // Plume doit tourner pour que la touche marche : ouverture de
            // session activée d'office (désactivable dans les réglages).
            Permissions.shared.setLaunchAtLogin(true)
        }
        Permissions.shared.refresh()

        // Premier lancement : l'assistant. Ensuite, la fenêtre à l'ouverture,
        // sauf au démarrage du Mac si tout est en ordre.
        let showedNews = VersionTracker.handleLaunch()
        if !prefs.onboardingDone {
            OnboardingWindowController.shared.show()
        } else if !showedNews && (!launchedAsLoginItem || !Permissions.shared.allGood) {
            MainWindowController.shared.show()
        }
        Updater.shared.checkAtLaunchIfNeeded()
    }

    /// Le tap clavier exige l'Accessibilité : on réessaie toutes les 2 s tant
    /// qu'elle n'est pas accordée (aucune relance de l'app nécessaire).
    private func startHotkey() {
        // Sans l'Accessibilité, macOS crée quand même le tap… mais ne lui envoie
        // aucune touche, et il resterait sourd après l'autorisation. On attend
        // donc qu'elle soit accordée pour le créer.
        if AXIsProcessTrusted(), hotkey.start() {
            hotkeyRetry?.invalidate()
            hotkeyRetry = nil
            Permissions.shared.refresh()
            return
        }
        guard hotkeyRetry == nil else { return }
        Log.info("touche de dictée en attente de l'autorisation Accessibilité")
        hotkeyRetry = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.startHotkey() }
        }
    }

    /// Spotlight (ou un double-clic) sur Plume déjà lancée → la fenêtre.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainWindowController.shared.show()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        // On ne laisse jamais derrière nous un moteur que NOUS avons lancé.
        SpeechEngine.killOwnedNow()
        Log.info("Plume quitte")
    }

    /// `kill`, déconnexion, arrêt du Mac : macOS envoie SIGTERM, et
    /// `applicationWillTerminate` n'est PAS appelé. Sans ça, le moteur lancé
    /// par Plume resterait orphelin.
    private var signalSources: [DispatchSourceSignal] = []
    private func installTerminationSignals() {
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler {
                SpeechEngine.killOwnedNow()
                Log.info("Plume arrêtée par un signal (\(sig))")
                exit(0)
            }
            source.resume()
            signalSources.append(source)
        }
    }

    // MARK: Menus

    @objc private func openSettings() { MainWindowController.shared.show(section: .settings) }
    @objc private func reportIssue() { IssueReporter.open() }
    @objc private func checkUpdates() {
        MainWindowController.shared.show(section: .settings)
        Task { await Updater.shared.check(userInitiated: true) }
    }
    @objc private func openHistory() { MainWindowController.shared.show(section: .history) }

    /// Menu refait quand on change la langue de l'interface.
    func rebuildMenu() { NSApp.mainMenu = buildMenu() }

    private func buildMenu() -> NSMenu {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: L("À propos de Plume", "About Plume"), action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        if Updater.shared.isSupported {
            let update = appMenu.addItem(withTitle: L("Rechercher les mises à jour…", "Check for Updates…"), action: #selector(checkUpdates), keyEquivalent: "")
            update.target = self
        }
        let report = appMenu.addItem(withTitle: L("Signaler un problème…", "Report a Problem…"), action: #selector(reportIssue), keyEquivalent: "")
        report.target = self
        appMenu.addItem(.separator())
        let settings = appMenu.addItem(withTitle: L("Réglages…", "Settings…"), action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L("Masquer Plume", "Hide Plume"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L("Quitter Plume", "Quit Plume"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: L("Édition", "Edit"))
        edit.addItem(withTitle: L("Annuler", "Undo"), action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: L("Rétablir", "Redo"), action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: L("Couper", "Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: L("Copier", "Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: L("Coller", "Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: L("Tout sélectionner", "Select All"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(.separator())
        let find = edit.addItem(withTitle: L("Rechercher dans l'historique", "Search History"), action: #selector(openHistory), keyEquivalent: "f")
        find.target = self
        editItem.submenu = edit
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let window = NSMenu(title: L("Fenêtre", "Window"))
        window.addItem(withTitle: L("Fermer", "Close"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        window.addItem(withTitle: L("Réduire", "Minimize"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = window
        main.addItem(windowItem)
        NSApp.windowsMenu = window

        return main
    }
}

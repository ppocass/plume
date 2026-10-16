import AppKit
import SwiftUI

/// Les nouveautés des versions importantes, montrées une fois après une mise
/// à jour (pas à une première installation : l'assistant suffit). Pour une
/// nouvelle version majeure, ajouter une entrée à `ReleaseNotes.all`.
struct ReleaseNotes {
    struct Page {
        let symbol: String
        let titleFR, titleEN: String
        let textFR, textEN: String
    }
    let version: String
    let pages: [Page]

    static let all: [ReleaseNotes] = [
        ReleaseNotes(version: "1.3", pages: [
            Page(symbol: "cpu", titleFR: "Choisissez votre modèle", titleEN: "Choose your model",
                 textFR: "Parakeet Ultra, Whisper jusqu'à Large v3 pour les Mac puissants, ou un service en ligne avec votre clé. Page Modèles.",
                 textEN: "Parakeet Ultra, Whisper up to Large v3 for powerful Macs, or an online service with your own key. See Models."),
            Page(symbol: "arrow.down.circle", titleFR: "Mises à jour", titleEN: "Updates",
                 textFR: "Plume se met à jour toute seule depuis GitHub. Vos réglages, votre historique et vos modèles sont conservés.",
                 textEN: "Plume now updates itself from GitHub. Your settings, history and models are kept."),
            Page(symbol: "menubar.rectangle", titleFR: "Barre des menus", titleEN: "Menu bar",
                 textFR: "Une icône facultative pour dicter, copier la dernière dictée ou ouvrir l'historique. Réglages → Général.",
                 textEN: "An optional icon to dictate, copy your last dictation or open History. Settings → General."),
            Page(symbol: "sparkles", titleFR: "Nettoyage en anglais", titleEN: "Cleanup in English",
                 textFR: "La consigne du nettoyage existe aussi en anglais, et suit la langue que vous parlez.",
                 textEN: "The cleanup instructions now exist in English too, and follow the language you speak."),
        ]),
    ]

    /// Les pages à montrer en passant de `from` à `to` (versions majeures entre les deux).
    static func pages(from: String, to: String) -> [Page] {
        all.filter { Updater.isNewer($0.version, than: from) && !Updater.isNewer($0.version, than: to) }.flatMap(\.pages)
    }
}

/// Au lancement : ce qui change d'une version à l'autre.
@MainActor
enum VersionTracker {
    /// Retient la version qui tourne, et montre les nouveautés si c'est une
    /// mise à jour. Renvoie `true` si la fenêtre des nouveautés s'ouvre.
    @discardableResult
    static func handleLaunch() -> Bool {
        let d = UserDefaults.standard
        let current = Updater.currentVersion
        let previous = d.string(forKey: "lastRunVersion")
        d.set(current, forKey: "lastRunVersion")
        // Installée avant que la version soit notée : la 1.2.
        let from = previous ?? (Prefs.shared.onboardingDone ? "1.2" : current)
        guard Prefs.shared.onboardingDone, Updater.isNewer(current, than: from) else { return false }
        Log.info("mise à jour \(from) → \(current)")
        let pages = ReleaseNotes.pages(from: from, to: current)
        guard !pages.isEmpty else { return false }
        WhatsNewWindowController.shared.show(pages: pages)
        return true
    }
}

@MainActor
final class WhatsNewWindowController: NSObject, NSWindowDelegate {
    static let shared = WhatsNewWindowController()
    private var window: NSWindow?

    func show(pages: [ReleaseNotes.Page]) {
        let root = WhatsNewView(pages: pages) { [weak self] in self?.window?.close() }
            .environmentObject(Prefs.shared)
            .tint(.plumeTheme)
            .focusEffectDisabled()
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 500),
                         styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        w.contentViewController = NSHostingController(rootView: root)
        w.setContentSize(NSSize(width: 560, height: 500))
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isMovableByWindowBackground = true
        w.isReleasedWhenClosed = false
        w.delegate = self
        window = w
        NSApp.setActivationPolicy(.regular)
        w.center()
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        w.clearInitialFocus()
    }

    func windowWillClose(_ notification: Notification) {
        DispatchQueue.main.async {
            self.window?.contentViewController = nil
            self.window = nil
            if !MainWindowController.shared.isOpen { NSApp.setActivationPolicy(.accessory) }
        }
    }
}

struct WhatsNewView: View {
    let pages: [ReleaseNotes.Page]
    let done: () -> Void
    @State private var index = 0
    @State private var forward = true

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                let p = pages[index]
                StepPage(icon: .symbol(p.symbol), title: L(p.titleFR, p.titleEN), subtitle: L(p.textFR, p.textEN)) {
                    EmptyView()
                }
                .id(index)
                .transition(.asymmetric(
                    insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity),
                    removal: .move(edge: forward ? .leading : .trailing).combined(with: .opacity)))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()

            HStack {
                Button(L("Retour", "Back")) { go(-1) }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .opacity(index == 0 ? 0 : 1).disabled(index == 0)
                    .frame(width: 110, alignment: .leading)
                Spacer()
                HStack(spacing: 7) {
                    ForEach(pages.indices, id: \.self) { i in
                        Circle().fill(i == index ? Color.plumeTheme : Color.secondary.opacity(0.3)).frame(width: 7, height: 7)
                    }
                }
                Spacer()
                Button(index == pages.count - 1 ? L("C'est parti", "Got It") : L("Suivant", "Next")) {
                    index == pages.count - 1 ? done() : go(1)
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .frame(width: 110, alignment: .trailing)
            }
            .padding(.horizontal, 28).padding(.vertical, 22)
        }
        .frame(width: 560, height: 500)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .top) {
            Text(L("Nouveautés de Plume \(Updater.currentVersion)", "What's new in Plume \(Updater.currentVersion)"))
                .font(.callout.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 18)
        }
    }

    private func go(_ delta: Int) {
        let next = index + delta
        guard pages.indices.contains(next) else { return }
        forward = delta > 0
        withAnimation(.spring(response: 0.42, dampingFraction: 0.88)) { index = next }
    }
}

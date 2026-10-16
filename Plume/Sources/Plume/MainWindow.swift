import AppKit
import SwiftUI

/// La fenêtre de Plume (Accueil, Historique, Vocabulaire, Modèles, Réglages) :
/// `NavigationSplitView` avec la sidebar de verre flottante de macOS 26, une
/// vraie barre de titre (sans elle la sidebar ne flotte plus), fond opaque à droite.
///
/// Elle n'existe que quand on l'ouvre (Spotlight, clic sur la pastille, ⌘,) ;
/// Plume passe alors au premier plan avec une icône dans le Dock, et la perd
/// quand on ferme la fenêtre.
@MainActor
final class MainWindowController: NSObject, NSWindowDelegate {
    static let shared = MainWindowController()
    private var window: NSWindow?
    let navigation = Navigation()
    var isOpen: Bool { window != nil }

    func show(section: SidebarItem? = nil) {
        if let section { navigation.selection = section }
        if window == nil { build() }
        NSApp.setActivationPolicy(.regular)
        Permissions.shared.refresh()
        Task { await SpeechEngine.shared.refreshState() }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window?.clearInitialFocus()
    }

    private func build() {
        let controller = NSHostingController(rootView: MainView()
            .environmentObject(navigation)
            .environmentObject(HistoryStore.shared)
            .environmentObject(Prefs.shared)
            .environmentObject(Permissions.shared)
            .environmentObject(EngineStatus.shared)
            .environmentObject(VocabularyStore.shared)
            .environmentObject(ModelStore.shared)
            .tint(.plumeTheme))
        // La barre d'outils et le titre déclarés en SwiftUI passent dans la
        // vraie barre de titre de la fenêtre AppKit.
        controller.sceneBridgingOptions = [.toolbars, .title]
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 580),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.contentViewController = controller
        w.title = "Plume"
        w.toolbarStyle = .unified
        w.minSize = NSSize(width: 680, height: 440)
        w.setContentSize(NSSize(width: 860, height: 580))
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.setFrameAutosaveName("PlumeMainWindow")
        if !w.setFrameUsingName("PlumeMainWindow") { w.center() }
        window = w
    }

    func windowWillClose(_ notification: Notification) {
        // Plus de fenêtre : Plume retourne en arrière-plan (pas d'icône au Dock),
        // et on libère toute la fenêtre (vues SwiftUI comprises) : au repos,
        // Plume ne doit garder en mémoire que l'écoute de la touche.
        DispatchQueue.main.async {
            NSApp.setActivationPolicy(.accessory)
            self.window?.contentViewController = nil
            self.window = nil
        }
    }
}

enum SidebarItem: String, CaseIterable, Identifiable {
    case home, history, vocabulary, models, settings
    var id: String { rawValue }
    var title: String {
        switch self {
        case .home: return L("Accueil", "Home")
        case .history: return L("Historique", "History")
        case .vocabulary: return L("Vocabulaire", "Vocabulary")
        case .models: return L("Modèles", "Models")
        case .settings: return L("Réglages", "Settings")
        }
    }
    var symbol: String {
        switch self {
        case .home: return "waveform"
        case .history: return "clock.arrow.circlepath"
        case .vocabulary: return "character.book.closed"
        case .models: return "cpu"
        case .settings: return "gearshape"
        }
    }
}

@MainActor
final class Navigation: ObservableObject {
    @Published var selection: SidebarItem = .home
}

struct MainView: View {
    @EnvironmentObject var navigation: Navigation
    @EnvironmentObject var permissions: Permissions
    @EnvironmentObject var prefs: Prefs

    var body: some View {
        let split = NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 280)
        } detail: {
            Group {
                switch navigation.selection {
                case .home: HomeView()
                case .history: HistoryView()
                case .vocabulary: VocabularyView()
                case .models: ModelsView()
                case .settings: SettingsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .navigationTitle(navigation.selection.title)
        .task {
            // Tant que la fenêtre est là : les coches d'autorisation suivent
            // ce qui se passe dans Réglages Système.
            while !Task.isCancelled {
                permissions.refresh()
                await SpeechEngine.shared.refreshState()
                try? await Task.sleep(for: .seconds(2))
            }
        }

        Group {
            if #available(macOS 15.0, *) {
                split.toolbar(removing: .sidebarToggle)
            } else {
                split
            }
        }
        // Changer de langue redessine toute la fenêtre.
        .id(prefs.appLanguage)
        .focusEffectDisabled()
        // Nouvelle page : macOS donnerait le focus clavier à son premier contrôle.
        .onChange(of: navigation.selection) { _, _ in NSApp.keyWindow?.clearInitialFocus() }
    }
}

// MARK: - Sidebar

/// `List` + `.listStyle(.sidebar)` +
/// `.scrollContentBackground(.hidden)` pour laisser voir le verre système, et
/// PAS de `List(selection:)` (la sélection native change d'aspect quand la
/// fenêtre perd le focus) : on dessine la rangée nous-mêmes.
struct SidebarView: View {
    @EnvironmentObject var navigation: Navigation
    @EnvironmentObject var history: HistoryStore
    @EnvironmentObject var permissions: Permissions

    var body: some View {
        List {
            Section {
                ForEach(SidebarItem.allCases) { item in
                    SidebarRow(title: item.title, systemImage: item.symbol,
                               isSelected: navigation.selection == item,
                               badge: badge(for: item)) {
                        navigation.selection = item
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .modifier(SidebarFooterBar())
    }

    private func badge(for item: SidebarItem) -> SidebarRow.Badge? {
        switch item {
        case .settings where !permissions.allGood: return .warning
        case .history where !history.items.isEmpty: return .count(history.items.count)
        default: return nil
        }
    }
}

struct SidebarRow: View {
    enum Badge: Equatable { case count(Int), warning }

    let title: String
    let systemImage: String
    let isSelected: Bool
    var badge: Badge? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 0) {
                Label {
                    Text(title)
                        .lineLimit(1)
                        .fontWeight(isSelected ? .semibold : .regular)
                        .foregroundStyle(.primary)
                } icon: {
                    Image(systemName: systemImage)
                        .foregroundStyle(Color.plumeTheme)
                }
                Spacer(minLength: 6)
                switch badge {
                case .count(let n):
                    Text("\(n)")
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                case .warning:
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundStyle(.orange)
                case nil:
                    EmptyView()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowInsets(EdgeInsets(top: 1, leading: 10, bottom: 1, trailing: 10))
        .listRowBackground(selectionBackground)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder
    private var selectionBackground: some View {
        if isSelected {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.secondary.opacity(0.22))
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
        }
    }
}

/// Pied de sidebar : l'état du moteur, toujours visible. Sur macOS 26, barre
/// native `safeAreaBar`.
struct SidebarFooterBar: ViewModifier {
    func body(content: Content) -> some View {
        Group {
            if #available(macOS 26.0, *) {
                content
                    .safeAreaBar(edge: .bottom, spacing: 0) { SidebarFooter() }
                    .scrollEdgeEffectStyle(.hard, for: .bottom)
            } else {
                content.safeAreaInset(edge: .bottom, spacing: 0) {
                    SidebarFooter().background(.regularMaterial)
                }
            }
        }
        .focusEffectDisabled()
    }
}

struct SidebarFooter: View {
    @EnvironmentObject var engine: EngineStatus
    @EnvironmentObject var models: ModelStore

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(dotColor)
                .frame(width: 7, height: 7)
            Text(shortLabel)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .overlay(alignment: .top) { Divider().padding(.horizontal, 12) }
        .help(engine.state.label)
    }

    /// Un téléchargement en cours passe avant l'état du moteur.
    private var download: Double? { models.progress.values.first }

    private var shortLabel: String {
        if let download { return L("Téléchargement… \(Int(download * 100)) %", "Downloading… \(Int(download * 100))%") }
        let name = ModelStore.active.displayName
        switch engine.state {
        case .sleeping: return L("\(name) en veille", "\(name) idle")
        case .loading: return L("\(name) se charge…", "\(name) loading…")
        case .notInstalled: return L("Modèle à télécharger", "Model not downloaded")
        case .ready(true): return L("\(name) prêt", "\(name) ready")
        case .ready(false): return L("\(name) prêt (partagé)", "\(name) ready (shared)")
        case .online: return L("Transcription en ligne", "Online transcription")
        case .failed: return L("\(name) en erreur", "\(name) error")
        }
    }

    private var dotColor: Color {
        if download != nil { return .plumeThinking }
        switch engine.state {
        case .sleeping: return .secondary.opacity(0.5)
        case .loading, .notInstalled: return .plumeThinking
        case .ready, .online: return .plumeDone
        case .failed: return .red
        }
    }
}

extension NSWindow {
    /// Aucun contrôle ne garde le focus clavier à l'ouverture : sinon macOS le
    /// donne au premier (puis au suivant) et l'entoure d'un cadre gris. La
    /// fenêtre redevient le premier répondeur ; Tab ramène le focus si on le veut.
    /// Refait juste après, car SwiftUI peut le redonner une fois la vue posée.
    func clearInitialFocus() {
        makeFirstResponder(nil)
        DispatchQueue.main.async { [weak self] in self?.makeFirstResponder(nil) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in self?.makeFirstResponder(nil) }
    }
}

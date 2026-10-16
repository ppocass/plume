import AppKit
import SwiftUI

/// L'assistant du premier lancement : une étape par écran, des points en bas
/// pour la progression, « Continuer » à droite. Rouvrable depuis
/// Réglages → « Revoir la configuration… ».
@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    static let shared = OnboardingWindowController()
    private var window: NSWindow?
    let model = OnboardingModel()

    func show() {
        if window == nil { build() }
        NSApp.setActivationPolicy(.regular)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window?.clearInitialFocus()
    }

    private func build() {
        model.step = 0
        model.chosenModel = ModelStore.shared.selectedID
        let root = OnboardingView(finish: { [weak self] in self?.finish() })
            .environmentObject(model)
            .environmentObject(Prefs.shared)
            .environmentObject(Permissions.shared)
            .environmentObject(EngineStatus.shared)
            .environmentObject(ModelStore.shared)
            .tint(.plumeTheme)
            .focusEffectDisabled()
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 540),
                         styleMask: [.titled, .closable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.contentViewController = NSHostingController(rootView: root)
        w.setContentSize(NSSize(width: 560, height: 540))
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isMovableByWindowBackground = true
        w.isReleasedWhenClosed = false
        w.delegate = self
        window = w
    }

    private func finish() {
        Prefs.shared.onboardingDone = true
        window?.close()
        MainWindowController.shared.show()
    }

    func windowWillClose(_ notification: Notification) {
        DispatchQueue.main.async {
            self.window?.contentViewController = nil
            self.window = nil
            if !MainWindowController.shared.isOpen { NSApp.setActivationPolicy(.accessory) }
        }
    }
}

@MainActor
final class OnboardingModel: ObservableObject {
    @Published var step = 0
    /// Sens de la dernière navigation, pour le glissement.
    @Published var forward = true
    /// Le modèle choisi à l'étape Modèle (appliqué en passant à l'étape suivante).
    @Published var chosenModel = ModelCatalog.defaultID
}

enum OnboardingStep {
    case welcome, microphone, accessibility, shortcut, language, model, cleanup, done

    /// Pas d'étape Nettoyage quand `local.json` fournit déjà un serveur.
    static var all: [OnboardingStep] {
        [.welcome, .microphone, .accessibility, .shortcut, .language, .model]
            + (Setup.localPolish != nil ? [] : [.cleanup]) + [.done]
    }
}

struct OnboardingView: View {
    @EnvironmentObject var model: OnboardingModel
    @EnvironmentObject var prefs: Prefs
    @EnvironmentObject var permissions: Permissions
    @EnvironmentObject var models: ModelStore
    let finish: () -> Void

    private var steps: [OnboardingStep] { OnboardingStep.all }
    private var current: OnboardingStep { steps[min(model.step, steps.count - 1)] }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                page(current)
                    .id(model.step)
                    .transition(.asymmetric(
                        insertion: .move(edge: model.forward ? .trailing : .leading).combined(with: .opacity),
                        removal: .move(edge: model.forward ? .leading : .trailing).combined(with: .opacity)))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()

            footer
        }
        .frame(width: 560, height: 540)
        .background(Color(nsColor: .windowBackgroundColor))
        .id(prefs.appLanguage)   // la langue choisie s'applique tout de suite
        .task {
            while !Task.isCancelled {
                permissions.refresh()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    // MARK: Pied : Retour · points · Continuer

    private var footer: some View {
        HStack {
            Button(L("Retour", "Back")) { go(-1) }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .opacity(model.step == 0 ? 0 : 1)
                .disabled(model.step == 0)
                .frame(width: 110, alignment: .leading)
            Spacer()
            HStack(spacing: 7) {
                ForEach(steps.indices, id: \.self) { i in
                    Circle()
                        .fill(i == model.step ? Color.plumeTheme : Color.secondary.opacity(0.3))
                        .frame(width: 7, height: 7)
                }
            }
            Spacer()
            Button(current == .done ? L("Commencer", "Get Started") : L("Continuer", "Continue")) {
                current == .done ? finish() : go(1)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .frame(width: 110, alignment: .trailing)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 22)
    }

    private func go(_ delta: Int) {
        let next = model.step + delta
        guard steps.indices.contains(next) else { return }
        // En quittant l'étape Modèle vers l'avant : le choix s'applique (et le
        // téléchargement commence s'il le faut).
        if delta > 0, current == .model, let m = ModelCatalog.model(model.chosenModel), m.id != models.selectedID || !models.isInstalled(m) {
            models.use(m)
        }
        model.forward = delta > 0
        withAnimation(.spring(response: 0.42, dampingFraction: 0.88)) { model.step = next }
    }

    // MARK: Pages

    @ViewBuilder
    private func page(_ step: OnboardingStep) -> some View {
        switch step {
        case .welcome:
            StepPage(icon: .app, title: L("Bienvenue dans Plume", "Welcome to Plume"),
                     subtitle: L("La dictée vocale, dans toutes vos apps.", "Voice dictation, in every app.")) {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 14) {
                    GridRow {
                        Text(L("Langue", "Language")).foregroundStyle(.secondary)
                            .gridColumnAlignment(.trailing)
                        Picker("", selection: $prefs.appLanguage) {
                            ForEach(AppLanguage.allCases) { Text($0.label).tag($0) }
                        }
                        .pickerStyle(.segmented).labelsHidden().fixedSize()
                        .focusable(false)   // pas de cadre gris de focus sur le choix
                    }
                    GridRow {
                        Text(L("Apparence", "Appearance")).foregroundStyle(.secondary)
                        Picker("", selection: $prefs.appearance) {
                            ForEach(AppAppearance.allCases) { Text($0.label).tag($0) }
                        }
                        .pickerStyle(.segmented).labelsHidden().fixedSize()
                        .focusable(false)   // pas de cadre gris de focus sur le choix
                    }
                }
            }

        case .microphone:
            StepPage(icon: .symbol("mic.fill"), title: L("Micro", "Microphone"),
                     subtitle: L("Pour entendre votre voix. Elle reste sur votre Mac.", "To hear your voice. It stays on your Mac.")) {
                PermissionStatus(ok: permissions.microphone == .authorized,
                                 action: L("Autoriser le micro", "Allow Microphone")) { permissions.requestMicrophone() }
            }

        case .accessibility:
            StepPage(icon: .symbol("accessibility"), title: L("Accessibilité", "Accessibility"),
                     subtitle: L("Pour le raccourci et l'insertion du texte. Activez Plume dans la liste.",
                                 "For the shortcut and text insertion. Turn on Plume in the list.")) {
                PermissionStatus(ok: permissions.accessibility,
                                 action: L("Ouvrir les Réglages", "Open Settings")) { permissions.requestAccessibility() }
            }

        case .shortcut:
            StepPage(icon: .symbol("keyboard"), title: L("Raccourci", "Shortcut"),
                     subtitle: L("Un appui pour démarrer, un appui pour terminer.", "Press once to start, once to stop.")) {
                VStack(spacing: 14) {
                    Text(prefs.shortcut.label)
                        .font(.system(size: 22, weight: .semibold, design: .rounded))
                        .padding(.horizontal, 18).padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.07)))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.12)))
                    ShortcutRecorder(shortcut: $prefs.shortcut, compact: true)
                    if prefs.shortcut.kind == .modifier && prefs.shortcut.keyCode == 63 {
                        Text(prefs.shortcut.explanation)
                            .font(.callout).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 400)
                        Button(L("Ouvrir les réglages Clavier", "Open Keyboard Settings")) {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                    }
                }
                .onChange(of: prefs.shortcut) { _, new in AppDelegate.shared?.hotkey.shortcut = new }
            }

        case .language:
            StepPage(icon: .symbol("globe"), title: L("Langue parlée", "Spoken language"),
                     subtitle: L("La langue dans laquelle vous dictez.", "The language you dictate in.")) {
                Picker("", selection: $prefs.language) {
                    ForEach(DictationLanguage.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
            }

        case .model:
            StepPage(icon: .symbol("cpu"), title: L("Modèle de voix", "Voice model"),
                     subtitle: L("Celui conseillé pour ce Mac est déjà choisi. Vous pourrez en changer dans Modèles.",
                                 "The one recommended for this Mac is already selected. You can change it in Models.")) {
                ModelChoice(chosen: $model.chosenModel)
            }

        case .cleanup:
            StepPage(icon: .symbol("sparkles"), title: L("Nettoyage du texte", "Text cleanup"),
                     subtitle: L("Ponctuation et hésitations corrigées. Facultatif : votre propre clé API.",
                                 "Fixes punctuation and filler words. Optional: your own API key.")) {
                Form {
                    PolishServiceRows(compact: true)
                }
                .formStyle(.grouped)
                .scrollDisabled(true)
                .frame(width: 460, height: 190)
            }

        case .done:
            StepPage(icon: .app, title: L("Tout est prêt", "You're all set"),
                     subtitle: L("Appuyez sur \(prefs.shortcut.label) pour dicter.", "Press \(prefs.shortcut.label) to dictate.")) {
                ModelDownloadStatus()
            }
        }
    }
}

/// Une page de l'assistant : icône, titre, sous-titre, puis son contenu.
private struct StepPage<Content: View>: View {
    enum Icon { case app, symbol(String) }
    let icon: Icon
    let title: String
    let subtitle: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 30)
            iconView
                .padding(.bottom, 22)
            Text(title)
                .font(.system(size: 26, weight: .bold))
                .multilineTextAlignment(.center)
            Text(subtitle)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
                .padding(.top, 8)
            content()
                .padding(.top, 28)
            Spacer(minLength: 10)
        }
        .padding(.horizontal, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var iconView: some View {
        switch icon {
        case .app:
            AppGlyph(size: 88)
        case .symbol(let name):
            Image(systemName: name)
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 76, height: 76)
                .background(RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(LinearGradient(colors: [Color(red: 0x7C / 255, green: 0x8C / 255, blue: 1),
                                                  Color(red: 0x43 / 255, green: 0x38 / 255, blue: 0xCA / 255)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing)))
                .shadow(color: Color(red: 0x43 / 255, green: 0x38 / 255, blue: 0xCA / 255).opacity(0.3), radius: 10, y: 4)
        }
    }
}

/// « Autorisé » quand c'est fait, sinon le bouton qui le demande.
private struct PermissionStatus: View {
    let ok: Bool
    let action: String
    let perform: () -> Void

    var body: some View {
        Group {
            if ok {
                Label(L("Autorisé", "Allowed"), systemImage: "checkmark.circle.fill")
                    .font(.headline)
                    .foregroundStyle(Color.plumeDone)
            } else {
                Button(action, action: perform)
                    .controlSize(.large)
            }
        }
        .animation(.easeOut(duration: 0.2), value: ok)
    }
}

/// Dernière page : le modèle se télécharge peut-être encore.
private struct ModelDownloadStatus: View {
    @EnvironmentObject var models: ModelStore

    var body: some View {
        let m = models.selected
        if let p = models.progress[m.id] {
            VStack(spacing: 8) {
                ProgressView(value: p).frame(width: 260)
                Text(L("Téléchargement de \(m.name) : \(Int(p * 100)) % de \(ModelRow.size(m.downloadSize))",
                       "Downloading \(m.name): \(Int(p * 100))% of \(ModelRow.size(m.downloadSize))"))
                    .font(.callout).foregroundStyle(.secondary)
            }
        } else if let error = models.errors[m.id] {
            Text(error).font(.callout).foregroundStyle(.red)
        } else {
            EmptyView()
        }
    }
}

/// L'étape Modèle : un menu avec le modèle conseillé déjà choisi, et sa fiche.
private struct ModelChoice: View {
    @EnvironmentObject var models: ModelStore
    @Binding var chosen: String

    private var options: [ModelInfo] { ModelCatalog.all.filter { models.isSupported($0) || $0.family == .cloud || $0.id == chosen } }
    private var current: ModelInfo { ModelCatalog.model(chosen) ?? models.selected }

    var body: some View {
        VStack(spacing: 14) {
            Picker("", selection: $chosen) {
                ForEach(options) { m in
                    Text(label(m)).tag(m.id)
                }
            }
            .labelsHidden()
            .fixedSize()

            if current.family == .cloud {
                Form { CloudModelSection(showUseButton: false) }
                    .formStyle(.grouped)
                    .scrollDisabled(true)
                    .frame(width: 460, height: 210)
            } else {
                VStack(spacing: 6) {
                    Text(current.summary)
                    Text(facts(current)).font(.callout).foregroundStyle(.secondary)
                    Text(L("Ce Mac : \(Setup.chipName), \(Setup.memoryGB) Go de mémoire.",
                           "This Mac: \(Setup.chipName), \(Setup.memoryGB) GB of memory."))
                        .font(.caption).foregroundStyle(.tertiary)
                }
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            }
        }
    }

    private func label(_ m: ModelInfo) -> String {
        var s = m.displayName
        if m.family != .cloud { s += " · " + ModelRow.size(m.downloadSize) }
        if m.id == ModelCatalog.recommendedDefault() { s += " · " + L("conseillé", "recommended") }
        else if models.isInstalled(m) && m.family != .cloud { s += " · " + L("déjà là", "already here") }
        return s
    }

    private func facts(_ m: ModelInfo) -> String {
        let speed = [L("lent", "slow"), L("rapide", "fast"), L("très rapide", "very fast")][max(0, min(2, m.speed - 1))]
        let accuracy = [L("bonne", "good"), L("très bonne", "very good"), L("excellente", "excellent")][max(0, min(2, m.accuracy - 1))]
        return [m.languages, L("vitesse : \(speed)", "speed: \(speed)"), L("précision : \(accuracy)", "accuracy: \(accuracy)")]
            .joined(separator: " · ")
    }
}

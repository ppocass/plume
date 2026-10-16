import SwiftUI

/// Réglages : formulaire groupé natif, comme Réglages Système.
struct SettingsView: View {
    @EnvironmentObject var prefs: Prefs
    @EnvironmentObject var permissions: Permissions
    @EnvironmentObject var engine: EngineStatus
    @EnvironmentObject var models: ModelStore
    @EnvironmentObject var navigation: Navigation
    @ObservedObject private var updater = Updater.shared

    var body: some View {
        Form {
            Section(L("Général", "General")) {
                Picker(L("Langue", "Language"), selection: $prefs.appLanguage) {
                    ForEach(AppLanguage.allCases) { Text($0.label).tag($0) }
                }
                .focusable(false)
                Picker(L("Apparence", "Appearance"), selection: $prefs.appearance) {
                    ForEach(AppAppearance.allCases) { Text($0.label).tag($0) }
                }
                .focusable(false)
                Toggle(L("Ouvrir à la connexion", "Open at login"), isOn: Binding(
                    get: { permissions.launchAtLogin },
                    set: { permissions.setLaunchAtLogin($0) }))
                Toggle(L("Afficher dans la barre des menus", "Show in menu bar"), isOn: $prefs.showInMenuBar)
                Toggle(L("Sons", "Sounds"), isOn: $prefs.soundsEnabled)
            }

            Section {
                LabeledContent(L("Raccourci", "Shortcut")) {
                    ShortcutRecorder(shortcut: $prefs.shortcut)
                }
            } header: {
                Text(L("Raccourci", "Shortcut"))
            } footer: {
                Text(prefs.shortcut.explanation)
            }

            Section {
                Picker(L("Langue parlée", "Spoken language"), selection: $prefs.language) {
                    ForEach(DictationLanguage.allCases) { Text($0.label).tag($0) }
                }
                .focusable(false)
            } header: {
                Text(L("Dictée", "Dictation"))
            } footer: {
                if ModelStore.active.family == .whisper && prefs.language == .auto {
                    Text(L("Avec Whisper, choisir la langue est plus fiable.", "With Whisper, choosing the language is more reliable."))
                }
            }

            Section {
                Toggle(L("Nettoyer le texte", "Clean up text"), isOn: $prefs.polishEnabled)
                PolishServiceRows()
            } header: {
                Text(L("Nettoyage", "Cleanup"))
            } footer: {
                Text(L("Ponctuation et hésitations corrigées. Seul le texte est envoyé, avec votre propre clé.",
                       "Fixes punctuation and filler words. Only text is sent, with your own key."))
            }

            Section(L("Pastille", "Indicator")) {
                TintRow(title: L("Écoute", "Listening"), selection: $prefs.listenTint)
                TintRow(title: L("Traitement", "Processing"), selection: $prefs.thinkTint)
                LabeledContent(L("Aperçu", "Preview")) {
                    HStack(spacing: 10) {
                        PillPreview(color: prefs.listenTint.color, thinking: false)
                        PillPreview(color: prefs.thinkTint.color, thinking: true)
                    }
                }
            }

            Section {
                LabeledContent(L("État", "Status"), value: engine.state.label)
                LabeledContent(L("Modèle", "Model")) {
                    HStack(spacing: 8) {
                        Text(ModelStore.active.displayName)
                        Button(L("Changer…", "Change…")) { navigation.selection = .models }
                    }
                }
                Picker(L("Mise en veille après", "Sleep after"), selection: $prefs.engineIdle) {
                    ForEach(Prefs.idleChoices, id: \.self) { v in
                        Text(v < 0 ? L("Jamais", "Never") : v < 60 ? "\(Int(v)) s" : "\(Int(v / 60)) min").tag(v)
                    }
                }
                .focusable(false)
            } header: {
                Text(L("Moteur", "Engine"))
            } footer: {
                Text(ModelStore.active.family == .cloud
                     ? L("Transcription en ligne : la voix est envoyée au service choisi.", "Online transcription: your voice is sent to the chosen service.")
                     : Setup.sharedEngineNote ?? L("Fonctionne hors ligne, sur votre Mac.", "Runs offline, on your Mac."))
            }

            Section(L("Autorisations", "Permissions")) {
                PermissionRows()
                if permissions.accessibility && !permissions.hotkeyActive {
                    Text(L("Activation du raccourci…", "Activating shortcut…"))
                        .font(.callout).foregroundStyle(.secondary)
                }
            }

            Section {
                LabeledContent(L("Version", "Version"), value: Updater.currentVersion)
                if updater.isSupported {
                    Toggle(L("Rechercher automatiquement", "Check automatically"), isOn: $updater.autoCheck)
                    LabeledContent(L("Mise à jour", "Update")) { UpdateStatus(updater: updater) }
                }
            } header: {
                Text(L("Mises à jour", "Updates"))
            } footer: {
                Text(updater.isSupported
                     ? L("Vos réglages, votre historique et vos modèles sont conservés.", "Your settings, history and models are kept.")
                     : L("Version compilée sur ce Mac : elle se met à jour depuis ses sources.", "Built on this Mac: update it from source."))
            }

            Section {
                Button(L("Revoir la configuration…", "Run Setup Again…")) {
                    OnboardingWindowController.shared.show()
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .onChange(of: prefs.shortcut) { _, new in
            AppDelegate.shared?.hotkey.shortcut = new
        }
    }
}

/// Service de nettoyage, adresse, modèle, clé et test (réglages et assistant).
struct PolishServiceRows: View {
    @EnvironmentObject var prefs: Prefs
    var compact = false

    var body: some View {
        Picker(L("Service", "Service"), selection: $prefs.polishService) {
            ForEach(PolishService.available) { Text($0.label).tag($0) }
        }
        .focusable(false)
        if prefs.polishService == .custom {
            TextField(L("Adresse", "URL"), text: $prefs.polishCustomURL, prompt: Text("https://…/v1"))
        }
        if prefs.polishService != .server && !compact {
            TextField(L("Modèle", "Model"), text: $prefs.polishModel, prompt: Text(prefs.polishService.defaultModel))
        }
        if !prefs.polishService.usesKeyFile {
            APIKeyRow(account: prefs.polishService.keyAccount)
        }
        if !compact {
            Picker(L("Consigne", "Instructions"), selection: $prefs.polishPrompt) {
                ForEach(PromptLanguage.allCases) { Text($0.label).tag($0) }
            }
            .focusable(false)
        }
        ConnectionTestRow { await Polisher.test() }
        if let page = prefs.polishService.keyPage {
            Link(L("Créer une clé \(prefs.polishService.label)", "Create a \(prefs.polishService.label) key"), destination: page)
        }
    }
}

/// « Tester » une connexion (nettoyage, transcription en ligne).
struct ConnectionTestRow: View {
    let run: () async -> Result<Double, Error>
    @State private var result: String?
    @State private var testing = false

    var body: some View {
        LabeledContent(L("Connexion", "Connection")) {
            HStack(spacing: 8) {
                if let result { Text(result).foregroundStyle(.secondary).lineLimit(2) }
                Button(testing ? L("Test…", "Testing…") : L("Tester", "Test")) {
                    testing = true
                    Task {
                        switch await run() {
                        case .success(let s): result = String(format: L("OK · %.2f s", "OK · %.2f s"), s)
                        case .failure(let e): result = e.localizedDescription
                        }
                        testing = false
                    }
                }
                .disabled(testing)
            }
        }
    }
}

/// Une rangée de pastilles de couleur, comme le choix d'accent de Réglages Système.
struct TintRow: View {
    let title: String
    @Binding var selection: PillTint

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 5) {
                ForEach(PillTint.allCases) { tint in
                    Button {
                        selection = tint
                    } label: {
                        Circle()
                            .fill(tint.color)
                            .frame(width: 16, height: 16)
                            .overlay(Circle().stroke(Color.primary.opacity(0.15), lineWidth: 0.5))
                            .padding(3)
                            .overlay(Circle().stroke(selection == tint ? Color.primary.opacity(0.75) : .clear, lineWidth: 1.5))
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help(tint.label)
                    .accessibilityLabel(tint.label)
                }
            }
        }
    }
}

/// La pastille en miniature, animée comme la vraie (écoute ou traitement).
struct PillPreview: View {
    let color: Color
    let thinking: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            HStack(spacing: 2.5) {
                ForEach(0..<LevelMeter.barCount, id: \.self) { i in
                    Capsule()
                        .fill(color)
                        .frame(width: 3, height: height(i, t: t))
                }
            }
            .frame(height: 18)
        }
        .shadow(color: color.opacity(0.5), radius: 4)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Capsule().fill(Color.black.opacity(0.88))
            .overlay(Capsule().stroke(Color.white.opacity(0.14), lineWidth: 0.75)))
    }

    private func height(_ i: Int, t: TimeInterval) -> CGFloat {
        if thinking {
            let wave = sin(t * 6 - Double(i) * 0.55)
            return 4 + 10 * CGFloat((wave + 1) / 2)
        }
        let voice = 0.5 + 0.5 * sin(t * 3.1 + Double(i) * 0.9) * sin(t * 1.7 + Double(i) * 0.4)
        return 3 + 15 * CGFloat(voice)
    }
}

/// Le choix du raccourci : la touche actuelle, « Enregistrer » (on appuie sur
/// une touche modificatrice seule ou sur une combinaison), et les choix rapides.
struct ShortcutRecorder: View {
    @Binding var shortcut: Shortcut
    /// Assistant : centré, sans rappeler la touche (affichée en grand au-dessus).
    var compact = false
    @State private var recording = false
    @State private var problem: String?
    @State private var monitor: Any?
    /// Touche modificatrice enfoncée seule pendant l'enregistrement.
    @State private var pendingModifier: Int64?

    var body: some View {
        VStack(alignment: compact ? .center : .trailing, spacing: 6) {
            HStack(spacing: 8) {
                if compact && recording {
                    Text(L("Appuyez sur une touche…", "Press a key…")).foregroundStyle(Color.plumeTheme)
                }
                if !compact {
                    Text(recording ? L("Appuyez sur une touche…", "Press a key…") : shortcut.label)
                        .font(.system(.body, design: .rounded).weight(.semibold))
                        .foregroundStyle(recording ? Color.plumeTheme : .primary)
                        .padding(.horizontal, 10).padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.primary.opacity(recording ? 0.04 : 0.08)))
                        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(recording ? Color.plumeTheme : .clear, lineWidth: 1))
                }
                Button(recording ? L("Annuler", "Cancel") : L("Modifier…", "Change…")) {
                    recording ? stop() : start()
                }
                Menu {
                    ForEach(Shortcut.presets, id: \.keyCode) { preset in
                        Button(preset.label) { stop(); shortcut = preset }
                    }
                } label: {
                    Text(L("Préréglages", "Presets"))
                }
                .fixedSize()
            }
            if recording {
                Text(L("Touche seule ou combinaison (⌃⇧W) · Échap pour annuler", "Single key or combo (⌃⇧W) · Esc to cancel"))
                    .font(.caption).foregroundStyle(.secondary)
            } else if let problem {
                Text(problem).font(.caption).foregroundStyle(.orange)
            }
        }
        .onDisappear { stop() }
    }

    private func start() {
        problem = nil
        pendingModifier = nil
        recording = true
        AppDelegate.shared?.hotkey.paused = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            handle(event)
            return nil   // rien n'atteint les champs pendant l'enregistrement
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
        pendingModifier = nil
        AppDelegate.shared?.hotkey.paused = false
    }

    private func handle(_ event: NSEvent) {
        let code = Int64(event.keyCode)
        if event.type == .flagsChanged {
            guard Shortcut.isModifierKey(code) else { return }
            let held = event.modifierFlags.intersection([.command, .control, .option, .shift, .function])
            if let pending = pendingModifier {
                // Relâchée seule → c'est le raccourci ; une 2ᵉ touche → on attend la combinaison.
                if pending == code, held.isEmpty || held == [.function] && code != 63 {
                    if let s = Shortcut.modifierKey(code) { shortcut = s }
                    stop()
                } else if !held.isEmpty {
                    pendingModifier = nil
                }
            } else if !held.isEmpty {
                pendingModifier = code
            }
            return
        }
        // keyDown
        pendingModifier = nil
        let mods = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if code == 53 && mods.isEmpty { stop(); return }   // Échap seule : annuler
        let (combo, why) = Shortcut.combo(from: event)
        if let combo {
            shortcut = combo
            stop()
        } else {
            problem = why
            stop()
        }
    }
}

/// Une clé API : collée une fois, gardée dans le trousseau, jamais réaffichée.
struct APIKeyRow: View {
    let account: String
    @State private var draft = ""
    @State private var saved = false

    var body: some View {
        LabeledContent(L("Clé API", "API key")) {
            HStack(spacing: 8) {
                if saved && draft.isEmpty {
                    Label(L("Enregistrée", "Saved"), systemImage: "checkmark.circle.fill")
                        .foregroundStyle(Color.plumeDone)
                    Button(L("Modifier", "Change")) { saved = false }
                } else {
                    SecureField(L("Coller la clé", "Paste key"), text: $draft)
                        .frame(minWidth: 220)
                        .onSubmit(save)
                    Button(L("Enregistrer", "Save"), action: save)
                        .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .onAppear { saved = KeychainStore.read(account) != nil }
        .onChange(of: account) { _, new in
            draft = ""
            saved = KeychainStore.read(new) != nil
        }
    }

    private func save() {
        let key = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        KeychainStore.write(account, key)
        draft = ""
        saved = true
    }
}

/// État de la mise à jour, et le bouton qui va avec.
struct UpdateStatus: View {
    @ObservedObject var updater: Updater

    var body: some View {
        HStack(spacing: 8) {
            switch updater.state {
            case .checking:
                ProgressView().controlSize(.small)
                Text(L("Recherche…", "Checking…")).foregroundStyle(.secondary)
            case .upToDate:
                Text(L("Plume est à jour", "Plume is up to date")).foregroundStyle(.secondary)
                checkButton
            case .available(let v):
                Text(L("Version \(v) disponible", "Version \(v) available")).foregroundStyle(Color.plumeTheme)
                Button(L("Mettre à jour", "Update")) { Task { await updater.install() } }
            case .downloading, .installing:
                ProgressView().controlSize(.small)
                Text(L("Installation…", "Installing…")).foregroundStyle(.secondary)
            case .failed(let why):
                Text(why).foregroundStyle(.orange).lineLimit(2)
                checkButton
            case .idle:
                checkButton
            }
        }
    }

    private var checkButton: some View {
        Button(L("Rechercher", "Check Now")) { Task { await updater.check(userInitiated: true) } }
    }
}

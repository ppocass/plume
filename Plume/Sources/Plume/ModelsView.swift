import SwiftUI

/// La page « Modèles » : les modèles de reconnaissance vocale, à télécharger,
/// utiliser ou supprimer, et la transcription en ligne avec sa propre clé.
struct ModelsView: View {
    @EnvironmentObject var models: ModelStore

    var body: some View {
        Form {
            Section {
                LabeledContent(L("Ce Mac", "This Mac"), value: "\(Setup.chipName) · \(Setup.memoryGB) " + L("Go", "GB"))
            } footer: {
                Text(L("Tout se passe sur votre Mac : la voix n'en sort pas.", "Everything runs on your Mac: your voice never leaves it."))
            }

            Section {
                ForEach(ModelCatalog.all.filter { $0.family == .parakeet }) { ModelRow(model: $0) }
            } header: {
                Text("Parakeet")
            } footer: {
                Text(L("Sur la puce neuronale : très rapide, même avec 8 Go.", "Runs on the Neural Engine: very fast, even with 8 GB."))
            }

            Section {
                ForEach(ModelCatalog.all.filter { $0.family == .whisper }) { ModelRow(model: $0) }
            } header: {
                Text("Whisper")
            } footer: {
                Text(L("Sur la puce graphique. Plus de langues, et il tient compte du vocabulaire.",
                       "Runs on the GPU. More languages, and it uses your vocabulary."))
            }

            Section {
                CloudModelSection()
            } header: {
                Text(L("En ligne", "Online"))
            } footer: {
                Text(L("Avec votre propre clé API. La voix est envoyée au service choisi.",
                       "With your own API key. Your voice is sent to the chosen service."))
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
}

/// Un modèle : nom, badges, description, chiffres, et l'action possible.
struct ModelRow: View {
    @EnvironmentObject var models: ModelStore
    let model: ModelInfo
    var compact = false
    @State private var confirmDelete = false

    private var isActive: Bool { models.selectedID == model.id && models.isInstalled(model) }
    private var isRecommended: Bool { ModelCatalog.recommended(model.family) == model.id }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(model.displayName).fontWeight(.semibold)
                    if isRecommended { Tag(text: L("Conseillé pour ce Mac", "Recommended for this Mac"), color: .plumeTheme) }
                }
                if !compact {
                    Text(model.summary).font(.callout).foregroundStyle(.secondary)
                }
                Text(facts).font(.caption).foregroundStyle(.secondary)
                if let error = models.errors[model.id] {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
            Spacer(minLength: 8)
            action
        }
        .padding(.vertical, 3)
        .confirmationDialog(L("Supprimer \(model.name) ?", "Delete \(model.name)?"), isPresented: $confirmDelete) {
            Button(L("Supprimer", "Delete"), role: .destructive) { models.delete(model) }
            Button(L("Annuler", "Cancel"), role: .cancel) {}
        } message: {
            Text(L("\(Self.size(model.downloadSize)) seront libérés. Vous pourrez le retélécharger.",
                   "\(Self.size(model.downloadSize)) will be freed. You can download it again."))
        }
    }

    private var facts: String {
        let speed = [L("lent", "slow"), L("rapide", "fast"), L("très rapide", "very fast")][max(0, min(2, model.speed - 1))]
        let accuracy = [L("bonne", "good"), L("très bonne", "very good"), L("excellente", "excellent")][max(0, min(2, model.accuracy - 1))]
        var parts = [Self.size(model.downloadSize), model.languages,
                     L("vitesse : \(speed)", "speed: \(speed)"), L("précision : \(accuracy)", "accuracy: \(accuracy)"),
                     L("\(model.memoryGB) Go de mémoire conseillés", "\(model.memoryGB) GB memory recommended")]
        if compact { parts = Array(parts.prefix(4)) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var action: some View {
        if let p = models.progress[model.id] {
            HStack(spacing: 8) {
                ProgressView(value: p).frame(width: 80)
                Text("\(Int(p * 100)) %").font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 34, alignment: .trailing)
                Button(L("Annuler", "Cancel")) { models.cancel(model) }
            }
        } else if !models.isSupported(model) {
            Text(Setup.macOSMajor < model.minMacOS ? L("macOS \(model.minMacOS) requis", "Requires macOS \(model.minMacOS)")
                                                   : L("Indisponible", "Unavailable"))
                .font(.callout).foregroundStyle(.secondary)
        } else if isActive {
            Label(L("Utilisé", "In use"), systemImage: "checkmark.circle.fill")
                .foregroundStyle(Color.plumeDone)
        } else if models.isInstalled(model) {
            HStack(spacing: 6) {
                Button(L("Utiliser", "Use")) { models.use(model) }
                if models.canDelete(model) {
                    Button { confirmDelete = true } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                        .help(L("Supprimer", "Delete"))
                }
            }
        } else {
            Button(L("Télécharger", "Download")) { models.download(model) }
        }
    }

    static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

/// « En ligne » : service, adresse, modèle, clé, test, et « Utiliser ».
struct CloudModelSection: View {
    @EnvironmentObject var models: ModelStore
    @EnvironmentObject var prefs: Prefs
    var showUseButton = true

    private var cloud: ModelInfo { ModelCatalog.model(ModelCatalog.cloudID)! }

    var body: some View {
        Picker(L("Service", "Service"), selection: $prefs.sttService) {
            ForEach(TranscriptionService.allCases) { Text($0.label).tag($0) }
        }
        if prefs.sttService == .custom {
            TextField(L("Adresse", "URL"), text: $prefs.sttCustomURL, prompt: Text("https://…/v1"))
        }
        TextField(L("Modèle", "Model"), text: $prefs.sttModel, prompt: Text(prefs.sttService.defaultModel))
        APIKeyRow(account: prefs.sttService.keyAccount)
        ConnectionTestRow { await CloudTranscriber.test() }
        if let page = prefs.sttService.keyPage {
            Link(L("Créer une clé \(prefs.sttService.label)", "Create a \(prefs.sttService.label) key"), destination: page)
        }
        if showUseButton {
            HStack {
                Spacer()
                if models.selectedID == cloud.id {
                    Label(L("Utilisé", "In use"), systemImage: "checkmark.circle.fill").foregroundStyle(Color.plumeDone)
                } else {
                    Button(L("Utiliser la transcription en ligne", "Use online transcription")) { models.use(cloud) }
                }
            }
        }
    }
}

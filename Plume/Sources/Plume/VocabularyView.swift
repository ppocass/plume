import SwiftUI

/// La page « Vocabulaire » :
/// une liste de mots ; un clic ouvre la fiche du mot, avec en dessous
/// « Également entendu sous la forme de » et autant de formes qu'on veut.
struct VocabularyView: View {
    @EnvironmentObject var vocabulary: VocabularyStore
    @State private var search = ""
    @State private var editing: VocabEntry?
    /// Le mot dont on enregistre la prononciation (feuille d'écoute).
    @State private var recording: VocabEntry?

    var body: some View {
        List {
            Section {
                Button {
                    editing = VocabEntry(word: "")
                } label: {
                    Label(L("Nouveau mot", "New Word"), systemImage: "plus.circle.fill")
                        .font(.body.weight(.medium))
                        .foregroundStyle(Color.plumeTheme)
                }
                .buttonStyle(.plain)
                .padding(.vertical, 4)
                Text(L("Écrivez comment ça sonne, comme vous l'entendriez. Plume reconnaîtra toutes les variantes.",
                       "Write how it sounds, the way you hear it. Plume picks up every variant."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section(L("\(filtered.count) mots", "\(filtered.count) words")) {
                ForEach(filtered) { entry in
                    Button {
                        editing = entry
                    } label: {
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(entry.word).font(.body.weight(.semibold))
                                if !entry.variants.isEmpty {
                                    Text(L("Entendu : ", "Heard: ") + entry.variants.joined(separator: ", "))
                                        .font(.callout)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 5)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button(L("Enregistrer la phonétique…", "Record how it sounds…")) {
                            PronounceRecorder.shared.start(for: entry.word)
                            recording = entry
                        }
                        Button(L("Modifier…", "Edit…")) { editing = entry }
                        Button(L("Supprimer", "Delete"), role: .destructive) { vocabulary.remove(entry.id) }
                    }
                }
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .searchable(text: $search, placement: .toolbar, prompt: L("Rechercher", "Search"))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { editing = VocabEntry(word: "") } label: { Label(L("Nouveau mot", "New Word"), systemImage: "plus") }
                    .help(L("Nouveau mot", "New Word"))
            }
        }
        .sheet(item: $editing) { entry in
            VocabEditorSheet(entry: entry, isNew: !vocabulary.items.contains { $0.id == entry.id })
        }
        .sheet(item: $recording, onDismiss: { PronounceRecorder.shared.cancel() }) { entry in
            PronounceSheet(entry: entry)
        }
    }

    private var filtered: [VocabEntry] {
        guard !search.isEmpty else { return vocabulary.items }
        return vocabulary.items.filter {
            $0.word.localizedCaseInsensitiveContains(search) || $0.variants.contains { $0.localizedCaseInsensitiveContains(search) }
        }
    }
}

/// La fiche d'un mot : le mot, puis « Également entendu sous la forme de ».
struct VocabEditorSheet: View {
    @EnvironmentObject var vocabulary: VocabularyStore
    @Environment(\.dismiss) private var dismiss

    /// Une forme avec son identité propre : supprimer une ligne au milieu ne
    /// décale pas les champs (et ne fait pas planter SwiftUI).
    struct HeardForm: Identifiable { let id = UUID(); var text: String }

    let original: VocabEntry
    let isNew: Bool
    @State private var word: String
    @State private var forms: [HeardForm]
    @State private var listening = false
    /// Le curseur va tout seul dans le champ qu'on vient d'ajouter.
    @FocusState private var focusedForm: UUID?
    @FocusState private var wordFocused: Bool

    init(entry: VocabEntry, isNew: Bool) {
        original = entry
        self.isNew = isNew
        _word = State(initialValue: entry.word)
        let f = entry.variants.map { HeardForm(text: $0) }
        _forms = State(initialValue: f.isEmpty ? [HeardForm(text: "")] : f)
    }

    private var entry: VocabEntry {
        var e = original
        e.word = word
        e.variants = forms.map(\.text)
        return e
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section {
                    TextField(L("Mot", "Word"), text: $word, prompt: Text(L("Orthographe correcte", "Correct spelling")))
                        .focused($wordFocused)
                        .font(.title3.weight(.semibold))
                } header: {
                    Text(L("Mot", "Word"))
                }

                Section {
                    ForEach($forms) { $form in
                        HStack {
                            TextField(L("Forme", "Form"), text: $form.text,
                                      prompt: Text(L("ex. dipsik", "e.g. dipsik")))
                                .labelsHidden()
                                .focused($focusedForm, equals: form.id)
                                .onSubmit { addForm() }
                            if forms.count > 1 || !form.text.isEmpty {
                                Button {
                                    forms.removeAll { $0.id == form.id }
                                    if forms.isEmpty { forms = [HeardForm(text: "")] }
                                } label: {
                                    Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                                }
                                .buttonStyle(.borderless)
                                .help(L("Retirer", "Remove"))
                            }
                        }
                    }
                    Button {
                        addForm()
                    } label: {
                        Label(L("Ajouter", "Add"), systemImage: "plus")
                    }
                    .buttonStyle(.borderless)
                    // Le même geste que dans le menu du mot, mais là où on
                    // rédige la fiche : on parle au lieu d'écrire.
                    Button {
                        PronounceRecorder.shared.start(for: word)
                        listening = true
                    } label: {
                        Label(L("Enregistrer la phonétique…", "Record how it sounds…"),
                              systemImage: "mic.fill")
                    }
                    .buttonStyle(.borderless)
                    .disabled(word.trimmingCharacters(in: .whitespaces).isEmpty)
                } header: {
                    Text(L("Comment ça sonne", "How it sounds"))
                } footer: {
                    // ⚠️ Le vrai malentendu était ici : le libellé précédent
                    // (« Reconnu à tort comme ») faisait croire qu'il fallait
                    // recopier une faute déjà vue. Il faut au contraire écrire
                    // **comment ça se prononce** — Pierre l'a demandé le
                    // 04/11 : « écrivez plutôt phonétiquement, avec des vraies
                    // lettres ». La correction se fait sur les mots entiers,
                    // l'accent ne casse donc rien.
                    Text(L("Une par ligne, avec les lettres qui s'entendent. Plume remplace toutes ces graphies par le mot ci-dessus.",
                           "One per line, using the letters you actually hear. Plume replaces every one of them with the word above."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

            HStack {
                if !isNew {
                    Button(L("Supprimer le mot", "Delete Word"), role: .destructive) {
                        vocabulary.remove(original.id)
                        dismiss()
                    }
                }
                Spacer()
                Button(L("Annuler", "Cancel"), role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(L("Enregistrer", "Save")) {
                    vocabulary.save(entry)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(word.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
        }
        .frame(width: 440, height: 440)
        .sheet(isPresented: $listening, onDismiss: { PronounceRecorder.shared.cancel() }) {
            // On réutilise la feuille d'écoute ; elle ajoute au mot en base,
            // et ici on veut aussi voir la graphie dans la fiche.
            PronounceSheet(entry: VocabEntry(word: word))
        }
        .onChange(of: PronounceRecorder.shared.state) { _, new in
            if case .got(let text) = new, !text.isEmpty {
                // Le résultat arrive : on l'ajoute à la fiche en cours d'édition.
                forms.append(HeardForm(text: text))
                PronounceRecorder.shared.reset()
                listening = false
            }
        }
        .onAppear {
            // Nouveau mot : curseur sur le mot ; mot existant : sur la 1re forme vide.
            if isNew { wordFocused = true } else if let empty = forms.first(where: { $0.text.isEmpty }) { focusedForm = empty.id }
        }
    }

    /// Ajoute un champ (ou réutilise le dernier s'il est vide) et y met le curseur.
    private func addForm() {
        if let last = forms.last, last.text.trimmingCharacters(in: .whitespaces).isEmpty {
            focusedForm = last.id
            return
        }
        let f = HeardForm(text: "")
        forms.append(f)
        DispatchQueue.main.async { focusedForm = f.id }
    }
}

/// « Corriger un mot… » depuis l'historique : corrige cette dictée ET retient
/// la correction pour les prochaines.
struct CorrectWordSheet: View {
    @Environment(\.dismiss) private var dismiss
    let item: Dictation
    @State private var heard = ""
    @State private var wanted = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("Corriger un mot", "Fix a Word")).font(.title3.weight(.semibold))
            Text(item.text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(4)
                .textSelection(.enabled)
            Form {
                TextField(L("Reconnu", "Heard"), text: $heard)
                TextField(L("Correct", "Correct"), text: $wanted)
            }
            .formStyle(.columns)
            Text(L("Corrigé ici et ajouté au vocabulaire.", "Fixed here and added to Vocabulary."))
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button(L("Annuler", "Cancel"), role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(L("Corriger", "Fix")) {
                    DictationController.shared.learnCorrection(in: item, heard: heard, wanted: wanted)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(heard.trimmingCharacters(in: .whitespaces).isEmpty || wanted.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}

/// La petite feuille « Enregistrer la phonétique » : on appuie, on prononce,
/// Plume écrit ce qu'il entend et l'ajoute au mot.
///
/// Le résultat **n'est pas imposé** : Pierre le voit, peut le corriger à la
/// main s'il est faux, puis valider. C'est important — un moteur peut se
/// tromper, et c'est justement sur les noms propres qu'il se trompe.
struct PronounceSheet: View {
    @EnvironmentObject var vocabulary: VocabularyStore
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var rec = PronounceRecorder.shared

    let entry: VocabEntry
    @State private var heard = ""

    var body: some View {
        VStack(spacing: 18) {
            VStack(spacing: 6) {
                Text(entry.word).font(.title2.weight(.semibold))
                Text(L("Prononcez-le comme vous le dites d'habitude.",
                       "Say it the way you normally say it."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            stateView

            if !heard.isEmpty {
                TextField(L("Entendu", "Heard"), text: $heard)
                    .textFieldStyle(.roundedBorder)
                    .font(.body.monospaced())
                    .frame(width: 260)
                    .focusEffectDisabled()
            }

            HStack {
                Button(L("Annuler", "Cancel"), role: .cancel) {
                    rec.cancel()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                switch rec.state {
                case .got:
                    Button(L("Ajouter", "Add")) {
                        vocabulary.add(word: entry.word, variant: heard)
                        rec.reset()
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(heard.trimmingCharacters(in: .whitespaces).isEmpty)
                case .listening:
                    Button(L("Terminer", "Stop")) { rec.finish() }
                        .buttonStyle(.borderedProminent)
                default:
                    Button(L("Réécouter", "Record again")) {
                        heard = ""
                        rec.start(for: entry.word)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(24)
        .frame(width: 400)
        .onAppear {
            rec.onResult = { text in heard = text }
            rec.start(for: entry.word)
        }
        .onDisappear { rec.cancel() }
    }

    @ViewBuilder
    private var stateView: some View {
        switch rec.state {
        case .idle, .listening:
            VStack(spacing: 10) {
                Image(systemName: "waveform")
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(Color.plumeAccent)
                    .symbolEffect(.variableColor.iterative, isActive: true)
                Text(L("J'écoute…", "Listening…"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(height: 90)
        case .working:
            VStack(spacing: 10) {
                ProgressView()
                Text(L("J'écris ce que j'entends…", "Writing what I hear…"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(height: 90)
        case .got:
            VStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(Color.plumeDone)
                Text(L("Voilà ce que j'ai entendu. Corrigez si besoin.",
                       "Here's what I heard. Fix it if it's off."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(height: 90)
        case .failed(let message):
            VStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(.orange)
                Text(message).font(.callout).foregroundStyle(.secondary)
            }
            .frame(height: 90)
        }
    }
}

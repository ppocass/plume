import SwiftUI

/// La page « Vocabulaire » :
/// une liste de mots ; un clic ouvre la fiche du mot, avec en dessous
/// « Également entendu sous la forme de » et autant de formes qu'on veut.
struct VocabularyView: View {
    @EnvironmentObject var vocabulary: VocabularyStore
    @State private var search = ""
    @State private var editing: VocabEntry?

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
                Text(L("Les mots mal reconnus, corrigés automatiquement.", "Misheard words, fixed automatically."))
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
                            TextField(L("Forme", "Form"), text: $form.text, prompt: Text(L("Forme mal reconnue", "Misheard form")))
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
                } header: {
                    Text(L("Reconnu à tort comme", "Misheard as"))
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

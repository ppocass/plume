import SwiftUI

/// La page « 1337 » : le second geste de dictée, qui maquille le texte en leet
/// speak au lieu de le rendre propre.
///
/// Trois réglages et rien d'autre : l'interrupteur, le raccourci (le même écran
/// d'enregistrement que les Réglages, ouvert aux couples de modificateurs), le
/// niveau avec un aperçu en direct des trois. **La couleur de la pastille ne
/// figure pas ici** : elle reste dans Réglages → Pastille, une seule fois.
struct LeetView: View {
    @EnvironmentObject var prefs: Prefs

    /// La phrase d'exemple de l'aperçu (dans la langue de l'interface).
    private var sample: String {
        L("Le renard brun saute par-dessus le chien paresseux.",
          "The quick brown fox jumps over the lazy dog.")
    }

    var body: some View {
        Form {
            Section {
                Toggle(L("Activer la dictée 1337", "Enable 1337 dictation"), isOn: $prefs.leetEnabled)
                LabeledContent(L("Raccourci", "Shortcut")) {
                    ShortcutRecorder(shortcut: $prefs.leetShortcut, allowsPairs: true)
                }
            } header: {
                Text(L("Dictée 1337", "1337 dictation"))
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("Dictez normalement, puis terminez avec ce raccourci : le texte de cette dictée part en 1337. Terminez avec votre raccourci habituel pour un texte normal.",
                           "Dictate as usual, then finish with this shortcut: that dictation comes out in 1337. Finish with your usual shortcut for plain text."))
                }
            }

            Section {
                LevelRow(level: .light, sample: sample, selection: $prefs.leetLevel)
                LevelRow(level: .medium, sample: sample, selection: $prefs.leetLevel)
                LevelRow(level: .full, sample: sample, selection: $prefs.leetLevel)
            } header: {
                Text(L("Niveau", "Level"))
            } footer: {
                Text(L("Les liens, les adresses e-mail et les chemins de fichiers ne sont jamais modifiés. Le même texte donne toujours le même résultat.",
                       "Links, email addresses and file paths are never changed. The same text always gives the same result."))
            }
            Section {
                LeetTransformer()
            } header: {
                Text(L("Transformer un texte", "Convert some text"))
            } footer: {
                Text(L("Collez du texte, il ressort en 1337 au niveau choisi plus haut. Rien ne quitte votre Mac.",
                       "Paste some text and it comes out in 1337 at the level chosen above. Nothing leaves your Mac."))
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .onChange(of: prefs.leetShortcut) { _, new in
            AppDelegate.shared?.hotkey.leetShortcut = prefs.leetEnabled ? new : nil
        }
        .onChange(of: prefs.leetEnabled) { _, on in
            AppDelegate.shared?.hotkey.leetShortcut = on ? prefs.leetShortcut : nil
        }
    }
}

/// Un niveau, avec la phrase d'exemple maquillée à ce niveau. Cliquer dessus le
/// choisit ; celui qui est actif est entouré du violet de Plume.
private struct LevelRow: View {
    let level: Leet.Level
    let sample: String
    @Binding var selection: Leet.Level

    private var isSelected: Bool { selection == level }

    var body: some View {
        Button {
            selection = level
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Circle()
                        .strokeBorder(isSelected ? Color.plumeTheme : Color.secondary.opacity(0.5), lineWidth: 2)
                        .background(Circle().fill(isSelected ? Color.plumeTheme : .clear))
                        .frame(width: 10, height: 10)
                    Text(level.label).fontWeight(.medium)
                    Spacer()
                }
                Text(Leet.transform(sample, level: level))
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Le transformateur : une zone où coller du texte, et dessous le résultat en
/// 1337 au niveau choisi dans l'onglet.
///
/// Demandé par Pierre le 05/11 : « un endroit vide où tu peux y coller ton
/// texte, ça fait transcrire, et en bas tu as ton texte en 1337, tu as juste à
/// faire copier ». **Volontairement dans l'app et pas en raccourci global** —
/// il ne voulait pas d'une touche système pour ça.
///
/// Tout est **local et instantané** : la transformation se fait à la frappe,
/// sans réseau, sans clé. Un texte collé ne quitte jamais le Mac.
private struct LeetTransformer: View {
    @EnvironmentObject var prefs: Prefs
    @State private var input = ""
    @State private var copied = false

    private var output: String {
        input.isEmpty ? "" : Leet.transform(input, level: prefs.leetLevel)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // ⚠️ **Un vrai NSTextView, pas le `TextEditor` de SwiftUI.** Ce
            // dernier garde des marges internes qu'on ne peut pas régler : le
            // curseur apparaissait collé au coin haut-gauche, à côté du texte
            // d'invite, et rien ne s'alignait (signalé par Pierre le 05/11).
            // Ici on choisit `textContainerInset`, donc le curseur et l'invite
            // partagent exactement la même origine.
            PlaceholderTextView(text: $input,
                                placeholder: L("Collez ou tapez du texte ici…",
                                                "Paste or type text here…"))
                .frame(minHeight: 96)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.primary.opacity(0.04))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.10))
                )

            if !input.isEmpty {
                HStack {
                    Text(L("Résultat", "Result"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        let pb = NSPasteboard.general
                        pb.clearContents()
                        pb.setString(output, forType: .string)
                        copied = true
                        Task {
                            try? await Task.sleep(for: .seconds(1.4))
                            copied = false
                        }
                    } label: {
                        Label(copied ? L("Copié", "Copied") : L("Copier", "Copy"),
                              systemImage: copied ? "checkmark" : "doc.on.clipboard")
                    }
                    .buttonStyle(.borderless)
                    .disabled(output.isEmpty)
                }

                Text(output)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.primary.opacity(0.04))
                    )
            }
        }
        .padding(.vertical, 2)
    }
}

/// Un champ de texte multiligne **dont on maîtrise les marges**.
///
/// SwiftUI n'expose pas `textContainerInset` : le curseur et le texte d'invite
/// ne pouvaient pas s'aligner (signalé par Pierre le 05/11 — curseur collé au
/// coin, invite à côté). On passe donc par AppKit et on pose **une seule marge**,
/// utilisée à la fois par le texte et par l'invite : elles coïncident au pixel.
///
/// ⚠️ L'invite est une **vue par-dessus**, jamais du texte dans la zone de
/// saisie : sinon elle se retrouverait collée si on clique dessus, et elle
/// compterait comme du contenu.
struct PlaceholderTextView: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String

    /// La marge intérieure, choisie ici et **partagée** par le texte et l'invite.
    static let inset = NSSize(width: 9, height: 10)

    func makeNSView(context: Context) -> NSView {
        let scroll = NSTextView.scrollableTextView()
        guard let view = scroll.documentView as? NSTextView else { return scroll }

        view.delegate = context.coordinator
        view.isRichText = false
        view.allowsUndo = true
        view.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        view.textContainerInset = Self.inset
        // ⚠️ **Indispensable.** `lineFragmentPadding` ajoute 5 pt de marge
        // gauche/droite par défaut, en plus de `textContainerInset` : le texte
        // commencerait à 13 pt alors que l'invite est à 8, et le décalage
        // reviendrait. À zéro, les deux partent exactement du même point.
        view.textContainer?.lineFragmentPadding = 0
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.drawsBackground = false
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true

        // L'invite, dessinée par-dessus la zone de texte, à la même origine.
        let label = NSTextField(labelWithString: placeholder)
        label.font = view.font
        label.textColor = .placeholderTextColor
        label.isHidden = !text.isEmpty
        label.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(label)

        // Même origine que le texte : l'inset, sans correction à l'œil. Le
        // texte et l'invite utilisent la même police, donc leurs lignes de base
        // coïncident.
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: scroll.leadingAnchor, constant: Self.inset.width),
            label.topAnchor.constraint(equalTo: scroll.topAnchor, constant: Self.inset.height - 1),
            label.trailingAnchor.constraint(lessThanOrEqualTo: scroll.trailingAnchor, constant: -Self.inset.width),
        ])

        context.coordinator.label = label
        return scroll
    }

    func updateNSView(_ scroll: NSView, context: Context) {
        guard let view = scroll as? NSScrollView,
              let textView = view.documentView as? NSTextView else { return }
        if textView.string != text { textView.string = text }
        context.coordinator.label?.isHidden = !text.isEmpty
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: PlaceholderTextView
        weak var label: NSTextField?

        init(_ parent: PlaceholderTextView) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            parent.text = view.string
            label?.isHidden = !view.string.isEmpty
        }
    }
}

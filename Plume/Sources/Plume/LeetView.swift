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
                    Text(prefs.leetShortcut.explanation)
                    Text(L("Le premier geste garde son rôle, la dictée normale.",
                           "Your first gesture keeps its role, normal dictation."))
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

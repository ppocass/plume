import SwiftUI

/// Accueil : comment dicter, ce qui manque éventuellement, et les chiffres.
struct HomeView: View {
    @EnvironmentObject var prefs: Prefs
    @EnvironmentObject var history: HistoryStore
    @EnvironmentObject var permissions: Permissions
    @EnvironmentObject var navigation: Navigation

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header

                if !permissions.allGood {
                    PermissionsCard()
                }

                gestures

                HStack(spacing: 14) {
                    StatTile(value: history.words(since: Calendar.current.startOfDay(for: Date())),
                             label: L("mots aujourd'hui", "words today"), symbol: "text.word.spacing")
                    StatTile(value: history.words(since: Date().addingTimeInterval(-7 * 86_400)),
                             label: L("mots en 7 jours", "words in 7 days"), symbol: "calendar")
                    // Total depuis le début (l'historique, lui, s'arrête à 200).
                    StatTile(value: history.totals.dictations,
                             label: L("dictées", "dictations"), symbol: "waveform")
                }

                if let last = history.items.first(where: { !$0.failed }) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(L("Dernière dictée", "Latest")).font(.headline)
                            Spacer()
                            // Bouton texte à la couleur du thème, sans anneau de
                            // focus (il était entouré de gris à l'ouverture).
                            Button {
                                navigation.selection = .history
                            } label: {
                                HStack(spacing: 3) {
                                    Text(L("Historique", "History"))
                                    Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                                }
                                .foregroundStyle(Color.plumeTheme)
                            }
                            .buttonStyle(.plain)
                            .focusable(false)
                        }
                        HistoryRow(item: last)
                            .padding(14)
                            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    private var header: some View {
        HStack(spacing: 16) {
            AppGlyph(size: 58)
            VStack(alignment: .leading, spacing: 4) {
                Text("Plume").font(.system(size: 26, weight: .bold, design: .rounded))
                Text(L("Dictée vocale, dans toutes vos apps.", "Voice dictation, in every app."))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var gestures: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("Utilisation", "How to use")).font(.headline)
            VStack(spacing: 0) {
                GestureRow(keys: [prefs.shortcut.label], text: L("Démarrer la dictée", "Start dictation"))
                Divider().padding(.leading, 138)
                GestureRow(keys: [prefs.shortcut.label], text: L("Terminer et insérer le texte", "Stop and insert text"))
                Divider().padding(.leading, 138)
                GestureRow(keys: [prefs.shortcut.label, "×2"], text: L("Annuler", "Cancel"))
            }
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }
}

struct GestureRow: View {
    let keys: [String]
    let text: String

    var body: some View {
        HStack(spacing: 14) {
            HStack(spacing: 4) {
                ForEach(Array(keys.enumerated()), id: \.offset) { _, key in
                    KeyCap(key)
                }
            }
            .frame(width: 110, alignment: .leading)
            Text(text)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }
}

struct KeyCap: View {
    let key: String
    init(_ key: String) { self.key = key }
    var body: some View {
        Text(key)
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.primary.opacity(0.08)))
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Color.primary.opacity(0.15)))
            .fixedSize()
    }
}

struct StatTile: View {
    let value: Int
    let label: String
    let symbol: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: symbol)
                .foregroundStyle(Color.plumeTheme)
            Text(formatNumber(value))
                .font(.system(size: 24, weight: .semibold, design: .rounded).monospacedDigit())
                .contentTransition(.numericText())
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// L'icône de l'app (la plume), la vraie : celle du Dock, lue dans le bundle.
/// Le dessin de l'icône laisse une marge (ombre comprise) : on l'agrandit un
/// peu pour que la plaque fasse `size`.
struct AppGlyph: View {
    let size: CGFloat
    var body: some View {
        Image(nsImage: NSApp.applicationIconImage)
            .resizable()
            .interpolation(.high)
            .frame(width: size * 1.24, height: size * 1.24)
            .frame(width: size, height: size)
    }
}

/// Ce qui manque pour que la dictée marche, avec le bouton pour le régler.
struct PermissionsCard: View {
    @EnvironmentObject var permissions: Permissions

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(L("Autorisations requises", "Permissions required"), systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(.orange)
            PermissionRows()
        }
        .padding(16)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.orange.opacity(0.25)))
    }
}

/// Les deux autorisations, réutilisées (Accueil, Réglages).
struct PermissionRows: View {
    @EnvironmentObject var permissions: Permissions
    var body: some View {
        PermissionRow(title: L("Micro", "Microphone"), detail: L("Pour entendre votre voix.", "To hear your voice."),
                      ok: permissions.microphone == .authorized) { permissions.requestMicrophone() }
        PermissionRow(title: L("Accessibilité", "Accessibility"), detail: L("Pour le raccourci et l'insertion du texte.", "For the shortcut and text insertion."),
                      ok: permissions.accessibility) { permissions.requestAccessibility() }
    }
}

struct PermissionRow: View {
    let title: String
    let detail: String
    let ok: Bool
    let action: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: ok ? "checkmark.circle.fill" : "circle.dashed")
                .font(.system(size: 18))
                .foregroundStyle(ok ? Color.plumeDone : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.medium)
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if !ok {
                Button(L("Autoriser", "Allow"), action: action)
            }
        }
    }
}

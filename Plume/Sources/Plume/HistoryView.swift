import SwiftUI

/// L'historique : les 200 dernières dictées, par jour, la plus récente en haut.
/// Celles qui n'ont pas pu être collées (pas de champ de texte) sont là aussi.
struct HistoryView: View {
    @EnvironmentObject var history: HistoryStore
    @State private var search = ""
    @State private var confirmClear = false

    var body: some View {
        Group {
            if history.items.isEmpty {
                ContentUnavailableView {
                    Label(L("Aucune dictée", "No dictations"), systemImage: "waveform")
                } description: {
                    Text(L("Appuyez sur \(Prefs.shared.shortcut.label) pour commencer.", "Press \(Prefs.shared.shortcut.label) to start."))
                }
            } else if filtered.isEmpty {
                ContentUnavailableView.search(text: search)
            } else {
                List {
                    ForEach(groups, id: \.day) { group in
                        Section(group.label) {
                            ForEach(group.items) { item in
                                HistoryRow(item: item)
                                    .padding(.vertical, 6)
                            }
                        }
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }
        }
        .searchable(text: $search, placement: .toolbar, prompt: L("Rechercher", "Search"))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    confirmClear = true
                } label: {
                    Label(L("Tout effacer", "Clear All"), systemImage: "trash")
                }
                .disabled(history.items.isEmpty)
                .help(L("Tout effacer", "Clear All"))
            }
        }
        .confirmationDialog(L("Effacer tout l'historique ?", "Clear all history?"), isPresented: $confirmClear) {
            Button(L("Tout effacer", "Clear All"), role: .destructive) { history.removeAll() }
            Button(L("Annuler", "Cancel"), role: .cancel) {}
        } message: {
            Text(L("\(history.items.count) dictées seront supprimées.", "\(history.items.count) dictations will be deleted."))
        }
    }

    private var filtered: [Dictation] {
        guard !search.isEmpty else { return history.items }
        return history.items.filter {
            $0.text.localizedCaseInsensitiveContains(search) || ($0.appName ?? "").localizedCaseInsensitiveContains(search)
        }
    }

    private struct DayGroup { let day: Date; let label: String; let items: [Dictation] }

    private var groups: [DayGroup] {
        let calendar = Calendar.current
        let byDay = Dictionary(grouping: filtered) { calendar.startOfDay(for: $0.date) }
        return byDay.keys.sorted(by: >).map { day in
            DayGroup(day: day, label: Self.dayLabel(day), items: byDay[day]!.sorted { $0.date > $1.date })
        }
    }

    static func dayLabel(_ day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return L("Aujourd'hui", "Today") }
        if calendar.isDateInYesterday(day) { return L("Hier", "Yesterday") }
        let f = DateFormatter()
        f.locale = AppLanguage.current.locale
        f.setLocalizedDateFormatFromTemplate("EEEEdMMMM")
        let s = f.string(from: day)
        return s.prefix(1).uppercased() + s.dropFirst()
    }
}

struct HistoryRow: View {
    @EnvironmentObject var history: HistoryStore
    let item: Dictation
    @State private var hovering = false
    @State private var copied = false
    @State private var correcting = false
    @State private var expanded = false

    /// Au-delà, le texte est replié sur 6 lignes (« Afficher tout » le déplie).
    private var isLong: Bool { item.text.count > 420 }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                if item.failed {
                    Text(L("Transcription impossible · \(Int(item.audioSeconds.rounded())) s d'audio conservées", "Couldn't transcribe · \(Int(item.audioSeconds.rounded())) s of audio kept"))
                        .foregroundStyle(.secondary)
                } else if isLong && !expanded {
                    // Replié : pas sélectionnable, sinon le texte se déplie au clic
                    // sans que la rangée grandisse, et recouvre les suivantes.
                    Text(item.text)
                        .lineLimit(6)
                        .fixedSize(horizontal: false, vertical: true)
                        .onTapGesture { expanded = true }
                    Button(L("Afficher tout", "Show All")) { expanded = true }
                        .buttonStyle(.link)
                        .font(.callout)
                } else {
                    Text(item.text)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    if isLong {
                        Button(L("Réduire", "Show Less")) { expanded = false }
                            .buttonStyle(.link)
                            .font(.callout)
                    }
                }
                HStack(spacing: 8) {
                    Text(item.date, style: .time)
                    if let app = item.appName {
                        Text("·")
                        Text(app)
                    }
                    if !item.failed {
                        Text("·")
                        Text(L("\(item.wordCount) mots", "\(item.wordCount) words"))
                    }
                    if !item.pasted && !item.failed {
                        Tag(text: L("Non inséré", "Not inserted"), color: .plumeTheme)
                    }
                    if item.polished {
                        Tag(text: L("Nettoyé", "Cleaned"), color: .secondary)
                    }
                    if item.failed {
                        Tag(text: L("Échec", "Failed"), color: .orange)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if item.failed {
                Button(L("Réessayer", "Retry")) { DictationController.shared.retry(item) }
            } else {
                Button {
                    copy(item.text)
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.borderless)
                .help(L("Copier", "Copy"))
                .opacity(hovering || copied ? 1 : 0)
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .sheet(isPresented: $correcting) { CorrectWordSheet(item: item) }
        .contextMenu {
            if !item.failed {
                Button(L("Copier", "Copy")) { copy(item.text) }
                if item.polished && item.raw != item.text {
                    Button(L("Copier le texte brut", "Copy Raw Text")) { copy(item.raw) }
                }
                Divider()
                Button(L("Corriger un mot…", "Fix a Word…")) { correcting = true }
                Divider()
            }
            Button(L("Supprimer", "Delete"), role: .destructive) { history.remove(item.id) }
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.2))
            copied = false
        }
    }
}

struct Tag: View {
    let text: String
    let color: Color
    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(color)
            .background(Capsule().fill(color.opacity(0.14)))
    }
}

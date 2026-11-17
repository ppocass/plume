import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// La bibliothèque des réunions : les dossiers de `Reunions/` du plus récent
/// au plus ancien, et les actions qui touchent au disque. Toute suppression
/// passe par la Corbeille : un dossier de réunion, c'est du travail.
@MainActor
final class MeetingLibrary: ObservableObject {
    @Published private(set) var meetings: [MeetingFolder] = []
    /// L'en-tête de chaque réunion, relu à chaque `reload()` : la liste ne
    /// relit pas les fichiers à chaque redessin.
    private var metas: [String: MeetingMeta] = [:]

    /// L'en-tête déjà lu par le dernier `reload()` : la liste ne touche pas au
    /// disque pendant qu'elle se dessine.
    func meta(for m: MeetingFolder) -> MeetingMeta? {
        metas[m.id]
    }

    func reload() {
        let fm = FileManager.default
        var found: [MeetingFolder] = []
        var loaded: [String: MeetingMeta] = [:]
        if let children = try? fm.contentsOfDirectory(at: MeetingFolder.root,
                                                     includingPropertiesForKeys: nil) {
            for url in children {
                let folder = MeetingFolder(url: url)
                // Un dossier sans méta n'est pas une réunion (ou n'est pas fini
                // d'être créé) : on ne montre pas un fantôme dans la liste.
                guard let meta = folder.readMeta() else { continue }
                found.append(folder)
                loaded[folder.id] = meta
            }
        }
        found.sort { (loaded[$0.id]?.startedAt ?? .distantPast) > (loaded[$1.id]?.startedAt ?? .distantPast) }
        metas = loaded
        meetings = found
    }

    func trash(_ m: MeetingFolder) {
        sendToTrash(m.url)
        reload()
    }

    func keepTextOnly(_ m: MeetingFolder) {
        let fm = FileManager.default
        for url in [m.micURL, m.systemURL] where fm.fileExists(atPath: url.path) {
            sendToTrash(url)
        }
        reload()
    }

    func copyText(_ m: MeetingFolder) {
        guard let meta = m.readMeta() else { return }
        let text = MeetingFiles.markdown(meta: meta, paragraphs: m.readParagraphs())
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        pasteboard.writeObjects([item])
    }

    func export(_ m: MeetingFolder) {
        guard let meta = m.readMeta() else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md")!]
        panel.nameFieldStringValue = m.name + ".md"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let text = MeetingFiles.markdown(meta: meta, paragraphs: m.readParagraphs())
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            Log.info("export de réunion impossible (\(url.lastPathComponent))")
        }
    }

    func revealInFinder(_ m: MeetingFolder) {
        if FileManager.default.fileExists(atPath: m.markdownURL.path) {
            NSWorkspace.shared.activateFileViewerSelecting([m.markdownURL])
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([m.url])
        }
    }

    private func sendToTrash(_ url: URL) {
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        } catch {
            Log.info("mise à la Corbeille impossible (\(url.lastPathComponent))")
        }
    }
}

/// La page « Réunions » : la liste des réunions à gauche, celle qu'on relit à
/// droite. Sœur de l'historique : même en-tête, mêmes rangées, même silence.
struct MeetingsView: View {
    @StateObject private var library = MeetingLibrary()
    @ObservedObject private var recorder = MeetingRecorder.shared
    @State private var selection: String?

    var body: some View {
        Group {
            if library.meetings.isEmpty {
                emptyState
            } else {
                HStack(spacing: 0) {
                    meetingList
                    Divider()
                    detail
                }
            }
        }
        .task {
            library.reload()
            syncSelection(library.meetings)
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                // Pendant une réunion, la liste suit les compteurs et le
                // nouveau dossier ; sinon rien ne bouge, inutile de relire.
                // L'état est relu à la source : la boucle survit aux redessins.
                if MeetingRecorder.shared.isRecording { library.reload() }
            }
        }
        .onChange(of: library.meetings) { _, list in syncSelection(list) }
    }

    private var meetingList: some View {
        List {
            ForEach(library.meetings) { m in
                Button {
                    selection = m.id
                } label: {
                    MeetingRow(meta: library.meta(for: m),
                               isRecording: recorder.isRecording && recorder.folder == m,
                               isSelected: selection == m.id)
                }
                .buttonStyle(.plain)
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .frame(width: 260)
    }

    @ViewBuilder private var detail: some View {
        if let m = library.meetings.first(where: { $0.id == selection }) {
            // Une identité par réunion : les paragraphes de la précédente ne
            // restent pas affichés une seconde sous le nouveau titre.
            MeetingDetailView(meeting: m, library: library, recorder: recorder)
                .id(m.id)
        } else {
            Color.clear
        }
    }

    private var emptyState: some View {
        let hold = Int(Prefs.shared.meetingHoldSeconds)
        return VStack(spacing: 10) {
            Image(systemName: "person.2.wave.2")
                .font(.system(size: 34))
                .foregroundStyle(.secondary)
            Text(L("Aucune réunion", "No meetings yet"))
                .font(.title3.weight(.semibold))
            Text(L("Tenez votre touche de dictée \(hold) secondes pour enregistrer une réunion : votre micro et le son du Mac, transcrits en direct.",
                   "Hold your dictation key for \(hold) seconds to record a meeting: your microphone and your Mac's audio, transcribed live."))
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 380)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    private func syncSelection(_ list: [MeetingFolder]) {
        // La première réunion est ouverte d'office, et une suppression laisse
        // la place à la suivante plutôt qu'à une page vide.
        if selection == nil || !list.contains(where: { $0.id == selection }) {
            selection = list.first?.id
        }
    }
}

/// Une rangée de la liste : la date, puis la durée (ou « En cours »), la
/// source et le nombre de mots.
private struct MeetingRow: View {
    let meta: MeetingMeta?
    let isRecording: Bool
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(meetingDateLabel(meta?.startedAt ?? Date()))
                .font(.body.weight(.medium))
                .lineLimit(1)
            HStack(spacing: 5) {
                if isRecording {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 7, height: 7)
                    Text(L("En cours", "Recording"))
                } else {
                    Text(MeetingFiles.duration(meta?.duration ?? 0))
                }
                if let meta {
                    Text("·")
                    Text(meta.source).lineLimit(1)
                    Text("·")
                    Text(L("\(meta.words) mots", "\(meta.words) words"))
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.accentColor.opacity(0.15))
            }
        }
        .contentShape(Rectangle())
    }
}

/// La réunion ouverte : son en-tête, ses actions, puis le texte.
private struct MeetingDetailView: View {
    let meeting: MeetingFolder
    @ObservedObject var library: MeetingLibrary
    @ObservedObject var recorder: MeetingRecorder

    @State private var meta: MeetingMeta?
    @State private var paragraphs: [MeetingParagraph] = []
    @State private var hasAudio = false
    @State private var audioBytes: Int64 = 0
    @State private var confirmDelete = false
    @State private var confirmKeepText = false
    /// Incrémenté à chaque relecture : c'est ce qui déclenche le défilement,
    /// même quand seul le texte du dernier paragraphe a grandi.
    @State private var reloadTick = 0

    private var isRecordingThis: Bool { recorder.isRecording && recorder.folder == meeting }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            transcript
        }
        // Le texte prend la place laissée par la liste, et rien de plus.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: meeting.id) {
            load()
            // Le texte s'écrit encore : on le relit toutes les deux secondes,
            // jamais plus vite (le dossier reste froid le reste du temps).
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                // Même raison que la liste : l'état d'enregistrement est relu
                // à la source, pas figé au démarrage de la boucle.
                if MeetingRecorder.shared.isRecording, MeetingRecorder.shared.folder == meeting {
                    load()
                }
            }
        }
        .confirmationDialog(L("Supprimer cette réunion ?", "Delete this meeting?"),
                            isPresented: $confirmDelete, titleVisibility: .visible) {
            Button(L("Garder", "Keep"), role: .cancel) {}
            Button(L("Supprimer", "Delete"), role: .destructive) { deleteNow() }
        } message: {
            Text(L("Elle part dans la Corbeille, avec son texte et son audio.",
                   "It goes to the Trash, with its text and audio."))
        }
        .confirmationDialog(L("Garder seulement le texte ?", "Keep only the text?"),
                            isPresented: $confirmKeepText, titleVisibility: .visible) {
            Button(L("Annuler", "Cancel"), role: .cancel) {}
            Button(L("Mettre l'audio à la Corbeille", "Move Audio to Trash"), role: .destructive) {
                library.keepTextOnly(meeting)
                load()
            }
        } message: {
            Text(L("Les deux pistes audio partent dans la Corbeille. Le texte reste.",
                   "Both audio tracks go to the Trash. The text stays."))
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(meetingDateLabel(meta?.startedAt ?? Date()))
                .font(.title3.weight(.semibold))
            Text(summary)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button {
                    library.copyText(meeting)
                } label: {
                    Label(L("Copier", "Copy"), systemImage: "doc.on.doc")
                }
                .help(L("Copier le texte de la réunion", "Copy the meeting text"))
                Button {
                    library.export(meeting)
                } label: {
                    Label(L("Exporter…", "Export…"), systemImage: "square.and.arrow.up")
                }
                .help(L("Exporter en Markdown", "Export as Markdown"))
                Button {
                    library.revealInFinder(meeting)
                } label: {
                    Label(L("Afficher dans le Finder", "Show in Finder"), systemImage: "folder")
                }
                .help(L("Afficher le dossier de la réunion", "Show the meeting folder"))
                if hasAudio {
                    Button {
                        confirmKeepText = true
                    } label: {
                        Label(L("Garder le texte seulement", "Keep text only"), systemImage: "waveform.slash")
                    }
                    .help(L("L'audio pèse \(audioSize). Il part dans la Corbeille, le texte reste.",
                            "The audio is \(audioSize). It goes to the Trash, the text stays."))
                    .disabled(isRecordingThis)
                }
                Button(role: .destructive) {
                    requestDelete()
                } label: {
                    Label(L("Supprimer", "Delete"), systemImage: "trash")
                }
                .help(L("Mettre la réunion à la Corbeille", "Move the meeting to the Trash"))
                .disabled(isRecordingThis)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 14)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(paragraphs) { p in
                        paragraphRow(p)
                            .id(p.id)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
            }
            // Une réunion en cours grandit : on suit la dernière phrase.
            .onChange(of: reloadTick) { _, _ in
                guard isRecordingThis, let last = paragraphs.last else { return }
                proxy.scrollTo(last.id, anchor: .bottom)
            }
        }
    }

    private func paragraphRow(_ p: MeetingParagraph) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(MeetingFiles.timestamp(p.start))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .leading)
            Text(p.speaker.label)
                .font(.callout.weight(.semibold))
                .foregroundStyle(p.speaker == .me ? Color.accentColor : Color.orange)
                .frame(width: 44, alignment: .leading)
            Text(p.text)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if !p.polished && Prefs.polishWanted {
                Text(L("non nettoyé", "not cleaned up"))
                    .font(.caption.italic())
                    .foregroundStyle(.secondary)
            }
        }
        .opacity(p.open ? 0.6 : 1)
    }

    private var summary: String {
        let words = meta?.words ?? 0
        let parts = [MeetingFiles.duration(meta?.duration ?? 0),
                     meta?.source,
                     meta?.model,
                     L("\(words) mots", "\(words) words")]
        return parts.compactMap { $0 }.joined(separator: " · ")
    }

    private var audioSize: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: audioBytes)
    }

    private func load() {
        meta = meeting.readMeta()
        paragraphs = meeting.readParagraphs()
        hasAudio = meeting.hasAudio
        audioBytes = meeting.audioBytes
        reloadTick += 1
    }

    private func requestDelete() {
        guard !isRecordingThis else { return }
        // Dix secondes : une réunion lancée par erreur, rien à confirmer.
        // Sans méta lue, on ne sait pas : on demande.
        if let duration = meta?.duration, duration < 10 {
            deleteNow()
        } else {
            confirmDelete = true
        }
    }

    private func deleteNow() {
        library.trash(meeting)
    }
}

/// « 22 oct. 2026 à 15:04 » (ou la forme anglaise), dans la langue de l'app.
private func meetingDateLabel(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = AppLanguage.current.locale
    formatter.dateStyle = .medium
    formatter.timeStyle = .short
    return formatter.string(from: date)
}

import AppKit
import Combine
import SwiftUI

/// Le widget de réunion, en bas à gauche : **un seul objet, plusieurs tailles**.
///
/// - **anneau** : pendant l'appui long, il se remplit (dès 0,8 s) ;
/// - **orbe** : point rouge qui bat, chrono, deux vumètres (micro / son du
///   Mac — le second est la seule preuve que l'autre côté est capté), arrêt ■,
///   abandon ✕ ;
/// - **panneau** (clic sur l'orbe) : le texte s'écrit en direct, la fin
///   seulement ; clic sur le titre → la page Réunions ;
/// - **fin** : « Copié · Ouvrir · Coller ».
///
/// Comme la pastille de dictée, c'est un `NSPanel` **non activant** qui ne
/// peut jamais devenir fenêtre clé : il ne vole jamais le focus (aucun cadre
/// de focus, le curseur reste dans l'app de visio). Il est **absent des
/// captures et des partages d'écran** (`sharingType = .none`) sauf si le
/// réglage le demande. Déplaçable ; sa place est retenue.
@MainActor
final class MeetingWidgetController {
    static let shared = MeetingWidgetController()

    let model = MeetingWidgetModel()
    private lazy var panel = MeetingPanel(model: model)
    private var observers: Set<AnyCancellable> = []
    private var hideTask: Task<Void, Never>?

    /// Branche le widget sur l'enregistreur et la touche (au lancement).
    func install() {
        let recorder = MeetingRecorder.shared
        recorder.onFinished = { [weak self] folder, text, reason in self?.showEnded(folder: folder, text: text, reason: reason) }
        recorder.onFailure = { [weak self] message in self?.flash(message) }
        recorder.$phase
            .removeDuplicates()
            .sink { [weak self] phase in self?.phaseChanged(phase) }
            .store(in: &observers)
        model.$mode.combineLatest(model.$expanded, model.$confirmingDiscard)
            .sink { [weak self] _ in DispatchQueue.main.async { self?.layout() } }
            .store(in: &observers)
        Prefs.shared.$meetingShowInCaptures
            .sink { [weak self] show in
                guard let self, !self.forceVisible else { return }
                self.panel.sharingType = show ? .readOnly : .none
            }
            .store(in: &observers)
    }

    /// Autotest : visible dans les captures d'écran, quel que soit le réglage.
    func showInCapturesForTests() {
        panel.sharingType = .readOnly
        forceVisible = true
    }
    private var forceVisible = false

    /// L'anneau de l'appui long (`nil` = le retirer).
    func holdProgress(_ progress: Double?) {
        if let progress {
            hideTask?.cancel()
            model.mode = .hold(min(1, max(0, progress)))
        } else if case .hold = model.mode {
            model.mode = MeetingRecorder.shared.phase == .idle ? .hidden : .live
        }
    }

    private func phaseChanged(_ phase: MeetingRecorder.Phase) {
        switch phase {
        case .starting, .recording:
            hideTask?.cancel()
            model.expanded = false
            model.confirmingDiscard = false
            model.mode = .live
        case .finishing:
            model.confirmingDiscard = false
            model.mode = .finishing
        case .idle:
            if case .live = model.mode { model.mode = .hidden }
            if case .finishing = model.mode { model.mode = .hidden }
        }
    }

    private func showEnded(folder: MeetingFolder, text: String, reason: MeetingRecorder.StopReason) {
        let meta = folder.readMeta()
        copy(text)
        model.ended = .init(folder: folder, text: text, reason: reason.message,
                            summary: [meta.map { MeetingFiles.duration($0.duration) },
                                      meta.map { L("\($0.words) mots", "\($0.words) words") }]
                                .compactMap { $0 }.joined(separator: " · "))
        model.mode = .ended
        scheduleHide(after: 15)
    }

    func flash(_ message: String) {
        model.message = message
        model.mode = .message
        scheduleHide(after: 3)
    }

    private func scheduleHide(after seconds: Double) {
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self else { return }
            if case .ended = self.model.mode { self.model.mode = .hidden }
            if case .message = self.model.mode { self.model.mode = .hidden }
        }
    }

    // MARK: Actions du widget

    func close() {
        hideTask?.cancel()
        model.mode = .hidden
    }

    func keepEndedOpen() { hideTask?.cancel() }

    func openMeetings() {
        MainWindowController.shared.show(section: .meetings)
        if case .ended = model.mode { close() }
    }

    func paste() {
        guard let ended = model.ended else { return }
        close()
        // Le panneau n'a jamais pris le focus : le texte part dans le champ où
        // était le curseur.
        TextInserter.paste(ended.text)
    }

    /// ✕ : moins de 10 s → abandon sans question (démarrage raté) ; sinon
    /// confirmation **dans le widget** (une alerte activerait l'app et volerait le focus).
    func discardTapped() {
        if MeetingRecorder.shared.elapsed < 10 {
            MeetingRecorder.shared.discard()
        } else {
            model.confirmingDiscard = true
        }
    }

    private func copy(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        pasteboard.writeObjects([item])
    }

    // MARK: Taille et place

    private func layout() {
        let size = model.size
        if size == .zero {
            panel.orderOut(nil)
            return
        }
        panel.place(size: size)
        if !panel.isVisible { panel.orderFrontRegardless() }
    }
}

@MainActor
final class MeetingWidgetModel: ObservableObject {
    enum Mode: Equatable {
        case hidden
        case hold(Double)
        case live
        case finishing
        case ended
        case message
    }

    struct Ended: Equatable {
        let folder: MeetingFolder
        let text: String
        let reason: String?
        let summary: String
    }

    @Published var mode: Mode = .hidden
    @Published var expanded = false
    @Published var confirmingDiscard = false
    var ended: Ended?
    var message = ""

    static let ringSize = NSSize(width: 64, height: 64)
    static let orbSize = NSSize(width: 248, height: 44)
    static let panelSize = NSSize(width: 420, height: 300)
    static let endedSize = NSSize(width: 360, height: 112)
    static let messageSize = NSSize(width: 300, height: 44)
    /// La marge autour du contenu, pour l'ombre.
    static let inset: CGFloat = 10

    var size: NSSize {
        let content: NSSize
        switch mode {
        case .hidden: return .zero
        case .hold: content = Self.ringSize
        case .live: content = expanded && !confirmingDiscard ? Self.panelSize : Self.orbSize
        case .finishing: content = Self.orbSize
        case .ended: content = Self.endedSize
        case .message: content = Self.messageSize
        }
        return NSSize(width: content.width + 2 * Self.inset, height: content.height + 2 * Self.inset)
    }
}

/// Le panneau lui-même. Ancré par son coin **bas gauche** : il grandit vers le
/// haut et la droite, et revient à la même place en se repliant.
final class MeetingPanel: NSPanel {
    private static let originKey = "meetingWidgetOrigin"
    private var placing = false

    init(model: MeetingWidgetModel) {
        super.init(contentRect: NSRect(origin: .zero, size: MeetingWidgetModel.orbSize),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isMovableByWindowBackground = true
        animationBehavior = .none
        sharingType = Prefs.shared.meetingShowInCaptures ? .readOnly : .none
        let hosting = NSHostingView(rootView: MeetingWidgetView()
            .environmentObject(model)
            .environmentObject(MeetingRecorder.shared)
            .environmentObject(MeetingRecorder.shared.levels)
            .focusEffectDisabled())
        hosting.autoresizingMask = [.width, .height]
        contentView = hosting
        NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: self, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.rememberOrigin() }
        }
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func place(size: NSSize) {
        var origin = savedOrigin ?? defaultOrigin
        // Toujours entièrement visible, même si l'écran a changé depuis.
        if let screen = NSScreen.screens.first(where: { $0.visibleFrame.contains(origin) }) ?? NSScreen.main {
            let v = screen.visibleFrame
            origin.x = min(max(origin.x, v.minX), v.maxX - size.width)
            origin.y = min(max(origin.y, v.minY), v.maxY - size.height)
        }
        placing = true
        setFrame(NSRect(origin: origin, size: size), display: true)
        placing = false
    }

    private var savedOrigin: NSPoint? {
        guard let s = UserDefaults.standard.string(forKey: Self.originKey) else { return nil }
        let p = NSPointFromString(s)
        return NSScreen.screens.contains { $0.frame.contains(p) } ? p : nil
    }

    /// En bas à gauche de l'écran principal, au-dessus du Dock.
    private var defaultOrigin: NSPoint {
        let v = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        return NSPoint(x: v.minX + 6, y: v.minY + 6)
    }

    private func rememberOrigin() {
        guard !placing else { return }
        UserDefaults.standard.set(NSStringFromPoint(frame.origin), forKey: Self.originKey)
    }
}

// MARK: - Vues

struct MeetingWidgetView: View {
    @EnvironmentObject var model: MeetingWidgetModel

    var body: some View {
        Group {
            switch model.mode {
            case .hidden: Color.clear
            case .hold(let progress): HoldRing(progress: progress)
            case .live:
                if model.confirmingDiscard { DiscardConfirmation() }
                else if model.expanded { MeetingSheet() }
                else { MeetingOrb() }
            case .finishing: FinishingOrb()
            case .ended: EndedCard()
            case .message: MessageCapsule(text: model.message)
            }
        }
        .padding(MeetingWidgetModel.inset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
    }
}

/// Le fond sombre de l'orbe, de l'anneau et des messages (comme la pastille).
private struct DarkCapsule: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(Capsule().fill(Color.black.opacity(0.88)))
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
            .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
            .environment(\.colorScheme, .dark)
    }
}

private struct HoldRing: View {
    let progress: Double
    var body: some View {
        ZStack {
            Circle().fill(Color.black.opacity(0.88))
            Circle().stroke(Color.white.opacity(0.15), lineWidth: 4).padding(8)
            Circle().trim(from: 0, to: progress)
                .stroke(Color.red, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .padding(8)
            Image(systemName: "person.2.wave.2.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: MeetingWidgetModel.ringSize.width, height: MeetingWidgetModel.ringSize.height)
        .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
    }
}

/// Le point rouge qui bat : allumé une seconde, atténué la suivante. Un
/// redessin par seconde, comme le chrono — une animation continue (même un
/// effet de symbole) refaisait la mise en page du widget à chaque image : 16 %
/// de processeur pendant toute la réunion.
private struct PulsingDot: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let on = Int(context.date.timeIntervalSinceReferenceDate) % 2 == 0
            Circle().fill(Color.red).frame(width: 9, height: 9).opacity(on ? 1 : 0.35)
        }
        .frame(width: 9, height: 9)
    }
}

/// Le chrono, redessiné une fois par seconde par SwiftUI lui-même.
private struct Chrono: View {
    let start: Date?
    var body: some View {
        if let start {
            Text(timerInterval: start...Date.distantFuture, countsDown: false)
                .monospacedDigit()
        } else {
            Text("0:00").monospacedDigit()
        }
    }
}

/// Un vumètre : une icône et cinq barres. Orange quand la piste est muette depuis une minute.
private struct Meter: View {
    let symbol: String
    /// Barres allumées, 0…5.
    let bars: Int
    let warning: Bool
    let help: String
    let color: Color

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: symbol).font(.system(size: 10, weight: .semibold))
            HStack(alignment: .center, spacing: 2) {
                ForEach(0..<MeetingLevels.bars, id: \.self) { i in
                    Capsule().frame(width: 3, height: 4 + CGFloat(i) * 2.5).opacity(i < bars ? 1 : 0.25)
                }
            }
        }
        .foregroundStyle(warning ? Color.orange : color)
        .help(help)
    }
}

private struct Meters: View {
    /// Blanc sur l'orbe sombre, gris sur la feuille blanche.
    var color: Color = .white.opacity(0.9)
    @EnvironmentObject var recorder: MeetingRecorder
    @EnvironmentObject var levels: MeetingLevels

    var body: some View {
        HStack(spacing: 10) {
            Meter(symbol: "mic.fill", bars: levels.me, warning: recorder.warnings.contains(.micSilent),
                  help: recorder.warnings.contains(.micSilent)
                    ? L("Le micro n'entend rien depuis une minute", "The microphone has heard nothing for a minute")
                    : L("Votre micro", "Your microphone"), color: color)
            Meter(symbol: "speaker.wave.2.fill", bars: levels.them, warning: recorder.warnings.contains(.systemSilent),
                  help: recorder.warnings.contains(.systemSilent)
                    ? L("Rien ne sort du Mac depuis une minute", "Nothing has come out of the Mac for a minute")
                    : L("Le son du Mac (les autres)", "The Mac's audio (the others)"), color: color)
        }
    }
}

private struct IconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.white.opacity(0.14)))
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

private struct MeetingOrb: View {
    @EnvironmentObject var recorder: MeetingRecorder
    @EnvironmentObject var model: MeetingWidgetModel

    var body: some View {
        HStack(spacing: 10) {
            Button { model.expanded = true } label: {
                HStack(spacing: 8) {
                    PulsingDot()
                    Chrono(start: recorder.startedAt)
                        .font(.system(size: 13, weight: .semibold))
                        .frame(minWidth: 40, alignment: .leading)
                    Meters()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L("Afficher le texte", "Show the text"))
            Spacer(minLength: 0)
            IconButton(symbol: "stop.fill", help: L("Arrêter et garder", "Stop and keep")) { recorder.stop() }
            IconButton(symbol: "xmark", help: L("Abandonner cette réunion", "Discard this meeting")) {
                MeetingWidgetController.shared.discardTapped()
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .frame(width: MeetingWidgetModel.orbSize.width, height: MeetingWidgetModel.orbSize.height)
        .modifier(DarkCapsule())
    }
}

private struct FinishingOrb: View {
    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(L("Finalisation…", "Finishing…")).font(.system(size: 13, weight: .medium))
        }
        .foregroundStyle(.white)
        .frame(width: MeetingWidgetModel.orbSize.width, height: MeetingWidgetModel.orbSize.height)
        .modifier(DarkCapsule())
    }
}

private struct DiscardConfirmation: View {
    @EnvironmentObject var recorder: MeetingRecorder
    @EnvironmentObject var model: MeetingWidgetModel

    var body: some View {
        HStack(spacing: 8) {
            Text(L("Supprimer cette réunion ?", "Delete this meeting?"))
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
            Spacer(minLength: 0)
            Button(L("Garder", "Keep")) { model.confirmingDiscard = false }
            Button(L("Supprimer", "Delete")) { recorder.discard() }
                .foregroundStyle(.red)
        }
        .buttonStyle(.plain)
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .frame(width: MeetingWidgetModel.orbSize.width, height: MeetingWidgetModel.orbSize.height)
        .modifier(DarkCapsule())
        .help(L("Elle part dans la Corbeille, avec son texte et son audio.", "It goes to the Trash, with its text and audio."))
    }
}

/// La feuille blanche : le texte s'écrit en direct. Seule la fin est dessinée
/// (40 paragraphes au plus) : deux heures de réunion ne coûtent pas plus cher
/// à afficher que deux minutes.
private struct MeetingSheet: View {
    @EnvironmentObject var recorder: MeetingRecorder
    @EnvironmentObject var model: MeetingWidgetModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                PulsingDot()
                Button { MeetingWidgetController.shared.openMeetings() } label: {
                    Text(L("Réunion", "Meeting") + (recorder.source.isEmpty ? "" : " · " + recorder.source))
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
                .help(L("Ouvrir dans Plume", "Open in Plume"))
                Chrono(start: recorder.startedAt)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                SheetButton(symbol: "chevron.down", help: L("Réduire", "Collapse")) { model.expanded = false }
                SheetButton(symbol: "stop.fill", help: L("Arrêter et garder", "Stop and keep")) { recorder.stop() }
                SheetButton(symbol: "xmark", help: L("Abandonner cette réunion", "Discard this meeting")) {
                    MeetingWidgetController.shared.discardTapped()
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 40)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        if recorder.lines.isEmpty {
                            Text(L("Le texte s'écrit ici dès que quelqu'un parle.", "The text appears here as soon as someone speaks."))
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                        }
                        ForEach(recorder.lines) { line in
                            LineView(line: line, isLast: line.id == recorder.lines.last?.id).id(line.id)
                        }
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: recorder.lines) { _, lines in
                    if let last = lines.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
                .onAppear { if let last = recorder.lines.last { proxy.scrollTo(last.id, anchor: .bottom) } }
            }
            Divider()
            HStack {
                Meters(color: .secondary)
                Spacer()
            }
            .padding(.horizontal, 14)
            .frame(height: 30)
        }
        .frame(width: MeetingWidgetModel.panelSize.width, height: MeetingWidgetModel.panelSize.height)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(nsColor: .textBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.1), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .shadow(color: .black.opacity(0.2), radius: 8, y: 3)
    }
}

private struct SheetButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).frame(width: 22, height: 22)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(help)
    }
}

private struct LineView: View {
    let line: MeetingRecorder.Line
    let isLast: Bool

    var body: some View {
        (Text(line.speaker.label + "  ")
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(line.speaker == .me ? .accentColor : .orange)
         + Text(line.text).font(.system(size: 13)))
            .foregroundStyle(isLast ? .primary : .secondary)
            .opacity(line.open ? 0.65 : 1)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct EndedCard: View {
    @EnvironmentObject var model: MeetingWidgetModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("Réunion enregistrée", "Meeting saved")).font(.system(size: 13, weight: .semibold))
                    Text([model.ended?.summary, model.ended?.reason].compactMap { $0 }.filter { !$0.isEmpty }
                        .joined(separator: " · "))
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                IconButton(symbol: "xmark", help: L("Fermer", "Close")) { MeetingWidgetController.shared.close() }
            }
            HStack(spacing: 8) {
                Label(L("Copié", "Copied"), systemImage: "checkmark")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
                Spacer(minLength: 0)
                CardButton(title: L("Ouvrir", "Open")) { MeetingWidgetController.shared.openMeetings() }
                CardButton(title: L("Coller", "Paste")) { MeetingWidgetController.shared.paste() }
            }
        }
        .foregroundStyle(.white)
        .padding(14)
        .frame(width: MeetingWidgetModel.endedSize.width, height: MeetingWidgetModel.endedSize.height)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.black.opacity(0.88)))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
        .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
        .environment(\.colorScheme, .dark)
        .onHover { if $0 { MeetingWidgetController.shared.keepEndedOpen() } }
    }
}

private struct CardButton: View {
    let title: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 12).padding(.vertical, 5)
                .background(Capsule().fill(Color.white.opacity(0.16)))
        }
        .buttonStyle(.plain)
    }
}

private struct MessageCapsule: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.white)
            .lineLimit(1)
            .padding(.horizontal, 16)
            .frame(width: MeetingWidgetModel.messageSize.width, height: MeetingWidgetModel.messageSize.height)
            .modifier(DarkCapsule())
    }
}

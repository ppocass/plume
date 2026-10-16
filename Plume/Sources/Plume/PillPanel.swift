import AppKit
import SwiftUI

/// La pastille flottante en bas de l'écran.
///
/// Invisible au repos : elle n'existe à l'écran que pendant une dictée et
/// juste après (le temps de dire « collé », ou le pop-up « rien à coller »).
/// Panneau **non activant** : cliquer dessus ne vole pas le focus de l'app où
/// l'on écrit (sauf pour ouvrir la fenêtre, ce qui est voulu).
///
/// Elle **s'ouvre plus large** quand il n'y avait pas de
/// champ où écrire : elle montre alors le début du texte, et **un clic dessus
/// le copie** dans le presse-papiers (voir `PillView`).
final class PillPanel: NSPanel {
    static let shared = PillPanel()

    /// Taille de la pastille ordinaire (barrres, ✓, messages).
    static let pillSize = NSSize(width: 320, height: 64)
    /// Taille du pop-up « rien à coller » — assez large pour lire l'aperçu.
    static let previewSize = NSSize(width: 430, height: 96)

    private let hosting: NSHostingView<AnyView>

    private init() {
        hosting = NSHostingView(rootView: AnyView(
            PillView()
                .environmentObject(DictationController.shared)
                .environmentObject(DictationController.shared.meter)
        ))
        super.init(contentRect: NSRect(origin: .zero, size: Self.pillSize),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isMovable = false
        animationBehavior = .none
        hosting.frame = contentRect(forFrameRect: frame)
        hosting.autoresizingMask = [.width, .height]
        contentView = hosting
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// En bas, au centre de l'écran où se trouve la souris (au-dessus du Dock).
    /// Le **bord bas reste fixe** : la pilule grandit vers le haut quand le
    /// pop-up s'ouvre, elle ne saute pas de place.
    private func place(size: NSSize) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let bottom = isVisible ? frame.minY : visible.minY + 14
        setFrame(NSRect(x: visible.midX - size.width / 2, y: bottom, width: size.width, height: size.height),
                 display: false)
    }

    func present() {
        // La fenêtre prend la taille de ce que montre la pastille à cet instant.
        let target = DictationController.shared.phase.showsPreview ? Self.previewSize : Self.pillSize
        if frame.size != target { place(size: target) }
        if !isVisible {
            place(size: target)
            alphaValue = 1
            orderFrontRegardless()
        }
    }

    func dismiss() {
        // La vue joue sa propre transition de sortie ; on retire la fenêtre après.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, DictationController.shared.phase == .hidden else { return }
            self.orderOut(nil)
        }
    }
}

// MARK: - La vue

/// Pilule sombre, barres qui suivent la voix : couleur d'écoute, puis couleur
/// de traitement, vert quand c'est collé. Une croix rouge à droite annule.
///
/// **Quand il n'y avait aucun champ où écrire**, la pilule s'agrandit et laisse
/// voir le début du texte (« Cliquer pour copier ») : le clic le met dans le
/// presse-papiers. Le double appui sur la touche la referme.
struct PillView: View {
    @EnvironmentObject var controller: DictationController
    @EnvironmentObject var meter: LevelMeter

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.clear
            if controller.phase != .hidden {
                content
                    .transition(.scale(scale: 0.6, anchor: .bottom).combined(with: .opacity))
                    .padding(.bottom, 6)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.spring(response: 0.32, dampingFraction: 0.78), value: controller.phase)
    }

    @ViewBuilder
    private var content: some View {
        if case .savedToHistory(let text) = controller.phase {
            savedPreview(text)
        } else {
            HStack(spacing: 8) {
                switch controller.phase {
                case .recording:
                    bars(color: .plumeAccent, thinking: false)
                    cancelButton
                case .processing:
                    bars(color: .plumeThinking, thinking: true)
                case .pasted:
                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Color.plumeDone)
                        .frame(width: 30, height: 18)
                case .copied:
                    Label(L("Copié", "Copied"), systemImage: "doc.on.clipboard.fill")
                        .labelStyle(PillLabelStyle(color: .plumeDone))
                case .message(let text, let isError):
                    Label(text, systemImage: isError ? "exclamationmark.triangle.fill" : "waveform.slash")
                        .labelStyle(PillLabelStyle(color: isError ? .orange : .secondary))
                case .savedToHistory, .hidden:
                    EmptyView()
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(pillBackground(capsule: true))
            .contentShape(Capsule())
            .onTapGesture { controller.pillClicked() }
            .help(tapHelp)
        }
    }

    /// Le pop-up « rien à coller » : pas de champ, on montre le texte et on
    /// propose de le copier.
    private func savedPreview(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "tray.and.arrow.down.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.plumeAccent)
                Text(L("Aucun champ · cliquez pour copier", "No text field · click to copy"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.75))
                Spacer(minLength: 0)
                animationCloseButton
            }
            Text(Self.preview(of: text))
                .font(.system(size: 14))
                .foregroundStyle(.white.opacity(0.96))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(pillBackground(capsule: false))
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onTapGesture { controller.pillClicked() }
        .help(L("Copier le texte", "Copy text"))
    }

    /// Les cinq premiers mots + « … » (le texte entier est copié, lui).
    static func preview(of text: String) -> String {
        let words = text.split(whereSeparator: \.isWhitespace)
        guard words.count > 5 else { return text }
        return words.prefix(5).joined(separator: " ") + "…"
    }

    private var animationCloseButton: some View {
        Button {
            controller.cancelFromPill()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 7, weight: .heavy))
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 14, height: 14)
                .background(Circle().fill(Color.white.opacity(0.14)))
        }
        .buttonStyle(.plain)
        .help(L("Fermer", "Close"))
    }

    private var tapHelp: String {
        switch controller.phase {
        case .recording, .processing: return L("Ouvrir Plume", "Open Plume")
        default: return ""
        }
    }

    @ViewBuilder
    private func pillBackground(capsule: Bool) -> some View {
        let shape: AnyShape = capsule
            ? AnyShape(Capsule())
            : AnyShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        shape
            .fill(Color.black.opacity(0.88))
            .overlay(shape.stroke(Color.white.opacity(0.14), lineWidth: 0.75))
            .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
    }

    private var cancelButton: some View {
        Button {
            controller.cancelFromPill()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 8, weight: .heavy))
                .foregroundStyle(.white)
                .frame(width: 16, height: 16)
                .background(Circle().fill(Color.red.opacity(0.85)))
        }
        .buttonStyle(.plain)
        .help(L("Annuler", "Cancel"))
    }

    private func bars(color: Color, thinking: Bool) -> some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 2.5) {
                ForEach(0..<LevelMeter.barCount, id: \.self) { i in
                    Capsule()
                        .fill(color)
                        .frame(width: 3, height: height(i, t: t, thinking: thinking))
                }
            }
            .frame(height: 18)
        }
        .shadow(color: color.opacity(0.5), radius: 4)
    }

    /// Écoute : chaque barre = un instant récent du micro (la plus à droite est
    /// la plus récente), avec un léger frémissement pour que le silence vive.
    /// Traitement : une vague qui traverse les barres.
    private func height(_ i: Int, t: TimeInterval, thinking: Bool) -> CGFloat {
        if thinking {
            let wave = sin(t * 6 - Double(i) * 0.55)
            return 4 + 10 * CGFloat((wave + 1) / 2)
        }
        let level = CGFloat(meter.levels[i])
        let shimmer = 0.5 + 0.5 * sin(t * 7 + Double(i) * 1.3)
        return max(3, 3 + 15 * pow(level, 0.8) + CGFloat(shimmer) * 1.5)
    }
}

private struct PillLabelStyle: LabelStyle {
    let color: Color
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon.foregroundStyle(color)
            configuration.title.foregroundStyle(.white.opacity(0.92))
        }
        .font(.system(size: 12, weight: .medium))
        .fixedSize()
    }
}

import AppKit
import SwiftUI

/// La pastille flottante.
///
/// Invisible au repos : elle n'existe à l'écran que pendant une dictée et
/// juste après (le temps de dire « collé », ou le pop-up « rien à coller »).
/// Panneau **non activant** : cliquer dessus ne vole pas le focus de l'app où
/// l'on écrit (sauf pour ouvrir la fenêtre, ce qui est voulu).
///
/// **Elle ne prend aucune place dans la barre des menus** : c'est une fenêtre
/// sans bordure qui se dessine *par-dessus*, elle ne demande pas d'emplacement.
///
/// Deux emplacements (Réglages → Pastille) :
/// - `bottom` : au-dessus du Dock, l'emplacement historique ;
/// - `notch` : centrée en haut, à la place de l'encoche. **Sans encoche** (les
///   MacBook Air M1), elle descend simplement du bord supérieur et s'arrête à
///   la même hauteur — la distance est calculée pour que ça tombe juste.
///
/// Elle **s'ouvre plus large** quand il n'y avait pas de champ où écrire : elle
/// montre alors le début du texte, et **un clic dessus le copie**.
final class PillPanel: NSPanel {
    static let shared = PillPanel()

    /// Taille de la pastille ordinaire (barrres, ✓, messages).
    static let pillSize = NSSize(width: 320, height: 64)
    /// Taille du pop-up « rien à coller » — assez large pour lire l'aperçu.
    static let previewSize = NSSize(width: 430, height: 96)

    /// Hauteur de l'encoche sur les MacBook qui en ont une (menu bar 37 pt).

    /// Marge sous la barre des menus quand il n'y a pas d'encoche.


    private let hosting: NSHostingView<AnyView>
    /// Vrai le temps de l'animation de descente : la vue ne joue alors pas sa
    /// propre transition d'entrée (sinon les deux se cumulent).
    private(set) var slidingIn = false

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

    private var pillStyle: PillStyle { Prefs.shared.pillStyle }
    private var hasNotch: Bool { NSScreen.main?.auxiliaryTopLeftArea != nil }

    /// L'écran où se trouve la souris (là où Pierre travaille).
    /// (Nommée `workScreen` : `screen` est déjà une propriété de `NSWindow`.)
    private var workScreen: NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
    }

    /// La taille de la fenêtre pour une phase donnée.
    ///
    /// En style « encoche », la **carte est plus étroite** que la pastille
    /// d'origine (300 au lieu de 320) : la maquette qui a plu à Pierre était
    /// compacte, et une carte large ne « sort » pas crédiblement d'une encoche.
    /// Le pop-up garde sa largeur (il doit pouvoir montrer une ligne de texte).
    private func panelSize(for phase: PillPhase) -> NSSize {
        if phase.showsPreview { return Self.previewSize }
        if pillStyle == .notch { return NSSize(width: 300, height: 64) }
        return Self.pillSize
    }

    /// Le cadre cible d'une taille donnée, selon le style.
    ///
    /// - `bottom` : **bord bas fixe** au-dessus du Dock — la pastille grandit
    ///   vers le haut quand le pop-up s'ouvre, elle ne saute pas de place ;
    /// - `top` et `notch` : **bord haut fixe** au bord de l'écran — elles
    ///   grandissent vers le bas, comme un panneau qui descend du haut.
    ///
    /// Les deux styles du haut remontent **jusqu'au bord supérieur** : c'est la
    /// vue qui réserve ensuite l'espace voulu (`padding`), ce qui permet à la
    /// carte « encoche » de coller au bord et à la pastille « en haut » de
    /// garder son arrondi complet sous la barre des menus.
    private func targetFrame(size: NSSize) -> NSRect {
        guard let workScreen else { return NSRect(origin: .zero, size: size) }
        let visible = workScreen.visibleFrame
        let x = visible.midX - size.width / 2

        switch pillStyle {
        case .bottom:
            let bottom = isVisible && frame.size.height > 0
                ? frame.minY
                : visible.minY + 14
            return NSRect(x: x, y: bottom, width: size.width, height: size.height)
        case .top, .notch:
            let maxTop = isVisible && frame.size.height > 0 ? frame.maxY : workScreen.frame.maxY
            return NSRect(x: x, y: maxTop - size.height, width: size.width, height: size.height)
        }
    }

    /// Le style a changé dans les Réglages : on replace sans animation.
    ///
    /// Pendant une dictée, le panneau est visible : on le remet en place tout
    /// de suite, sinon il resterait à l'ancien emplacement jusqu'au prochain
    /// affichage et Pierre croirait que le réglage n'a rien fait.
    func styleChanged() {
        guard isVisible else { return }
        let target = panelSize(for: DictationController.shared.phase)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.28
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            animator().setFrame(targetFrame(size: target), display: true)
        }
    }

    func present() {
        // La fenêtre prend la taille de ce que montre la pastille à cet instant.
        let target = panelSize(for: DictationController.shared.phase)
        let goal = targetFrame(size: target)

        if !isVisible {
            if pillStyle.hangsFromTop {
                slideIn(to: goal)
            } else {
                setFrame(goal, display: false)
                alphaValue = 1
                orderFrontRegardless()
            }
            return
        }
        if frame != goal {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.22
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                animator().setFrame(goal, display: true)
            }
        }
    }

    /// L'entrée du style « encoche » : la pastille **descend du bord supérieur**
    /// et se pose à sa place, avec un ressort. Elle part de 40 pt plus haut et
    /// glisse en 0,42 s : assez pour qu'on voie d'où elle vient, assez court
    /// pour ne pas faire attendre pendant une dictée.
    private func slideIn(to goal: NSRect) {
        var start = goal
        start.origin.y = goal.maxY - 8          // presque entièrement hors écran
        setFrame(start, display: false)
        alphaValue = 0
        slidingIn = true
        orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.42
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.18, 1.28, 0.42, 1.0)
            animator().setFrame(goal, display: true)
            animator().alphaValue = 1
        } completionHandler: { [weak self] in
            self?.slidingIn = false
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

    /// Le style « encoche » fait descendre la fenêtre elle-même : la vue n'a
    /// alors qu'un fondu à jouer, sinon les deux animations se cumulent et la
    /// pastille paraît bégayer à l'entrée.
    private var style: PillStyle { Prefs.shared.pillStyle }
    private var hangsFromTop: Bool { style.hangsFromTop }

    /// L'espace entre le bord supérieur de l'écran et le haut de la pastille.
    ///
    /// - style « en haut » : la barre des menus (37 pt) + 6 pt, pour que la
    ///   pastille flotte juste dessous, entièrement arrondie ;
    /// - style « encoche » : 0 — la carte **colle** au bord supérieur et c'est
    ///   son raccord plat qui la rattache à l'encoche.
    private var topInset: CGFloat { style == .notch ? 0 : 43 }

    var body: some View {
        ZStack(alignment: hangsFromTop ? .top : .bottom) {
            Color.clear
            if controller.phase != .hidden {
                Group {
                    if style == .notch {
                        // Une seule forme : coiffe + carte, dessinées ensemble.
                        content
                            .frame(maxWidth: .infinity)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(NotchCardBackground())
                    } else {
                        content
                    }
                }
                .frame(width: style == .notch ? 300 : nil)
                .transition(hangsFromTop
                    ? .opacity
                    : .scale(scale: 0.6, anchor: .bottom).combined(with: .opacity))
                .padding(hangsFromTop ? .top : .bottom, hangsFromTop ? topInset : 6)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.spring(response: 0.32, dampingFraction: 0.78), value: controller.phase)
    }

    /// Le fond « encoche » : la silhouette de `NotchCardShape` en noir, avec le
    /// même filet et la même ombre que le reste de l'app.
    private struct NotchCardBackground: View {
        var body: some View {
            NotchCardShape()
                .fill(Color(white: 0.055))
                // Filet **sur les côtés et le bas seulement** : un contour
                // complet dessinerait une ligne blanche en travers de la barre
                // des menus, alors que le haut de la carte est hors écran.
                .overlay(
                    NotchCardShape()
                        .stroke(Color.white.opacity(0.13), lineWidth: 0.75)
                        .mask(
                            Rectangle()
                                .padding(.top, 2)   // laisse la ligne du haut dehors
                        )
                )
                .shadow(color: .black.opacity(0.50), radius: 22, y: 12)
        }
    }

    /// Ce que montre la pastille, selon l'instant de la dictée.
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
            // ⚠️ L'ordre compte : `.frame` **avant** `.background`, sinon le
            // fond reste à la taille du texte et la carte sort plus étroite
            // que sa coiffe.
            .frame(maxWidth: style == .notch ? .infinity : nil)
            .padding(.horizontal, style == .notch ? 22 : 12)
            .padding(.vertical, 8)
            // En encoche, le fond est déjà dessiné par `NotchCardBackground`
            // (une seule silhouette) : en remettre un ici produirait un contour
            // intérieur visible, comme une boîte dans la boîte.
            .background(style == .notch ? nil : pillBackground(capsule: true))
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
                    .foregroundStyle(pillText.opacity(0.62))
                Spacer(minLength: 0)
                animationCloseButton
            }
            Text(Self.preview(of: text))
                .font(.system(size: 14))
                .foregroundStyle(pillText)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: style == .notch ? .infinity : nil, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        // Voir `content` : en encoche, la silhouette est déjà dessinée par le parent.
        .background(style == .notch ? nil : pillBackground(capsule: false))
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
                .foregroundStyle(pillText.opacity(0.55))
                .frame(width: 14, height: 14)
                .background(Circle().fill(pillText.opacity(0.10)))
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

    /// Le fond, selon le style.
    ///
    /// - **en bas / en haut** : du **verre dépoli macOS**. C'était le vrai défaut
    ///   de l'ancienne pastille : `Color.black.opacity(0.88)` posait une tache
    ///   opaque au-dessus d'une interface entièrement translucide. Ici le fond du
    ///   bureau transparaît (flouté, éclairci), comme dans le reste du système.
    /// - **encoche** : une carte **sombre** qui prolonge l'encoche (elle est noire,
    ///   une carte claire se découperait dessus), avec le même verre par-dessus
    ///   pour ne pas redevenir l'aplat de départ.
    ///
    /// Le texte suit : sombre sur le verre clair, clair sur la carte d'encoche.
    @ViewBuilder
    private func pillBackground(capsule: Bool) -> some View {
        let shape: AnyShape = pillShape(capsule: capsule)
        if style == .notch {
            // Pas d'arrondi en haut : le raccord avec l'encoche est plat.
            //
            // 🔴 **Pas de `.ultraThinMaterial` ici.** Testé le 03/11 : posé
            // par-dessus un fond clair, le matériau rend **gris moyen** et la
            // carte perd tout son effet d'encoche — elle ressemble à un bout
            // de plastique. L'encoche du Mac est **noire** : on l'assume.
            // Un noir très légèrement translucide garde un peu du fond, sans
            // jamais virer au gris.
            shape
                .fill(Color(white: 0.055).opacity(0.97))
                .overlay(shape.stroke(Color.white.opacity(0.13), lineWidth: 0.75))
                .shadow(color: .black.opacity(0.50), radius: 20, y: 9)
        } else {
            shape
                .fill(.ultraThinMaterial)
                .overlay(shape.fill(Color.white.opacity(0.30)))
                .overlay(shape.stroke(Color.white.opacity(0.55), lineWidth: 0.75))
                .overlay(shape.stroke(Color.black.opacity(0.10), lineWidth: 0.5).padding(0.5))
                .shadow(color: .black.opacity(0.22), radius: 14, y: 5)
                .shadow(color: .black.opacity(0.10), radius: 2, y: 1)
        }
    }

    /// La forme : capsule pour la pastille, rectangle arrondi pour le pop-up.
    /// En style « encoche », les coins du haut sont **droits** pour que la carte
    /// se fonde dans le bord de l'écran.
    private func pillShape(capsule: Bool) -> AnyShape {
        if style == .notch {
            // ⚠️ **Pas une capsule.** Une capsule a des **demi-cercles** aux
            // bouts (rayon = moitié de la hauteur) : ça ne ressemble à rien de
            // macOS. L'encoche d'un MacBook a des coins de **12-14 pt** tout au
            // plus, et son bas arrondi suit la même famille. On prend donc un
            // arrondi continu de 14 pt en bas, et **0 en haut** pour que la
            // carte se fonde dans le bord de l'écran.
            return AnyShape(UnevenRoundedRectangle(
                topLeadingRadius: 0, bottomLeadingRadius: 14,
                bottomTrailingRadius: 14, topTrailingRadius: 0, style: .continuous))
        }
        return capsule
            ? AnyShape(Capsule())
            : AnyShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    /// La couleur du texte de la pastille : sombre sur le verre clair, clair
    /// sur la carte sombre du style « encoche ».
    private var pillText: Color { style == .notch ? .white : .primary }

    private var cancelButton: some View {
        Button {
            controller.cancelFromPill()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 7, weight: .bold))
                .foregroundStyle(pillText.opacity(0.62))
                .frame(width: 15, height: 15)
                .background(Circle().fill(pillText.opacity(0.10)))
        }
        .buttonStyle(.plain)
        .help(L("Annuler", "Cancel"))
    }

    private func bars(color: Color, thinking: Bool) -> some View {
        // En style « encoche », la carte est large : des barres de 3 pt collées
        // au milieu donnent l'impression d'un petit objet perdu dans un grand
        // vide (remarque de Pierre). On les **étire** pour qu'elles occupent la
        // largeur, comme un vrai niveau audio.
        let wide = style == .notch
        let barWidth: CGFloat = wide ? 7 : 3
        let spacing: CGFloat = wide ? 9 : 2.5
        let maxHeight: CGFloat = wide ? 28 : 18
        return TimelineView(.animation(minimumInterval: 1.0 / 30)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: spacing) {
                ForEach(0..<LevelMeter.barCount, id: \.self) { i in
                    Capsule()
                        .fill(color)
                        .frame(width: barWidth, height: height(i, t: t, thinking: thinking))
                }
            }
            .frame(height: maxHeight)
        }
        .frame(maxWidth: wide ? .infinity : nil)
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
        // 🐛 Avant le correctif : sans micro ouvert (rendu hors écran, ou juste
        // après le démarrage), toutes les barres tombaient à `max(3, …)` et la
        // pastille montrait **treize points alignés** — laid, et Pierre l'aurait
        // pris pour un bug d'affichage. Le frémissement seul donne maintenant une
        // vague lisible qui respire, comme sur une vraie écoute au calme.
        return max(3, 3 + 15 * pow(level, 0.8) + CGFloat(shimmer) * 4)
    }
}

private struct PillLabelStyle: LabelStyle {
    let color: Color
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon.foregroundStyle(color)
            configuration.title.foregroundStyle(.primary.opacity(0.88))
        }
        .font(.system(size: 12, weight: .medium))
        .fixedSize()
    }
}

/// La silhouette complète du style « encoche » : **une seule forme**, la coiffe
/// étroite en haut et la carte large en bas.
///
/// Pourquoi une seule forme et pas deux rectangles empilés : empilés, le filet
/// clair du haut de la carte dessinait une **couture** visible entre les deux,
/// et l'ensemble ne ressemblait plus à une encoche mais à deux blocs collés.
/// Ici il n'y a qu'un contour, donc rien à raccorder.
struct NotchCardShape: Shape {
    /// Arrondi du bas de la carte — un arrondi macOS, pas un demi-cercle.
    var corner: CGFloat = 14

    /// **Une seule silhouette, pleine largeur.**
    ///
    /// Version du 04/11 : Pierre a signalé, capture à l'appui, que le
    /// **décrochement** laissait deux « épaules » visibles dans la barre des
    /// menus, et que « ça fait bizarre ». La coiffe n'est donc plus plus étroite
    /// que la carte : le noir est **continu jusqu'au bord supérieur**, sur toute
    /// la largeur, avec seulement les deux coins du bas arrondis. Ça lit comme
    /// un panneau qui descend de la barre — plus de marche, plus de vide.
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - corner))
        p.addQuadCurve(to: CGPoint(x: rect.maxX - corner, y: rect.maxY),
                       control: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX + corner, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - corner),
                       control: CGPoint(x: rect.minX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}

import AppKit
import SwiftUI

/// Vérification visuelle sans capture d'écran : `Plume --snapshot DOSSIER`
/// dessine les pages de l'assistant hors écran (seulement les vues de Plume) en PNG,
/// en français/anglais et clair/sombre. Ne touche à aucun réglage enregistré.
/// (La fenêtre principale n'y figure pas : ses zones qui défilent sortent
/// noires dans un rendu hors écran.)
@MainActor
enum Snapshot {
    static func run(into dir: String) {
        let out = URL(fileURLWithPath: dir)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        // L'icône de la barre des menus, agrandie (8×), noire sur blanc.
        let big = NSImage(size: NSSize(width: 144, height: 144))
        big.lockFocus()
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: 144, height: 144).fill()
        StatusItemController.icon.draw(in: NSRect(x: 0, y: 0, width: 144, height: 144))
        big.unlockFocus()
        if let tiff = big.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
            try? rep.representation(using: .png, properties: [:])?.write(to: out.appendingPathComponent("barre-des-menus.png"))
        }
        let d = UserDefaults.standard
        // Les réglages que les pages pourraient toucher sont remis tels quels.
        let keys = ["appLanguage", "appAppearance", "polishService"]
        let saved = keys.map { d.object(forKey: $0) }
        defer { for (k, v) in zip(keys, saved) { d.set(v, forKey: k) } }
        pills(into: out)
        for lang in AppLanguage.allCases {
            d.set(lang.rawValue, forKey: "appLanguage")
            for dark in [false, true] {
                let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
                let suffix = "\(lang.rawValue)-\(dark ? "sombre" : "clair")"
                let model = OnboardingModel()
                for (i, step) in OnboardingStep.all.enumerated() {
                    model.step = i
                    let view = OnboardingView(finish: {})
                        .environmentObject(model).environmentObject(Prefs.shared)
                        .environmentObject(Permissions.shared).environmentObject(EngineStatus.shared)
                        .environmentObject(ModelStore.shared)
                        .tint(.plumeTheme)
                    render(view, size: NSSize(width: 560, height: 540), appearance: appearance,
                           to: out.appendingPathComponent("assistant-\(i + 1)-\(step)-\(suffix).png"))
                }
            }
        }
    }

    /// Les trois styles de pastille, rendus hors écran — vérification visuelle
    /// sans toucher au vrai panneau ni aux réglages.
    ///
    /// On dessine directement `PillView`, dans les tailles réelles du panneau,
    /// en clair et en sombre. C'est ce que Pierre voit à l'écran.
    static func pills(into out: URL) {
        let d = UserDefaults.standard
        let saved = d.string(forKey: "pillStyle")
        defer { d.set(saved, forKey: "pillStyle") }

        // La vue lit son état dans `DictationController.phase` : on lui donne
        // un aperçu figé en dessinant les deux formes de la pastille.
        for style in PillStyle.allCases {
            for dark in [false, true] {
                d.set(style.rawValue, forKey: "pillStyle")
                let suffix = "\(style.rawValue)-\(dark ? "sombre" : "clair")"
                let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
                let view = PillSnapshotFrame(style: style)
                    .environmentObject(DictationController.shared)
                    .environmentObject(DictationController.shared.meter)
                render(view, size: NSSize(width: 460, height: 150), appearance: appearance,
                       to: out.appendingPathComponent("pastille-\(suffix).png"))
            }
        }
    }

    private static func render<V: View>(_ view: V, size: NSSize, appearance: NSAppearance, to url: URL) {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        window.appearance = appearance
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: size)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        host.layoutSubtreeIfNeeded()
        // Fenêtre vraiment affichée, mais hors de l'écran visible : les zones
        // qui défilent (Form, ScrollView) ne se dessinent qu'ainsi.
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.orderFrontRegardless()
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        window.orderOut(nil)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}

/// Une image figée de la pastille, pour la vérification visuelle.
///
/// On ne passe par `PillView` (dont l'état vit dans `DictationController` et
/// changerait le vrai panneau) : on redessine **exactement** les mêmes formes et
/// couleurs, avec les réglages lus comme dans l'app.
struct PillSnapshotFrame: View {
    let style: PillStyle

    private var pillText: Color { style == .notch ? .white : .primary }

    private func shape(capsule: Bool) -> AnyShape {
        if style == .notch {
            let bottom: CGFloat = capsule ? 32 : 16
            return AnyShape(UnevenRoundedRectangle(
                topLeadingRadius: 0, bottomLeadingRadius: bottom,
                bottomTrailingRadius: bottom, topTrailingRadius: 0, style: .continuous))
        }
        return capsule
            ? AnyShape(Capsule())
            : AnyShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    @ViewBuilder
    private func background(capsule: Bool) -> some View {
        let s = shape(capsule: capsule)
        if style == .notch {
            s.fill(.ultraThinMaterial)
                .overlay(s.fill(Color.black.opacity(0.72)))
                .overlay(s.stroke(Color.white.opacity(0.16), lineWidth: 0.75))
                .shadow(color: .black.opacity(0.45), radius: 18, y: 8)
        } else {
            s.fill(.ultraThinMaterial)
                .overlay(s.fill(Color.white.opacity(0.30)))
                .overlay(s.stroke(Color.white.opacity(0.55), lineWidth: 0.75))
                .shadow(color: .black.opacity(0.22), radius: 14, y: 5)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if style.hangsFromTop {
                Spacer().frame(height: style == .notch ? 4 : 47)
            }
            HStack(spacing: 8) {
                HStack(alignment: .center, spacing: 2.5) {
                    ForEach(0..<13, id: \.self) { i in
                        Capsule().fill(Color.plumeAccent)
                            .frame(width: 3, height: [6, 14, 20, 10, 17, 23, 9, 15, 21, 12, 7, 16, 19][i])
                    }
                }
                .frame(height: 18)
                .shadow(color: Color.plumeAccent.opacity(0.5), radius: 4)
                Button {} label: {
                    Image(systemName: "xmark").font(.system(size: 7, weight: .bold))
                        .foregroundStyle(pillText.opacity(0.62))
                        .frame(width: 15, height: 15)
                        .background(Circle().fill(pillText.opacity(0.10)))
                }.buttonStyle(.plain)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(background(capsule: true))

            Spacer().frame(height: 10)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "tray.and.arrow.down.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.plumeAccent)
                    Text(L("Aucun champ · cliquez pour copier", "No text field · click to copy"))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(pillText.opacity(0.62))
                    Spacer(minLength: 0)
                    Image(systemName: "xmark").font(.system(size: 7, weight: .heavy))
                        .foregroundStyle(pillText.opacity(0.55)).frame(width: 14, height: 14)
                        .background(Circle().fill(pillText.opacity(0.10)))
                }
                Text(L("Je voulais te dire que la réunion de demain…",
                       "I wanted to tell you that tomorrow's meeting…"))
                    .font(.system(size: 14)).foregroundStyle(pillText)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(background(capsule: false))

            if !style.hangsFromTop { Spacer(minLength: 0) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(white: 0.45))
    }
}

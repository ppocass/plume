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

import AppKit

/// L'icône facultative de la barre des menus (Réglages → Général, désactivée
/// par défaut) : démarrer ou terminer une dictée, copier la dernière, ouvrir
/// l'historique ou les réglages, quitter.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    static let shared = StatusItemController()
    private var item: NSStatusItem?

    /// Montre ou retire l'icône selon le réglage.
    func update() {
        if Prefs.shared.showInMenuBar {
            guard item == nil else { return }
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            item.button?.image = Self.icon
            item.button?.setAccessibilityLabel("Plume")
            let menu = NSMenu()
            menu.delegate = self
            menu.autoenablesItems = false
            item.menu = menu
            self.item = item
        } else if let item {
            NSStatusBar.system.removeStatusItem(item)
            self.item = nil
        }
    }

    /// Le menu est refait à chaque ouverture : il suit la dictée en cours, la
    /// langue et le raccourci.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let dictation = DictationController.shared
        let shortcut = Prefs.shared.shortcut.label

        let toggle: NSMenuItem
        if dictation.isBusy {
            toggle = NSMenuItem(title: L("Traitement…", "Processing…"), action: nil, keyEquivalent: "")
            toggle.isEnabled = false
        } else if dictation.isRecordingNow {
            toggle = NSMenuItem(title: L("Terminer la dictée", "Stop Dictation"), action: #selector(toggleDictation), keyEquivalent: "")
        } else {
            toggle = NSMenuItem(title: L("Démarrer la dictée", "Start Dictation") + "  (\(shortcut))",
                                action: #selector(toggleDictation), keyEquivalent: "")
        }
        toggle.target = self
        menu.addItem(toggle)

        let copy = NSMenuItem(title: L("Copier la dernière dictée", "Copy Last Dictation"), action: #selector(copyLatest), keyEquivalent: "")
        copy.target = self
        copy.isEnabled = HistoryStore.shared.latest != nil
        menu.addItem(copy)

        menu.addItem(.separator())
        for (title, selector) in [(L("Historique…", "History…"), #selector(openHistory)),
                                  (L("Réglages…", "Settings…"), #selector(openSettings))] {
            let entry = NSMenuItem(title: title, action: selector, keyEquivalent: "")
            entry.target = self
            menu.addItem(entry)
        }
        menu.addItem(.separator())
        let quit = NSMenuItem(title: L("Quitter Plume", "Quit Plume"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        menu.addItem(quit)
    }

    @objc private func toggleDictation() { DictationController.shared.toggleFromMenu() }
    @objc private func copyLatest() { DictationController.shared.copyLatest() }
    @objc private func openHistory() { MainWindowController.shared.show(section: .history) }
    @objc private func openSettings() { MainWindowController.shared.show(section: .settings) }

    /// La plume du logo, dessinée en image « modèle » (macOS la teinte selon la
    /// barre des menus, claire ou sombre). Mêmes tracés que `Tools/icone-plume/plume.svg`.
    static let icon: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { rect in
            let s: CGFloat = 0.0215
            let t = NSAffineTransform()
            t.translateX(by: rect.midX, yBy: rect.midY)
            t.rotate(byDegrees: 36)
            t.scale(by: s)
            t.translateX(by: -519, yBy: -510)
            t.concat()

            func curve(_ p: NSBezierPath, _ c: [CGFloat]) {
                p.curve(to: NSPoint(x: c[4], y: c[5]), controlPoint1: NSPoint(x: c[0], y: c[1]), controlPoint2: NSPoint(x: c[2], y: c[3]))
            }
            let left = NSBezierPath()
            left.move(to: NSPoint(x: 540, y: 120))
            curve(left, [470, 190, 432, 280, 425, 380])
            left.line(to: NSPoint(x: 470, y: 384))
            left.line(to: NSPoint(x: 423, y: 414))
            curve(left, [420, 470, 426, 520, 440, 562])
            left.line(to: NSPoint(x: 486, y: 556))
            left.line(to: NSPoint(x: 448, y: 590))
            curve(left, [462, 630, 482, 668, 512, 700])
            curve(left, [520, 520, 530, 320, 540, 120])
            left.close()
            let right = NSBezierPath()
            right.move(to: NSPoint(x: 540, y: 120))
            curve(right, [585, 200, 612, 300, 615, 410])
            right.line(to: NSPoint(x: 572, y: 430))
            right.line(to: NSPoint(x: 614, y: 446))
            curve(right, [612, 540, 588, 620, 512, 700])
            curve(right, [520, 520, 530, 320, 540, 120])
            right.close()

            NSColor.black.setFill()
            left.fill()
            right.fill()
            // Le rachis : creusé dans les barbes, plein pour le tuyau.
            let rachis = NSBezierPath()
            rachis.move(to: NSPoint(x: 538, y: 170))
            curve(rachis, [528, 400, 518, 640, 500, 900])
            rachis.lineCapStyle = .round
            rachis.lineWidth = 0.85 / s
            NSGraphicsContext.current?.compositingOperation = .destinationOut
            NSBezierPath(rect: NSRect(x: 0, y: 0, width: 1024, height: 700)).addClip()
            rachis.stroke()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            NSGraphicsContext.current?.saveGraphicsState()
            NSBezierPath(rect: NSRect(x: 0, y: 690, width: 1024, height: 400)).setClip()
            NSColor.black.setStroke()
            rachis.lineWidth = 1.5 / s
            rachis.stroke()
            NSGraphicsContext.current?.restoreGraphicsState()
            return true
        }
        image.isTemplate = true
        return image
    }()
}

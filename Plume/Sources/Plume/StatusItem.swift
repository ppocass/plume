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
        toggle.image = NSImage(systemSymbolName: dictation.isRecordingNow ? "stop.circle" : "mic", accessibilityDescription: nil)
        menu.addItem(toggle)

        let copy = NSMenuItem(title: L("Copier la dernière dictée", "Copy Last Dictation"), action: #selector(copyLatest), keyEquivalent: "")
        copy.target = self
        copy.isEnabled = HistoryStore.shared.latest != nil
        copy.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)
        menu.addItem(copy)

        menu.addItem(.separator())
        // Chaque entrée a son icône : macOS en met d'office à certaines (Réglages,
        // Quitter), et les autres paraîtraient décalées.
        for (title, selector, symbol) in [(L("Historique…", "History…"), #selector(openHistory), "clock.arrow.circlepath"),
                                          (L("Réglages…", "Settings…"), #selector(openSettings), "gearshape")] {
            let entry = NSMenuItem(title: title, action: selector, keyEquivalent: "")
            entry.target = self
            entry.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            menu.addItem(entry)
        }
        menu.addItem(.separator())
        let quit = NSMenuItem(title: L("Quitter Plume", "Quit Plume"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        quit.image = NSImage(systemSymbolName: "xmark.rectangle", accessibilityDescription: nil)
        menu.addItem(quit)
    }

    @objc private func toggleDictation() { DictationController.shared.toggleFromMenu() }
    @objc private func copyLatest() { DictationController.shared.copyLatest() }
    @objc private func openHistory() { MainWindowController.shared.show(section: .history) }
    @objc private func openSettings() { MainWindowController.shared.show(section: .settings) }

    /// Une plume au trait (style des symboles de macOS), en image « modèle » :
    /// macOS la teinte selon la barre des menus. Tracé de
    /// `Tools/icone-barre-menus/B.svg` (18 × 18).
    static let icon: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            NSColor.black.setStroke()
            let vane = NSBezierPath()
            vane.move(to: NSPoint(x: 15.4, y: 2.4))
            vane.curve(to: NSPoint(x: 5.1, y: 12.2), controlPoint1: NSPoint(x: 10.2, y: 2.6), controlPoint2: NSPoint(x: 5.8, y: 6.4))
            vane.line(to: NSPoint(x: 5.9, y: 13))
            vane.curve(to: NSPoint(x: 15.4, y: 2.4), controlPoint1: NSPoint(x: 11.3, y: 12.4), controlPoint2: NSPoint(x: 15.2, y: 8.2))
            vane.close()
            vane.lineWidth = 1.3
            vane.lineJoinStyle = .round
            vane.stroke()
            let shaft = NSBezierPath()
            shaft.move(to: NSPoint(x: 13.6, y: 4.2))
            shaft.line(to: NSPoint(x: 2.6, y: 15.4))
            shaft.lineWidth = 1.3
            shaft.lineCapStyle = .round
            shaft.stroke()
            return true
        }
        image.isTemplate = true
        return image
    }()
}

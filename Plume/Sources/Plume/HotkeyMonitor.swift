import AppKit
import CoreGraphics

/// Écoute la touche de dictée dans TOUT le système. Tap **actif**
/// (`.defaultTap`) qui renvoie chaque événement tel quel : rien n'est bloqué
/// ni modifié.
///
/// ⚠️ Pas `.listenOnly` : un tap en écoute seule
/// exige l'autorisation « Surveillance de l'entrée » ; sans elle, macOS ne lui
/// passe QUE les touches tapées dans Plume — Option ne marchait que Plume au
/// premier plan. Un tap actif ne demande que l'Accessibilité, déjà nécessaire
/// pour coller.
///
/// **Touche modificatrice** (Option gauche…) : un « appui » ne compte que si
/// la touche est enfoncée puis relâchée **seule** :
/// aucune autre touche, aucun clic, aucun autre modificateur entre les deux, et
/// en moins de 0,8 s. Option sert à taper `{ | …` et aux raccourcis : ⌥+lettre
/// ou ⌥-clic ne déclenchent donc jamais la dictée.
///
/// **Combinaison** (⌃⇧W…) : chaque frappe exacte (sans répétition automatique)
/// compte, et elle est **avalée** — elle n'arrive pas à l'app au premier plan.
///
/// Le tap exige l'autorisation **Accessibilité**. Sans elle, `start()` échoue
/// et l'app réessaie toutes les 2 s (dès que la case est cochée, ça marche,
/// sans relancer).
final class HotkeyMonitor {
    var shortcut: Shortcut = .default
    /// Pendant l'enregistrement d'un nouveau raccourci dans les réglages.
    var paused = false
    /// Appelé sur le fil principal à chaque appui valide.
    var onTap: (() -> Void)?

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var downAt: TimeInterval?
    private var dirty = false

    static let maxTapDuration: TimeInterval = 0.8

    var isRunning: Bool { tap != nil }

    @discardableResult
    func start() -> Bool {
        if tap != nil { return true }
        let types: [CGEventType] = [.flagsChanged, .keyDown, .keyUp, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        let me = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                          options: .defaultTap, eventsOfInterest: mask,
                                          callback: { _, type, event, info in
                                              if let info,
                                                 Unmanaged<HotkeyMonitor>.fromOpaque(info).takeUnretainedValue().handle(type, event) {
                                                  return nil   // combinaison de Plume : avalée
                                              }
                                              return Unmanaged.passUnretained(event)
                                          }, userInfo: me) else {
            return false
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.source = source
        Log.info("écoute du raccourci \(shortcut.display) active")
        return true
    }

    func stop() {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        tap = nil
        source = nil
    }

    /// Le keyUp de la combinaison avalée doit l'être aussi.
    private var swallowKeyUp: Int64?

    /// Renvoie `true` si l'événement doit être avalé.
    private func handle(_ type: CGEventType, _ event: CGEvent) -> Bool {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // macOS coupe un tap qu'il juge trop lent : on le rallume.
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            downAt = nil
            return false
        default: break
        }
        if paused { downAt = nil; return false }
        let code = event.getIntegerValueField(.keyboardEventKeycode)

        if shortcut.kind == .combo {
            if type == .keyDown, shortcut.matches(keyCode: code, flags: event.flags) {
                swallowKeyUp = code
                if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
                    DispatchQueue.main.async { [weak self] in self?.onTap?() }
                }
                return true
            }
            if type == .keyUp, code == swallowKeyUp {
                swallowKeyUp = nil
                return true
            }
            return false
        }

        switch type {
        case .flagsChanged:
            let flags = event.flags
            if code == shortcut.keyCode {
                if shortcut.isDown(flags) {
                    downAt = ProcessInfo.processInfo.systemUptime
                    dirty = shortcut.otherModifiersHeld(flags)
                } else if let start = downAt {
                    let held = ProcessInfo.processInfo.systemUptime - start
                    downAt = nil
                    if !dirty && held < Self.maxTapDuration {
                        DispatchQueue.main.async { [weak self] in self?.onTap?() }
                    }
                }
            } else if downAt != nil {
                dirty = true
            }
        case .keyUp:
            break
        default:
            // Une touche, un clic ou un défilement pendant l'appui : ce n'était
            // pas un appui « seul ».
            if downAt != nil { dirty = true }
        }
        return false
    }
}

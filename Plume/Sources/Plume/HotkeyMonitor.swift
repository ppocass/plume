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
/// **Couple de modificateurs** (⌘ gauche + ⌥ gauche, le 1337) : écouté à côté
/// du raccourci de dictée, il part quand **l'une des deux touches se relâche**,
/// à condition que rien d'autre ne soit venu s'intercaler. Rien n'est avalé :
/// ⌘⌥+touche et ⌘⌥-clic gardent leur rôle habituel.
///
/// Le tap exige l'autorisation **Accessibilité**. Sans elle, `start()` échoue
/// et l'app réessaie toutes les 2 s (dès que la case est cochée, ça marche,
/// sans relancer).
final class HotkeyMonitor {
    var shortcut: Shortcut = .default
    /// Le raccourci de la dictée 1337 (⌘ gauche + ⌥ gauche tenus ensemble).
    /// `nil` ou désactivé : on n'écoute rien de ce côté.
    var leetShortcut: Shortcut? = nil
    /// Appelé sur le fil principal quand la dictée 1337 est demandée.
    var onLeetTap: (() -> Void)?
    /// Pendant l'enregistrement d'un nouveau raccourci dans les réglages.
    var paused = false
    /// Appelé sur le fil principal à chaque appui valide.
    var onTap: (() -> Void)?

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var downAt: TimeInterval?
    private var dirty = false
    /// Le couple du 1337 est-il tenu en ce moment ? Et était-ce un appui
    /// « propre » (relâché assez vite, sans autre touche) ?
    private var leetHeld = false
    private var leetStart: TimeInterval?
    private var leetDirty = false

    static let maxTapDuration: TimeInterval = 0.8
    /// Le couple tenu ensemble peut rester appuyé plus longtemps qu'une touche
    /// seule (on réfléchit avant de relâcher) : deux secondes, pas huit dixièmes.
    static let maxLeetHoldDuration: TimeInterval = 2

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
            leetHeld = false
            leetStart = nil
            return false
        default: break
        }
        if paused { downAt = nil; leetHeld = false; leetStart = nil; return false }
        let code = event.getIntegerValueField(.keyboardEventKeycode)

        // Le couple ⌘ gauche + ⌥ gauche s'évalue AVANT le raccourci de dictée
        // (ses drapeaux sont à jour), mais ne part qu'APRÈS : un ⌘⌥ qui vient
        // de servir de raccourci 1337 ne doit pas ouvrir en plus une dictée
        // normale. Un vrai raccourci de dictée, lui, prime : on n'envoie pas
        // les deux gestes.
        var fireLeet = false
        if let leet = leetShortcut, leet.kind == .modifierCombo {
            if type == .flagsChanged {
                if leet.bothDown(event.flags) {
                    if !leetHeld {
                        leetHeld = true
                        leetStart = ProcessInfo.processInfo.systemUptime
                        leetDirty = false
                    }
                } else if leetHeld {
                    // Une des deux se relâche : c'est le geste, s'il est propre.
                    let start = leetStart ?? ProcessInfo.processInfo.systemUptime
                    let held = ProcessInfo.processInfo.systemUptime - start
                    leetHeld = false
                    leetStart = nil
                    fireLeet = !leetDirty && held < Self.maxLeetHoldDuration
                }
            } else if leetHeld {
                // Une vraie touche, un clic, un défilement : ce n'était pas
                // « les deux tenues ensemble », c'était ⌘⌥+quelque chose.
                leetDirty = true
            }
        }

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
            // Le 1337 doit quand même partir même quand la combinaison de
            // dictée n'est pas concernée par cet événement.
            if fireLeet { DispatchQueue.main.async { [weak self] in self?.onLeetTap?() } }
            return false
        }

        var fireDictation = false
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
                        fireDictation = true
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

        // Un vrai appui de dictée prime sur le couple : on n'envoie qu'un geste.
        if fireDictation {
            if leetStart != nil { leetHeld = false; leetStart = nil; leetDirty = true }
            DispatchQueue.main.async { [weak self] in self?.onTap?() }
        } else if fireLeet {
            DispatchQueue.main.async { [weak self] in self?.onLeetTap?() }
        }
        return false
    }
}

import AppKit
import AVFoundation
import ApplicationServices
import ServiceManagement

/// Les deux autorisations dont Plume a besoin, et le lancement à l'ouverture
/// de session. Rafraîchi régulièrement tant que la fenêtre est ouverte (pour
/// que la coche passe au vert dès que l'autorisation est donnée dans Réglages Système).
@MainActor
final class Permissions: ObservableObject {
    static let shared = Permissions()

    @Published var microphone: AVAuthorizationStatus = .notDetermined
    @Published var accessibility = false
    @Published var hotkeyActive = false
    @Published var launchAtLogin = false

    var allGood: Bool { microphone == .authorized && accessibility && hotkeyActive }

    func refresh() {
        if Setup.demo {
            microphone = .authorized; accessibility = true; hotkeyActive = true; launchAtLogin = true
            return
        }
        microphone = AVCaptureDevice.authorizationStatus(for: .audio)
        accessibility = AXIsProcessTrusted()
        hotkeyActive = AppDelegate.shared?.hotkey.isRunning ?? false
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func requestMicrophone() {
        if microphone == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { _ in
                Task { @MainActor in self.refresh() }
            }
        } else {
            open("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
        }
    }

    func requestAccessibility() {
        // Ajoute Plume à la liste (décochée) et ouvre le bon panneau.
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            Log.info("ouverture de session : \(error.localizedDescription)")
        }
        refresh()
    }

    private func open(_ url: String) {
        if let u = URL(string: url) { NSWorkspace.shared.open(u) }
    }
}

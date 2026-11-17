import AppKit
import AVFoundation
import CoreAudio
import Foundation

/// **Le son qui sort du Mac** (le côté « Eux » d'une visio), par un *process
/// tap* Core Audio (macOS 14.4 et plus) :
/// `CATapDescription` → `AudioHardwareCreateProcessTap` → un périphérique
/// agrégé **privé** qui contient le tap → un IOProc qui reçoit le son.
///
/// - **Cible** : si une app de visio connue joue du son (Zoom, Teams, Webex,
///   Discord, Slack, WhatsApp, Skype), on n'écoute **qu'elle** (ni musique ni
///   notifications). Sinon, tout le son du Mac **sauf Plume**.
/// - **Autorisation** : la première ouverture déclenche la demande de macOS
///   (« enregistrement de l'audio du système », distincte du micro). Refusée,
///   le tap ne rend que du silence : c'est le vumètre « son du Mac » qui le
///   montre, et l'alerte de piste muette.
/// - **Sortie changée** (casque branché, AirPods) : le périphérique agrégé est
///   reconstruit sur la nouvelle sortie, l'enregistrement continue.
///
/// Le son sort en **16 kHz mono** sur la file du tap ; rien n'est gardé ici.
@available(macOS 14.4, *)
final class SystemAudioTap: @unchecked Sendable {
    /// Morceau converti (16 kHz mono) et son niveau 0…1, sur la file du tap.
    var onSamples: (@Sendable (_ samples: UnsafeBufferPointer<Float>, _ level: Float) -> Void)?

    /// Ce qu'on écoute, pour l'en-tête de la réunion (« Zoom », « Son du Mac »).
    private(set) var sourceName = ""
    /// Les processus écoutés (vide = tout le Mac sauf Plume).
    private(set) var targetPIDs: [pid_t] = []

    enum TapError: LocalizedError {
        case unavailable(String, OSStatus)
        var errorDescription: String? {
            switch self {
            case .unavailable(let step, let status):
                return L("son du Mac indisponible", "system audio unavailable") + " (\(step) \(status))"
            }
        }
    }

    private let queue = DispatchQueue(label: "plume.system-audio", qos: .userInitiated)
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var resampler: MonoResampler?
    private var format: AVAudioFormat?
    private var outputListener: AudioObjectPropertyListenerBlock?
    private var running = false

    /// Les apps de visio qu'on sait cibler (préfixes d'identifiant). FaceTime
    /// n'y est pas : son son passe par un service système, pas par l'app.
    static let meetingApps: [(prefix: String, name: String)] = [
        ("us.zoom.", "Zoom"), ("com.microsoft.teams", "Teams"), ("com.cisco.webex", "Webex"),
        ("Cisco-Systems.Spark", "Webex"), ("com.hnc.Discord", "Discord"), ("com.tinyspeck.slackmacgap", "Slack"),
        ("net.whatsapp.WhatsApp", "WhatsApp"), ("desktop.WhatsApp", "WhatsApp"), ("com.skype.", "Skype"),
    ]

    /// **Autotest seulement** : un processus (par exemple `afplay`) à traiter
    /// comme une app de visio, pour vérifier l'arrêt quand elle se ferme.
    nonisolated(unsafe) static var testMeetingPID: pid_t?

    func start() throws {
        try queue.sync { try build() }
        listenForOutputChanges()
    }

    func stop() {
        if let outputListener {
            var address = Self.address(kAudioHardwarePropertyDefaultOutputDevice)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, outputListener)
            self.outputListener = nil
        }
        queue.sync { tearDown() }
    }

    /// Une des apps ciblées tourne-t-elle encore ? (Toujours vrai pour le tap global.)
    var targetIsAlive: Bool {
        targetPIDs.isEmpty || targetPIDs.contains { kill($0, 0) == 0 }
    }

    // MARK: Construction

    private func build() throws {
        let description: CATapDescription
        let targets = Self.meetingProcesses()
        if let first = targets.first {
            description = CATapDescription(monoMixdownOfProcesses: targets.map(\.object))
            sourceName = first.name
            targetPIDs = targets.map(\.pid)
        } else {
            let me = Self.processObject(for: getpid()).map { [$0] } ?? []
            description = CATapDescription(monoGlobalTapButExcludeProcesses: me)
            sourceName = L("Son du Mac", "Mac audio")
            targetPIDs = []
        }
        description.uuid = UUID()
        description.name = "Plume"
        description.isPrivate = true
        description.muteBehavior = .unmuted

        var tap = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateProcessTap(description, &tap)
        guard status == noErr else { throw TapError.unavailable("tap", status) }
        tapID = tap

        do {
            var asbd = AudioStreamBasicDescription()
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            var address = Self.address(kAudioTapPropertyFormat)
            status = AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &asbd)
            guard status == noErr, let format = AVAudioFormat(streamDescription: &asbd),
                  let resampler = MonoResampler(from: format) else { throw TapError.unavailable("format", status) }
            self.format = format
            self.resampler = resampler

            guard let outputUID = Self.defaultOutputUID() else { throw TapError.unavailable("sortie", -1) }
            let aggregate: [String: Any] = [
                kAudioAggregateDeviceNameKey: "Plume (réunion)",
                kAudioAggregateDeviceUIDKey: "plume.meeting.\(UUID().uuidString)",
                kAudioAggregateDeviceMainSubDeviceKey: outputUID,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
                kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true,
                                                   kAudioSubTapUIDKey: description.uuid.uuidString]],
            ]
            var device = AudioObjectID(kAudioObjectUnknown)
            status = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &device)
            guard status == noErr else { throw TapError.unavailable("agrégat", status) }
            aggregateID = device

            var proc: AudioDeviceIOProcID?
            status = AudioDeviceCreateIOProcIDWithBlock(&proc, device, queue) { [weak self] _, input, _, _, _ in
                self?.receive(input)
            }
            guard status == noErr, let proc else { throw TapError.unavailable("ioproc", status) }
            procID = proc
            status = AudioDeviceStart(device, proc)
            guard status == noErr else { throw TapError.unavailable("start", status) }
            running = true
            Log.info("son du Mac : écoute de « \(sourceName) » (\(Int(format.sampleRate)) Hz, \(format.channelCount) canal/canaux)")
        } catch {
            tearDown()
            throw error
        }
    }

    private func tearDown() {
        if aggregateID != kAudioObjectUnknown, let procID {
            if running { AudioDeviceStop(aggregateID, procID) }
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        procID = nil
        running = false
        if aggregateID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggregateID) }
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        tapID = AudioObjectID(kAudioObjectUnknown)
        resampler = nil
        format = nil
    }

    /// Sortie par défaut changée : on reconstruit sur la nouvelle.
    private func listenForOutputChanges() {
        var address = Self.address(kAudioHardwarePropertyDefaultOutputDevice)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self, self.running else { return }
            self.tearDown()
            do {
                try self.build()
                Log.info("son du Mac : sortie changée, écoute reconstruite")
            } catch {
                Log.info("son du Mac : reconstruction impossible après changement de sortie (\(error.localizedDescription))")
            }
        }
        if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, block) == noErr {
            outputListener = block
        }
    }

    // MARK: File du tap

    private func receive(_ input: UnsafePointer<AudioBufferList>) {
        guard let format, let resampler, let onSamples,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: input, deallocator: nil) else { return }
        resampler.convert(buffer) { chunk in
            onSamples(chunk, MonoResampler.level(of: chunk))
        }
    }

    // MARK: Core Audio

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    static func processObject(for pid: pid_t) -> AudioObjectID? {
        var address = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var pid = pid
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                                UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object)
        return status == noErr && object != kAudioObjectUnknown ? object : nil
    }

    /// Les processus audio des apps de visio connues (le premier donne le nom).
    static func meetingProcesses() -> [(object: AudioObjectID, pid: pid_t, name: String)] {
        var address = address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &objects) == noErr else { return [] }

        var found: [(object: AudioObjectID, pid: pid_t, name: String)] = []
        for object in objects {
            // Seulement si elle joue du son en ce moment : une app de visio ouverte
            // hors appel (WhatsApp au repos) ne doit pas capter l'écoute.
            guard let bundle = stringProperty(object, kAudioProcessPropertyBundleID),
                  let app = meetingApps.first(where: { bundle.hasPrefix($0.prefix) }),
                  uintProperty(object, kAudioProcessPropertyIsRunningOutput) == 1 else { continue }
            var pid: pid_t = 0
            var pidSize = UInt32(MemoryLayout<pid_t>.size)
            var pidAddress = Self.address(kAudioProcessPropertyPID)
            guard AudioObjectGetPropertyData(object, &pidAddress, 0, nil, &pidSize, &pid) == noErr else { continue }
            found.append((object, pid, app.name))
        }
        if let pid = testMeetingPID, let object = processObject(for: pid) { found.append((object, pid, "Test")) }
        return found
    }

    private static func stringProperty(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr,
              let string = value?.takeRetainedValue() else { return nil }
        return string as String
    }

    private static func uintProperty(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var address = address(selector)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr ? value : nil
    }

    private static func defaultOutputUID() -> String? {
        var address = address(kAudioHardwarePropertyDefaultOutputDevice)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
              device != kAudioObjectUnknown else { return nil }
        return stringProperty(device, kAudioDevicePropertyDeviceUID)
    }
}

import Foundation

/// Le chef d'orchestre d'une réunion (en cours d'écriture : interface publique figée).
@MainActor
final class MeetingRecorder: ObservableObject {
    static let shared = MeetingRecorder()

    /// Le mode n'existe que si macOS sait écouter le son des autres apps (14.4+).
    nonisolated static var isSupported: Bool {
        if #available(macOS 14.4, *) { return true }
        return false
    }

    @Published private(set) var isRecording = false
    @Published private(set) var startedAt: Date?
    /// La réunion en cours (son dossier sur le disque).
    @Published private(set) var folder: MeetingFolder?

    func toggle() { isRecording ? stop() : start() }
    func start() {}
    func stop() {}
}

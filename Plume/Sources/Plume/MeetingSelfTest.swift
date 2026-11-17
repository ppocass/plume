import AppKit
import Foundation

/// Autotest du mode Réunion, dans une vraie app (pour que macOS puisse poser
/// la question de l'autorisation) :
/// `Plume --meeting-selftest <secondes> <rapport.json>`.
///
/// Démarre une vraie réunion (micro + son du Mac + widget), relève la mémoire
/// et le processeur toutes les 10 s, l'arrête, attend la fin et écrit un
/// rapport JSON. Le son à capter vient de l'extérieur (un fichier joué par
/// `afplay`, une visio…).
enum MeetingSelfTest {
    @MainActor
    static func run(seconds: Double, report: String) {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        MeetingWidgetController.shared.install()
        // `PLUME_SHOW_WIDGET=1` : le widget apparaît dans les captures (vérification visuelle).
        if ProcessInfo.processInfo.environment["PLUME_SHOW_WIDGET"] == "1" {
            MeetingWidgetController.shared.showInCapturesForTests()
        }
        let recorder = MeetingRecorder.shared
        var samples: [[String: Double]] = []
        let started = Date()
        let cpuStart = cpuSeconds()

        func write(_ extra: [String: Any]) {
            var out: [String: Any] = ["samples": samples, "elapsed": Date().timeIntervalSince(started)]
            out.merge(extra) { $1 }
            if let data = try? JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: URL(fileURLWithPath: report))
            }
        }

        recorder.onFinished = { folder, text, reason in
            let lags = recorder.textLags
            let meta = folder.readMeta()
            write([
                "folder": folder.url.path, "reason": String(describing: reason), "source": meta?.source ?? "",
                "duration": meta?.duration ?? 0, "paragraphs": meta?.paragraphs ?? 0, "words": meta?.words ?? 0,
                "polished": folder.readParagraphs().filter(\.polished).count,
                "lagMean": lags.isEmpty ? 0 : lags.reduce(0, +) / Double(lags.count),
                "lagMax": lags.max() ?? 0, "lagCount": lags.count,
                "lagOver2s": lags.filter { $0 > 2 }.count,
                "cpuSeconds": cpuSeconds() - cpuStart,
                "micBytes": fileSize(folder.micURL), "systemBytes": fileSize(folder.systemURL),
                "markdownBytes": fileSize(folder.markdownURL), "textChars": text.count,
            ])
            exit(0)
        }
        recorder.onFailure = { message in
            write(["error": message])
            exit(1)
        }
        if let path = ProcessInfo.processInfo.environment["PLUME_FAKE_MIC"],
           let data = FileManager.default.contents(atPath: path), let signal = SpeechGate.readWav(data) {
            MicrophoneHub.shared.replaceWithTestSignal(signal)
        }
        // Cas limites, sans toucher au vrai disque ni à une vraie visio :
        // `PLUME_MEETING_MIN_FREE_GB` relève le seuil du disque,
        // `PLUME_TEST_MEETING_PID` fait passer un processus (afplay…) pour une visio.
        let env = ProcessInfo.processInfo.environment
        if let gb = env["PLUME_MEETING_MIN_FREE_GB"].flatMap(Double.init) {
            MeetingRecorder.minFreeBytes = Int64(gb * 1_000_000_000)
        }
        if #available(macOS 14.4, *), let pid = env["PLUME_TEST_MEETING_PID"].flatMap(pid_t.init) {
            SystemAudioTap.testMeetingPID = pid
        }
        recorder.start()
        Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { timer in
            MainActor.assumeIsolated {
                let t = Date().timeIntervalSince(started)
                samples.append(["t": t, "rssMB": residentMB(), "cpu": cpuSeconds() - cpuStart,
                                "lines": Double(recorder.lines.count),
                                "micSilent": recorder.warnings.contains(.micSilent) ? 1 : 0,
                                "systemSilent": recorder.warnings.contains(.systemSilent) ? 1 : 0])
                write([:])
                if t >= seconds, recorder.phase == .recording {
                    timer.invalidate()
                    recorder.stop()
                }
            }
        }
        app.run()
    }

    static func residentMB() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? Double(info.resident_size) / 1_048_576 : 0
    }

    static func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    }

    static func fileSize(_ url: URL) -> Double {
        Double((try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0)
    }
}

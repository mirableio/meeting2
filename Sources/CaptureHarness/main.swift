import Foundation
import Darwin
import Meeting2Core

// A throwaway command-line program for testing capture by hand — not the eventual
// product UI. It records for a few seconds and prints (or saves) the resulting health
// stats, so the riskiest claim can be checked first on real hardware: that we can
// capture two non-silent audio files locally, with nothing else (calendar,
// transcription, storage) involved yet. Driven by the targets in the Makefile.
struct Arguments {
    var duration: TimeInterval = 10
    var output: URL?
    var statsOutput: URL?

    init(_ raw: [String]) throws {
        var iterator = raw.dropFirst().makeIterator()
        while let arg = iterator.next() {
            switch arg {
            case "--duration", "-d":
                guard let value = iterator.next(), let seconds = TimeInterval(value) else {
                    throw CaptureError.invalidState("Expected numeric value after \(arg)")
                }
                duration = seconds
            case "--output", "-o":
                guard let value = iterator.next() else {
                    throw CaptureError.invalidState("Expected path after \(arg)")
                }
                output = URL(fileURLWithPath: NSString(string: value).expandingTildeInPath)
            case "--stats":
                guard let value = iterator.next() else {
                    throw CaptureError.invalidState("Expected path after \(arg)")
                }
                statsOutput = URL(fileURLWithPath: NSString(string: value).expandingTildeInPath)
            case "--help", "-h":
                print(Self.help)
                exit(0)
            default:
                throw CaptureError.invalidState("Unknown argument: \(arg)")
            }
        }
    }

    static var help: String {
        """
        Usage: CaptureHarness [--duration seconds] [--output folder]

        Records mic.caf and system.caf into the output folder and writes meeting.json.
        Use --stats path.json to write machine-readable capture stats.
        Default duration: 10 seconds.
        Default output: ~/Recordings/Meetings/harness-<timestamp>
        """
    }
}

func defaultOutputFolder() -> URL {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd HH-mm-ss"

    let root = URL(fileURLWithPath: NSString(string: "~/Recordings/Meetings").expandingTildeInPath)
    return root.appendingPathComponent("harness-\(formatter.string(from: Date()))")
}

struct JSONTrackStats: Codable {
    let path: String
    let rms: Double
    let peak: Float
    let droppedBytes: Int
    let routeChanges: Int
    let hostStartTime: UInt64?
}

struct JSONRecordingStats: Codable {
    let mic: JSONTrackStats
    let system: JSONTrackStats
    let micMinusSystemStartDeltaMS: Double?
}

func jsonStats(_ stats: RecordingStats) -> JSONRecordingStats {
    let delta: Double?
    if let micHost = stats.mic.hostStartTime, let systemHost = stats.system.hostStartTime {
        delta = HostClock.milliseconds(from: systemHost, to: micHost)
    } else {
        delta = nil
    }

    return JSONRecordingStats(
        mic: JSONTrackStats(
            path: stats.mic.url.path,
            rms: stats.mic.rms,
            peak: stats.mic.peak,
            droppedBytes: stats.mic.droppedBytes,
            routeChanges: stats.mic.routeChanges,
            hostStartTime: stats.mic.hostStartTime
        ),
        system: JSONTrackStats(
            path: stats.system.url.path,
            rms: stats.system.rms,
            peak: stats.system.peak,
            droppedBytes: stats.system.droppedBytes,
            routeChanges: stats.system.routeChanges,
            hostStartTime: stats.system.hostStartTime
        ),
        micMinusSystemStartDeltaMS: delta
    )
}

@main
struct CaptureHarness {
    static func main() async {
        var diagnosticFolder: URL?
        do {
            let args = try Arguments(CommandLine.arguments)
            let folder = args.output ?? defaultOutputFolder()
            diagnosticFolder = folder
            let store = MeetingStore(root: folder.deletingLastPathComponent())

            print("Recording for \(args.duration)s")
            print("Output: \(folder.path)")
            fflush(stdout)
            DebugDiagnostics.log(recordingFolder: folder, "harness start requested duration=\(args.duration)")

            // M2 starts metadata before capture starts. This is intentionally one
            // atomic JSON write outside the sample path: if the process dies, launch
            // recovery has a durable folder identity and an `endedAt: null` marker.
            _ = try await store.markRecordingStarted(
                folder: folder,
                startedAt: Date(),
                outputRoute: OutputRouteProbe.current()
            )

            let recorder = DualTrackRecorder(folder: folder)
            try recorder.start()
            try await Task.sleep(nanoseconds: UInt64(args.duration * 1_000_000_000))
            let stats = recorder.stop()

            let deltaText = jsonStats(stats).micMinusSystemStartDeltaMS.map { String(format: "%.2fms", $0) } ?? "unknown"
            print("mic:    rms=\(stats.mic.rms) peak=\(stats.mic.peak) dropped=\(stats.mic.droppedBytes) routeChanges=\(stats.mic.routeChanges) path=\(stats.mic.url.path)")
            print("system: rms=\(stats.system.rms) peak=\(stats.system.peak) dropped=\(stats.system.droppedBytes) routeChanges=\(stats.system.routeChanges) path=\(stats.system.url.path)")
            print("startDelta mic-system: \(deltaText)")

            _ = try await store.finalizeCompletedRecording(folder: folder, stats: stats)

            if let statsOutput = args.statsOutput {
                let data = try JSONEncoder().encode(jsonStats(stats))
                try FileManager.default.createDirectory(at: statsOutput.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: statsOutput)
            }

            if stats.mic.isSilent || stats.system.isSilent {
                print("warning: one or more tracks appear silent")
            }
        } catch {
            fputs("\(error)\n", stderr)
            fputs(Arguments.help + "\n", stderr)
            DebugDiagnostics.log(recordingFolder: diagnosticFolder, "harness failed error=\(error)")
            exit(1)
        }
    }
}

import Foundation
import Meeting2Core

struct RecordingSessionStartResult {
    let folder: URL
}

struct RecordingSessionStopResult {
    let folder: URL
}

@MainActor
final class RecordingSessionController {
    // App-layer owner for the single live capture session. Keeping this out of the
    // menu controller gives manual controls, future auto-detect, and quit handling one
    // command surface: start a session, stop it, then let post-recording work run
    // elsewhere. It deliberately does not know about menu text, icons, or transcription.
    let recordingsRoot: URL

    private let store: MeetingStore
    private var recorder: DualTrackRecorder?
    private(set) var currentFolder: URL?
    private(set) var lastFolder: URL?

    init(recordingsRoot: URL, store: MeetingStore) {
        self.recordingsRoot = recordingsRoot
        self.store = store
    }

    var canStart: Bool {
        recorder == nil
    }

    var canStop: Bool {
        recorder != nil
    }

    var currentStats: RecordingStats? {
        recorder?.currentStats
    }

    func start(now: Date = Date(), source: MeetingSource = MeetingSource()) async throws -> RecordingSessionStartResult {
        guard recorder == nil else {
            throw CaptureError.invalidState("Recording already in progress")
        }

        let folder = try nextRecordingFolder(now: now)
        currentFolder = folder
        DebugDiagnostics.log(recordingFolder: folder, "session start requested")

        do {
            // Probe the output route now, before the tap exists, so we record where audio
            // was actually playing (built-in speakers vs headphones). Compression uses this
            // to decide whether the mic alone already holds the whole conversation.
            let outputRoute = OutputRouteProbe.current()
            _ = try await store.markRecordingStarted(folder: folder, startedAt: now, outputRoute: outputRoute, source: source)
            recorder = try await startRecorderOffMainActor(folder: folder)
            return RecordingSessionStartResult(folder: folder)
        } catch {
            currentFolder = nil
            recorder = nil
            DebugDiagnostics.log(recordingFolder: folder, "session start failed error=\(error)")
            throw error
        }
    }

    func stop() async throws -> RecordingSessionStopResult {
        guard let recorder else {
            throw CaptureError.invalidState("No recording is in progress")
        }

        let folder = currentFolder
        self.recorder = nil
        let stats = await stopRecorderOffMainActor(recorder)

        guard let folder else {
            throw CaptureError.invalidState("Missing recording folder during stop")
        }

        do {
            _ = try await store.finalizeCompletedRecording(folder: folder, stats: stats)
            currentFolder = nil
            lastFolder = folder
            return RecordingSessionStopResult(folder: folder)
        } catch {
            // The recorder has already closed the CAFs. Preserve the folder for Reveal
            // and let launch recovery reconstruct metadata on the next app start.
            currentFolder = nil
            lastFolder = folder
            DebugDiagnostics.log(recordingFolder: folder, "session stop metadata failed error=\(error)")
            throw error
        }
    }

    private func startRecorderOffMainActor(folder: URL) async throws -> DualTrackRecorder {
        // Core Audio process-tap creation/start can block, retry, and occasionally wait
        // on HAL server state. Keep that work off the main actor so every caller sees a
        // responsive command, whether the command came from the menu or auto-detect.
        try await Task.detached(priority: .userInitiated) {
            let newRecorder = DualTrackRecorder(folder: folder)
            try newRecorder.start()
            return newRecorder
        }.value
    }

    private func stopRecorderOffMainActor(_ recorder: DualTrackRecorder) async -> RecordingStats {
        // Stop can drain writer queues and close files. The caller removes the recorder
        // before awaiting this so live health reads cannot race the teardown path.
        await Task.detached(priority: .userInitiated) {
            recorder.stop()
        }.value
    }

    /// Picks a fresh folder named by a second-resolution start timestamp (the stable id).
    /// Two recordings begun in the same wall-clock second would collide, so append a
    /// numeric suffix until the name is free. The folder, once chosen, is never renamed.
    private func nextRecordingFolder(now: Date = Date()) throws -> URL {
        try FileManager.default.createDirectory(at: recordingsRoot, withIntermediateDirectories: true)

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH-mm-ss"

        let baseID = formatter.string(from: now)
        var candidate = recordingsRoot.appendingPathComponent(baseID)
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = recordingsRoot.appendingPathComponent("\(baseID)-\(suffix)")
            suffix += 1
        }
        return candidate
    }
}

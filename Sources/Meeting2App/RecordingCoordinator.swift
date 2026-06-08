import Foundation
import Meeting2Core

extension Notification.Name {
    /// Posted whenever a recording is created, finished, renamed, deleted, or re-transcribed —
    /// the library window observes it to reload. Coarse on purpose: a reload is cheap.
    static let meetingLibraryDidChange = Notification.Name("com.mirable.Meeting2.libraryDidChange")
}

struct RecordingCoordinatorStopResult {
    let folder: URL
    let postRecordingTask: Task<PostRecordingPipelineResult, Error>
}

@MainActor
final class RecordingCoordinator {
    // The app-shell command surface for "a recording happened." Manual menu controls
    // and future auto-detect should both come through here so they share the same
    // start/stop/finalize/reconcile sequence. This is intentionally not in the core:
    // it wires product policy and dev configuration around the reusable core pieces.
    let recordingsRoot: URL

    private let store: MeetingStore
    private let recordingSession: RecordingSessionController
    private let postRecordingPipeline: PostRecordingPipeline
    private var postRecordingTask: Task<PostRecordingPipelineResult, Error>?

    convenience init() {
        self.init(recordingsRoot: URL(fileURLWithPath: NSString(string: "~/Recordings/Meetings").expandingTildeInPath))
    }

    init(recordingsRoot: URL) {
        self.recordingsRoot = recordingsRoot
        let store = MeetingStore(root: recordingsRoot)
        self.store = store
        self.recordingSession = RecordingSessionController(recordingsRoot: recordingsRoot, store: store)
        self.postRecordingPipeline = PostRecordingPipeline(store: store)
    }

    var canStart: Bool {
        recordingSession.canStart
    }

    var canStop: Bool {
        recordingSession.canStop
    }

    var currentFolder: URL? {
        recordingSession.currentFolder
    }

    var lastFolder: URL? {
        recordingSession.lastFolder
    }

    var currentStats: RecordingStats? {
        recordingSession.currentStats
    }

    func start() async throws -> RecordingSessionStartResult {
        try await recordingSession.start()
    }

    func stopAndProcess(
        onProgress: PostRecordingProgressHandler? = nil
    ) async throws -> RecordingCoordinatorStopResult {
        let stopped = try await recordingSession.stop()
        let task = enqueuePostRecording { pipeline in
            try await pipeline.runAfterRecording(folder: stopped.folder, onProgress: onProgress)
        }
        return RecordingCoordinatorStopResult(folder: stopped.folder, postRecordingTask: task)
    }

    func recoverInterruptedRecordings() async throws -> [MeetingRecoveryResult] {
        try await postRecordingPipeline.recoverInterruptedRecordings()
    }

    func pendingTranscriptionCount() async -> Int {
        await postRecordingPipeline.pendingTranscriptionCount()
    }

    func runPendingPostRecording(
        onProgress: PostRecordingProgressHandler? = nil
    ) -> Task<PostRecordingPipelineResult, Error> {
        enqueuePostRecording { pipeline in
            try await pipeline.runPendingCompressionAndTranscription(onProgress: onProgress)
        }
    }

    func runPendingTranscriptionOnly(
        onProgress: PostRecordingProgressHandler? = nil
    ) -> Task<PostRecordingPipelineResult, Error> {
        enqueuePostRecording { pipeline in
            try await pipeline.runPendingTranscriptionOnly(onProgress: onProgress)
        }
    }

    private func enqueuePostRecording(
        operation: @escaping (PostRecordingPipeline) async throws -> PostRecordingPipelineResult
    ) -> Task<PostRecordingPipelineResult, Error> {
        let pipeline = postRecordingPipeline
        let task = Task {
            try await operation(pipeline)
        }
        postRecordingTask = task
        return task
    }

    // MARK: - Library commands (the window mutates recordings through here, not the filesystem)

    /// Every recording folder, as file-derived snapshots, for the library list. Read-only and
    /// not chained behind the run queue.
    func recordings() async -> [MeetingSnapshot] {
        (try? await store.scan()) ?? []
    }

    func rename(folder: URL, to displayName: String) async throws {
        try await store.setDisplayName(folder: folder, displayName)
        notifyLibraryChanged()
    }

    /// Moves a recording to the Trash (recoverable). Refuses the live recording and one whose
    /// transcription is `.running`, so we don't trash a folder out from under an open write —
    /// authoritatively, not trusting the timer-driven row `isBusy`. (A folder that's only being
    /// compressed isn't guarded: compression has no status by design, deletes to the Trash, and is
    /// per-item failure-isolated, so the worst case is a benign caught error on a recoverable item.)
    func deleteRecording(folder: URL) async throws {
        guard !isLiveRecording(folder) else {
            throw CaptureError.invalidState("That recording is still in progress")
        }
        if let snapshot = try? await store.snapshot(folder: folder),
           snapshot.metadata?.jobs.transcription.status == .running {
            throw CaptureError.invalidState("That recording is still transcribing")
        }
        try FileManager.default.trashItem(at: folder, resultingItemURL: nil)
        notifyLibraryChanged()
    }

    /// Re-queues a recording for transcription: clears its transcript (so `needsWork` is true
    /// again). Refuses the live recording and one that's already transcribing, so we never race
    /// open writes. The caller kicks the actual sweep (so it's observed for UI like any other).
    func clearTranscriptForReTranscribe(folder: URL) async throws {
        guard !isLiveRecording(folder) else {
            throw CaptureError.invalidState("That recording is still in progress")
        }
        let snapshot = try await store.snapshot(folder: folder)
        guard snapshot.metadata?.jobs.transcription.status != .running else {
            throw CaptureError.invalidState("That recording is already transcribing")
        }
        try await store.clearTranscript(folder: folder)
        notifyLibraryChanged()
    }

    func notifyLibraryChanged() {
        NotificationCenter.default.post(name: .meetingLibraryDidChange, object: nil)
    }

    /// Whether `folder` is the one being recorded right now. Uses the same canonical comparison the
    /// library overlay uses (`standardizedFileURL.path`) — raw `URL` equality would miss e.g. a
    /// trailing-slash difference and let a live folder be deleted/re-transcribed.
    private func isLiveRecording(_ folder: URL) -> Bool {
        guard let current = currentFolder else { return false }
        return folder.standardizedFileURL.path == current.standardizedFileURL.path
    }
}

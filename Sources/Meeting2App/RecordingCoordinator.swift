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

    /// How short a take has to be before we treat it as junk and bin it. Shared by the auto-stop
    /// prune and the manual-stop discard.
    static let minimumKeepSeconds: Double = 30

    func start(source: MeetingSource = MeetingSource()) async throws -> RecordingSessionStartResult {
        try await recordingSession.start(source: source)
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

    /// Stop an auto-detected take and *then* decide what to do with it. Unlike `stopAndProcess`,
    /// which always enqueues the pipeline immediately, a provisional auto recording is judged first:
    /// a too-short or fully-silent take is moved to the Trash (recoverable), anything else is kept
    /// and enqueued exactly like a manual stop. Returns `nil` when the take was discarded.
    ///
    /// `ownerActiveSeconds` is how long the external mic owner actually held the mic — the real
    /// meeting length. "Too short" is judged on *that*, not the finalized recording duration, which
    /// also includes the stop grace (so a 5-second grab would otherwise look like a ~125-second
    /// file and survive).
    ///
    /// Keep-on-uncertainty: the both-silent check needs a finalized snapshot; if we can't read it,
    /// we KEEP and enqueue — never Trash a recording we can't actually judge ("never miss").
    func stopAutoRecording(
        ownerActiveSeconds: TimeInterval,
        onProgress: PostRecordingProgressHandler? = nil
    ) async throws -> RecordingCoordinatorStopResult? {
        let stopped = try await recordingSession.stop()
        if await shouldPruneAutoRecording(folder: stopped.folder, ownerActiveSeconds: ownerActiveSeconds) {
            try FileManager.default.trashItem(at: stopped.folder, resultingItemURL: nil)
            notifyLibraryChanged()
            return nil
        }
        let task = enqueuePostRecording { pipeline in
            try await pipeline.runAfterRecording(folder: stopped.folder, onProgress: onProgress)
        }
        return RecordingCoordinatorStopResult(folder: stopped.folder, postRecordingTask: task)
    }

    /// Stop and discard outright — used when the caller has already decided the take is junk (a
    /// manually-stopped recording under `minimumKeepSeconds`). Trashes regardless of whether
    /// finalize succeeded: the audio is closed either way and the folder is junk we want gone. Trash
    /// is recoverable, so this is never lossy.
    func stopAndDiscard() async throws {
        let folder = currentFolder
        // The finalize error is intentionally ignored — the recorder is already closed and we're
        // discarding the folder regardless. The Trash move is NOT: if it fails the recording is
        // still on disk, so this throws and the caller must not report success.
        _ = try? await recordingSession.stop()
        defer { notifyLibraryChanged() }  // reflect reality either way (folder gone, or still there)
        if let folder {
            try FileManager.default.trashItem(at: folder, resultingItemURL: nil)
        }
    }

    /// Prune only when we can *positively* judge the take as junk: the external owner held the mic
    /// for less than the minimum, or both tracks are explicitly silent. Anything else stays.
    private func shouldPruneAutoRecording(folder: URL, ownerActiveSeconds: TimeInterval) async -> Bool {
        if ownerActiveSeconds < Self.minimumKeepSeconds { return true }
        if let metadata = (try? await store.snapshot(folder: folder))?.metadata,
           metadata.audioHealth.micSilent == true, metadata.audioHealth.systemSilent == true {
            return true
        }
        return false
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

import Foundation
import Meeting2Core

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

    private let recordingSession: RecordingSessionController
    private let postRecordingPipeline: PostRecordingPipeline
    private var postRecordingTask: Task<PostRecordingPipelineResult, Error>?

    convenience init() {
        self.init(recordingsRoot: URL(fileURLWithPath: NSString(string: "~/Recordings/Meetings").expandingTildeInPath))
    }

    init(recordingsRoot: URL) {
        self.recordingsRoot = recordingsRoot
        let store = MeetingStore(root: recordingsRoot)
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
        onPhase: PostRecordingPhaseHandler? = nil
    ) async throws -> RecordingCoordinatorStopResult {
        let stopped = try await recordingSession.stop()
        let task = enqueuePostRecording { pipeline in
            try await pipeline.runAfterRecording(folder: stopped.folder, onPhase: onPhase)
        }
        return RecordingCoordinatorStopResult(folder: stopped.folder, postRecordingTask: task)
    }

    func recoverInterruptedRecordings() async throws -> [MeetingRecoveryResult] {
        try await postRecordingPipeline.recoverInterruptedRecordings()
    }

    func runPendingPostRecording(
        onPhase: PostRecordingPhaseHandler? = nil
    ) -> Task<PostRecordingPipelineResult, Error> {
        enqueuePostRecording { pipeline in
            try await pipeline.runPendingCompressionAndTranscription(onPhase: onPhase)
        }
    }

    func runPendingTranscriptionOnly(
        onPhase: PostRecordingPhaseHandler? = nil
    ) -> Task<PostRecordingPipelineResult, Error> {
        enqueuePostRecording { pipeline in
            try await pipeline.runPendingTranscriptionOnly(onPhase: onPhase)
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

}

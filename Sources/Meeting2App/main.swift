import AppKit
import Carbon.HIToolbox
import Combine
import Foundation
import Meeting2Core

enum RecorderMenuState: Equatable {
    case idle
    case starting
    case recording
    case stopping
    case failed
}

/// What the menu-bar icon should depict. Rendered by `StatusItemController` as a real
/// (non-template) coloured circle so it can be red/orange and breathe — things a SwiftUI
/// `MenuBarExtra` label can't do because it force-templates to monochrome.
enum IconState: Equatable {
    case idle              // neutral adaptive circle
    case attention         // amber "!" — an unresolved problem
    case transitioning     // arming/finalizing
    case recording         // red circle, breathing
    case recordingWarning  // orange circle, breathing (a track is missing)
    case processing        // green⇄neutral colour pulse — compressing/transcribing
    case success           // solid green, held briefly after work finishes
}

/// After-the-fact work the app is doing once a recording has stopped. Surfaced as an
/// in-progress line in the menu and a pulsing green icon, so the user can see it's busy.
enum ProcessingActivity: Equatable {
    case processingAudio(current: Int, total: Int)  // merging the two tracks into one file
    case transcribing(current: Int, total: Int)

    /// The "N of M" count is shown only when `total > 1` — a single item reads plainly, never
    /// "1 of 1".
    var headerText: String {
        switch self {
        case let .processingAudio(current, total):
            return total > 1 ? "Processing audio \(current) of \(total)…" : "Processing audio…"
        case let .transcribing(current, total):
            return total > 1 ? "Transcribing \(current) of \(total)…" : "Transcribing…"
        }
    }
}

/// Live audio-health warning while recording. Both tracks are watched, but with very
/// different sensitivity (see `checkLiveAudioHealth`): system silence almost always means
/// capture broke, while a quiet mic is usually just listening/mute.
enum LiveAudioWarning: String, Equatable {
    case none
    case system
    case mic
    case both
}

/// A problem that persists across capture states until the user fixes or dismisses it.
/// Drives the amber `!` badge on the menu-bar icon.
enum Attention: Equatable, Identifiable {
    case startFailed(String)
    case transcriptionFailed
    case permissionMissing

    var id: String {
        switch self {
        case .startFailed: return "startFailed"
        case .transcriptionFailed: return "transcriptionFailed"
        case .permissionMissing: return "permissionMissing"
        }
    }

    var headerText: String {
        switch self {
        case .startFailed: return "⚠ Couldn't start recording"
        case .transcriptionFailed: return "⚠ Transcription failed"
        case .permissionMissing: return "⚠ Microphone access needed"
        }
    }
}

@MainActor
final class RecorderMenuController: ObservableObject {
    // Presentation state for the menu-bar surface. Recording lifecycle and post-recording
    // work are reached through `RecordingCoordinator`, so future auto-detect can call the
    // same commands without depending on SwiftUI menu details. See plans/STATUS-UX.md for
    // the icon/menu/attention design this implements.
    @Published private(set) var state: RecorderMenuState = .idle
    @Published private(set) var currentFolder: URL?
    @Published private(set) var lastFolder: URL?
    @Published private(set) var statusMessage = "Ready"
    @Published private(set) var lastError: String?
    @Published private(set) var liveAudioWarning: LiveAudioWarning = .none
    @Published private(set) var attention: [Attention] = []
    @Published private(set) var processingActivity: ProcessingActivity?
    @Published private(set) var pendingTranscriptionCount = 0
    @Published private(set) var successFlashActive = false
    /// User opt-in for auto-detect (off by default). Persisted; mirrored by the menu checkmark.
    @Published private(set) var autoRecordEnabled: Bool
    @Published private var recordingElapsedSeconds = 0
    @Published private var isBusyStateVisible = false

    var recordingsRoot: URL { recordingCoordinator.recordingsRoot }

    /// Set by `AppDelegate` to open the recordings window from the menu — keeps the controller
    /// from knowing about the window/library types.
    var onOpenRecordings: (() -> Void)?

    /// Set by `AppDelegate` to start/stop the mic-owner monitor when auto-record is toggled —
    /// keeps the controller from knowing about the detection subsystem.
    var onAutoRecordChanged: ((Bool) -> Void)?
    private static let autoRecordDefaultsKey = "AutoRecordEnabled"

    private let recordingCoordinator: RecordingCoordinator
    private var hotKey: GlobalHotKey?
    private var healthMonitorTask: Task<Void, Never>?
    private var elapsedClockTask: Task<Void, Never>?
    private var postRecordingTask: Task<Void, Never>?
    private var recordingStartedAt: Date?
    private var micEverHadAudio = false
    private var systemSilentSince: Date?
    private var busyPresentationTask: Task<Void, Never>?
    private var busyPresentationSourceState: RecorderMenuState?
    /// Set when a quit arrives while a stop is already running, so the in-flight stop terminates on
    /// completion instead of being killed mid-drain by an immediate second terminate.
    private var quitRequested = false
    private var successFlashTask: Task<Void, Never>?
    private var transcribingStartedAt: Date?
    private static let successFlashSeconds: UInt64 = 1_500_000_000
    private static let busyPresentationDelayNanoseconds: UInt64 = 350_000_000
    private static let micSilenceGraceSeconds: TimeInterval = 30
    private static let systemSilenceGraceSeconds: TimeInterval = 15
    private static let liveSilenceLevel: Float = 0.003

    init(coordinator: RecordingCoordinator) {
        recordingCoordinator = coordinator
        autoRecordEnabled = UserDefaults.standard.bool(forKey: Self.autoRecordDefaultsKey)

        // Global ⌃⌘R toggles recording without opening the menu (the fast path). The
        // Carbon handler fires on the main thread, so hop straight onto the main actor.
        hotKey = GlobalHotKey(
            keyCode: UInt32(kVK_ANSI_R),
            modifiers: UInt32(cmdKey | controlKey)
        ) { [weak self] in
            MainActor.assumeIsolated { self?.toggleRecording() }
        }

        Task {
            await recoverInterruptedRecordings(silent: true)
        }
    }

    // MARK: - Derived UI

    var canStart: Bool {
        guard recordingCoordinator.canStart else { return false }
        if case .idle = state { return true }
        if case .failed = state { return true }
        return false
    }

    var canStop: Bool {
        guard recordingCoordinator.canStop else { return false }
        if case .recording = state { return true }
        return false
    }

    var isRecording: Bool {
        if case .recording = presentedState { return true }
        return false
    }

    private var hasAttention: Bool { !attention.isEmpty }

    /// What the menu-bar icon should show right now. Recording wins over everything; once
    /// idle, a brief success flash beats in-progress work, which beats an unresolved problem.
    var iconState: IconState {
        switch presentedState {
        case .recording:
            return liveAudioWarning == .none ? .recording : .recordingWarning
        case .starting, .stopping:
            return .transitioning
        case .idle, .failed:
            if successFlashActive { return .success }
            if processingActivity != nil { return .processing }
            return hasAttention ? .attention : .idle
        }
    }

    /// Recent loudness (louder of the two tracks) for the breathing animation; 0 when
    /// not recording.
    var breathLevel: Float {
        guard isRecording, let stats = recordingCoordinator.currentStats else { return 0 }
        return max(stats.mic.recentLevel, stats.system.recentLevel)
    }

    /// The minimal ambient text beside the icon: just the live timer while recording.
    /// Empty otherwise.
    var menuBarTitle: String {
        guard case .recording = presentedState else { return "" }
        return formattedRecordingElapsed
    }

    /// The status sentence shown as the menu's first (dimmed) line. No live timer here —
    /// the menu is rebuilt only when it opens, so a timer would just sit frozen; the
    /// ticking one lives in the menu bar.
    var menuStatusHeader: String {
        switch presentedState {
        case .recording:
            // Recording + (if anything's wrong) a short note on the same line. The orange
            // dot already flags trouble, so the text stays terse.
            if let warning = liveWarningShort {
                return "Recording     \(warning)"
            }
            return "Recording"
        case .starting:
            return "Starting…"
        case .stopping:
            return "Stopping…"
        case .idle, .failed:
            // In-progress work outranks a stale status line, but not an active problem.
            if let activity = processingActivity, !hasAttention {
                return activity.headerText
            }
            return attention.first?.headerText ?? statusMessage
        }
    }

    /// A terse label for a live audio warning, shown inline after "Recording".
    private var liveWarningShort: String? {
        switch liveAudioWarning {
        case .none: return nil
        case .system: return "no call audio"
        case .mic: return "no mic audio"
        case .both: return "no audio"
        }
    }

    /// While a recording is live, what (if anything) is still processing in the background —
    /// shown as a dimmed secondary menu line so an in-flight transcription isn't hidden by the
    /// new recording. Nil when not recording or nothing is running. The icon stays the
    /// recording dot; this is the menu's job (see plans/BACKGROUND.md, change 3).
    var backgroundActivityText: String? {
        guard case .recording = presentedState, let activity = processingActivity else { return nil }
        return activity.headerText
    }

    private var presentedState: RecorderMenuState {
        switch state {
        case .starting where !isBusyStateVisible,
             .stopping where !isBusyStateVisible:
            return busyPresentationSourceState ?? state
        default:
            return state
        }
    }

    private var formattedRecordingElapsed: String {
        Self.formatClock(recordingElapsedSeconds)
    }

    /// How long the current transcription has been running (m:ss), or nil when not
    /// transcribing. Shown inside the menu only — the menu-bar icon stays just the pulsing
    /// dot. Computed live, so the value is current whenever the menu reads it.
    var transcribingElapsedText: String? {
        guard case .transcribing = processingActivity, let start = transcribingStartedAt else { return nil }
        return Self.formatClock(max(0, Int(Date().timeIntervalSince(start))))
    }

    /// Formats a whole-second duration as `m:ss` (or `h:mm:ss` once past an hour).
    private static func formatClock(_ totalSeconds: Int) -> String {
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds / 60) % 60
        let seconds = totalSeconds % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }

    // MARK: - Commands

    /// The global-hotkey / quick action: start when idle, stop when recording.
    func toggleRecording() {
        if canStop {
            stopRecording()
        } else if canStart {
            startRecording()
        }
    }

    /// `completion` reports whether capture actually started (true) or failed (false), on the main
    /// actor — auto-detect needs the real outcome rather than assuming success, so it doesn't wedge
    /// or notify on a failed start.
    func startRecording(source: MeetingSource = MeetingSource(), completion: ((Bool) -> Void)? = nil) {
        guard canStart else { completion?(false); return }

        lastError = nil
        liveAudioWarning = .none
        micEverHadAudio = false
        systemSilentSince = nil
        endSuccessFlash()
        // Do NOT clear processingActivity/transcribingStartedAt here: a transcription from a
        // previous meeting keeps running in the background, and we now keep it visible (as a
        // secondary menu line) instead of hiding it the moment a new recording starts. The
        // icon is owned by recording; `iconState`/`menuStatusHeader` already mask the activity
        // while recording. It clears itself when that work finishes (handlePostRecording*).
        clearAttention(.startFailed(""))
        clearAttention(.permissionMissing)
        beginBusyPresentation(to: .starting, delayedStatusMessage: "Starting recording...")

        Task {
            do {
                let result = try await recordingCoordinator.start(source: source)
                currentFolder = result.folder
                statusMessage = "Recording to \(result.folder.lastPathComponent)"
                endBusyPresentation()
                state = .recording
                startElapsedClock(startedAt: Date())
                startHealthMonitor(folder: result.folder)
                recordingCoordinator.notifyLibraryChanged()  // new live row
                completion?(true)
            } catch {
                endBusyPresentation()
                stopHealthMonitor()
                stopElapsedClock()
                currentFolder = recordingCoordinator.currentFolder
                lastFolder = recordingCoordinator.lastFolder
                liveAudioWarning = .none
                lastError = String(describing: error)
                statusMessage = "Ready"
                state = .idle
                if isPermissionError(error) {
                    addAttention(.permissionMissing)
                } else {
                    addAttention(.startFailed(String(describing: error)))
                }
                DebugDiagnostics.log(recordingFolder: currentFolder, "menu start failed error=\(error)")
                completion?(false)
            }
        }
    }

    func stopRecording(terminateAfterStop: Bool = false) {
        guard recordingCoordinator.canStop else {
            if terminateAfterStop {
                NSApplication.shared.terminate(nil)
            }
            return
        }

        let folder = currentFolder
        stopHealthMonitor()
        stopElapsedClock()
        liveAudioWarning = .none
        beginBusyPresentation(to: .stopping, delayedStatusMessage: "Stopping recording...")

        Task {
            if let folder {
                DebugDiagnostics.log(recordingFolder: folder, "menu stop requested")
            }

            do {
                let result = try await recordingCoordinator.stopAndProcess(onProgress: progressHandler())
                currentFolder = nil
                lastFolder = result.folder
                statusMessage = "Saved \(result.folder.lastPathComponent)"
                endBusyPresentation()
                state = .idle
                recordingCoordinator.notifyLibraryChanged()  // recording now finalized
                observePostRecording(result.postRecordingTask, silent: false)

                if terminateAfterStop || quitRequested {
                    NSApplication.shared.terminate(nil)
                }
            } catch {
                // The audio is already safe: `RecordingSessionController.stop()` closes
                // both CAFs before metadata finalization can throw. A later recovery pass
                // rebuilds `meeting.json`, so this is visible but not data loss.
                currentFolder = nil
                lastFolder = recordingCoordinator.lastFolder ?? folder
                lastError = String(describing: error)
                statusMessage = "Stop saved audio, metadata failed"
                endBusyPresentation()
                state = .idle
                DebugDiagnostics.log(recordingFolder: lastFolder, "menu stop metadata failed error=\(error)")
                // The audio is safe; if this stop was triggered by (or raced) a Quit, still
                // terminate so the app doesn't hang waiting for a completion that already happened.
                if terminateAfterStop || quitRequested {
                    NSApplication.shared.terminate(nil)
                }
            }
        }
    }

    /// Stop a recording that auto-detect started: same UI teardown as a manual stop, but the
    /// coordinator may *discard* the take (too short / silent) instead of enqueuing transcription.
    /// `ownerActiveSeconds` is how long the external mic owner was actually present — the real
    /// meeting length — which is what "too short" is judged on (not the recording wall-clock, which
    /// also includes the stop grace).
    func stopAutoRecording(ownerActiveSeconds: TimeInterval) {
        guard recordingCoordinator.canStop else { return }

        stopHealthMonitor()
        stopElapsedClock()
        liveAudioWarning = .none
        beginBusyPresentation(to: .stopping, delayedStatusMessage: "Stopping recording...")

        Task {
            do {
                let result = try await recordingCoordinator.stopAutoRecording(
                    ownerActiveSeconds: ownerActiveSeconds,
                    onProgress: progressHandler()
                )
                currentFolder = nil
                endBusyPresentation()
                state = .idle
                if let result {
                    lastFolder = result.folder
                    statusMessage = "Saved \(result.folder.lastPathComponent)"
                    recordingCoordinator.notifyLibraryChanged()
                    observePostRecording(result.postRecordingTask, silent: false)
                } else {
                    // Discarded — the provisional row created at start is now gone.
                    statusMessage = "Discarded a short auto-recording"
                    recordingCoordinator.notifyLibraryChanged()
                }
            } catch {
                // Audio is safe (CAFs closed); leave the folder for launch recovery to finalize.
                currentFolder = nil
                lastFolder = recordingCoordinator.lastFolder
                lastError = String(describing: error)
                statusMessage = "Stop saved audio, metadata failed"
                endBusyPresentation()
                state = .idle
            }
        }
    }

    func transcribePendingRecordings() {
        observePostRecording(
            recordingCoordinator.runPendingTranscriptionOnly(onProgress: progressHandler()),
            silent: false
        )
    }

    /// Retry after a transcription failure. Success clears the badge in `handlePostRecordingFinished`.
    func retryTranscription() {
        transcribePendingRecordings()
    }

    func openRecordings() {
        onOpenRecordings?()
    }

    /// Re-transcribe a specific recording (from the library): clear its transcript, then drive
    /// the normal observed pending sweep so the menu shows progress and failures badge as usual.
    func reTranscribe(folder: URL) {
        Task {
            do {
                try await recordingCoordinator.clearTranscriptForReTranscribe(folder: folder)
                transcribePendingRecordings()
            } catch {
                lastError = String(describing: error)
                statusMessage = "Couldn't re-transcribe — \(error)"
            }
        }
    }

    func openRecordingsFolder() {
        try? FileManager.default.createDirectory(at: recordingsRoot, withIntermediateDirectories: true)
        NSWorkspace.shared.open(recordingsRoot)
    }

    func revealCurrentOrLastRecording() {
        guard let folder = currentFolder ?? lastFolder else { return }
        NSWorkspace.shared.activateFileViewerSelecting([folder])
    }

    /// Open the Microphone pane of Privacy & Security so the user can grant access.
    func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    func quit() {
        // Route the status-menu Quit through `applicationShouldTerminate` (→ `terminationReply`)
        // so every quit path shares one guard.
        NSApplication.shared.terminate(nil)
    }

    func toggleAutoRecord() { setAutoRecord(!autoRecordEnabled) }

    func setAutoRecord(_ enabled: Bool) {
        guard enabled != autoRecordEnabled else { return }
        autoRecordEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.autoRecordDefaultsKey)
        onAutoRecordChanged?(enabled)
    }

    /// The single decision for every quit path (⌘Q, Dock, Apple-menu, status-menu, logout). Never
    /// tears the process down while a recording is live *or* mid-stop:
    ///  - live recording: kick a clean stop, terminate from its completion;
    ///  - already stopping: remember the quit and let the in-flight stop terminate when it finishes
    ///    (a second quit must not kill the drain — `canStop` is already false here);
    ///  - otherwise: quit now.
    func terminationReply() -> NSApplication.TerminateReply {
        if canStop {
            stopRecording(terminateAfterStop: true)
            return .terminateCancel
        }
        if state == .stopping {
            quitRequested = true
            return .terminateCancel
        }
        return .terminateNow
    }

    // MARK: - Attention

    func dismissAttention(_ item: Attention) {
        attention.removeAll { $0.id == item.id }
    }

    private func addAttention(_ item: Attention) {
        attention.removeAll { $0.id == item.id }
        attention.append(item)
    }

    private func clearAttention(_ item: Attention) {
        attention.removeAll { $0.id == item.id }
    }

    // MARK: - Post-recording

    private func observePostRecording(
        _ task: Task<PostRecordingPipelineResult, Error>,
        silent: Bool
    ) {
        postRecordingTask = Task { [weak self] in
            do {
                let result = try await task.value
                self?.handlePostRecordingFinished(result, silent: silent)
            } catch {
                self?.handlePostRecordingFailed(error, silent: silent)
            }
        }
    }

    private func handlePostRecordingFinished(_ result: PostRecordingPipelineResult, silent: Bool) {
        // The work is done — drop the in-progress line/icon and its clock.
        processingActivity = nil
        transcribingStartedAt = nil
        refreshPendingCount()
        recordingCoordinator.notifyLibraryChanged()

        // Per-item transcription failures raise the badge; a clean run clears it. (This runs
        // even for silent launch sweeps, so a background failure still surfaces.)
        if result.transcriptionFailures.isEmpty {
            clearAttention(.transcriptionFailed)
        } else {
            addAttention(.transcriptionFailed)
        }

        guard !silent, case .idle = state else { return }

        let transcribed = result.transcriptionResults.count
        // Fold compression and transcription failures together: any failure means something
        // didn't finish, so don't flash success — even if an *unrelated* recording transcribed
        // fine (otherwise a just-stopped recording's compression failure is hidden behind an
        // older one's success). The audio is safe either way and the next sweep retries.
        let didntFinish = result.transcriptionFailures.count + result.compressionFailures.count
        if didntFinish > 0 {
            if transcribed > 0 {
                statusMessage = "Transcribed \(transcribed), \(didntFinish) didn't finish — audio is safe"
            } else {
                statusMessage = "\(didntFinish) recording\(didntFinish == 1 ? "" : "s") didn't finish — audio is safe"
            }
            return
        }

        if transcribed > 0 {
            statusMessage = transcribed == 1 ? "✓ Transcribed recording" : "✓ Transcribed \(transcribed) recordings"
            beginSuccessFlash()
            return
        }

        let compressed = result.compressionResults.filter(\.didCompress)
        guard !compressed.isEmpty else { return }
        statusMessage = compressed.count == 1
            ? "✓ Saved recording"
            : "✓ Saved \(compressed.count) recordings"
        beginSuccessFlash()
    }

    /// Hold the icon solid green for ~1s after work completes, then fall back to idle.
    private func beginSuccessFlash() {
        endSuccessFlash()
        successFlashActive = true
        successFlashTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.successFlashSeconds)
            guard !Task.isCancelled else { return }
            self?.successFlashActive = false
        }
    }

    private func endSuccessFlash() {
        successFlashTask?.cancel()
        successFlashTask = nil
        successFlashActive = false
    }

    /// A progress callback for the pipeline. Hops onto the main actor and reflects the current
    /// stage + "N of M" as the in-progress activity. `[weak self]` so a finished controller
    /// doesn't keep the closure alive.
    private func progressHandler() -> PostRecordingProgressHandler {
        { [weak self] progress in
            Task { @MainActor in
                self?.applyProgress(progress)
            }
        }
    }

    private func applyProgress(_ progress: PostRecordingProgress) {
        switch progress.phase {
        case .compressing:
            processingActivity = .processingAudio(current: progress.current, total: progress.total)
        case .transcribing:
            // Start the transcription clock once, when the stage begins — it spans the whole
            // batch, not each item.
            if case .transcribing = processingActivity {} else { transcribingStartedAt = Date() }
            processingActivity = .transcribing(current: progress.current, total: progress.total)
        }
    }

    /// Refresh the cached "N pending transcriptions" count the menu shows on its button. The
    /// menu build is synchronous and can't await a scan, so we cache it: refreshed after each
    /// run finishes and when the menu opens (`StatusItemController`). The async result lands on
    /// the main actor and republishes, so an open menu picks it up on its next refresh tick.
    func refreshPendingCount() {
        Task { [weak self] in
            guard let self else { return }
            let count = await recordingCoordinator.pendingTranscriptionCount()
            self.pendingTranscriptionCount = count
        }
    }

    private func handlePostRecordingFailed(_ error: Error, silent: Bool) {
        // Whatever happened, we're no longer mid-work.
        processingActivity = nil
        transcribingStartedAt = nil
        refreshPendingCount()
        recordingCoordinator.notifyLibraryChanged()

        // A missing API key is not a failure to badge — transcription is opt-in, so we
        // never nag about it. Skip it whether the run was silent (launch) or not.
        if isMissingAPIKeyError(error) {
            DebugDiagnostics.log("transcription skipped: no API key")
            return
        }

        if case .transcription = error as? PostRecordingPipelineError {
            addAttention(.transcriptionFailed)
        }

        if !silent {
            lastError = String(describing: error)
            if case .idle = state {
                switch error as? PostRecordingPipelineError {
                case .compression: statusMessage = "Compression failed, audio preserved"
                case .transcription: statusMessage = "Transcription failed, audio preserved"
                case nil: statusMessage = "Post-recording work failed, audio preserved"
                }
            }
        }
        DebugDiagnostics.log("post-recording work failed error=\(error)")
    }

    func recoverInterruptedRecordings(silent: Bool = false) async {
        do {
            let results = try await recordingCoordinator.recoverInterruptedRecordings()
            defer {
                observePostRecording(
                    recordingCoordinator.runPendingPostRecording(onProgress: progressHandler()),
                    silent: silent
                )
            }
            guard !silent || !results.isEmpty else { return }
            let recovered = results.filter(\.didRecover).count
            let failed = results.count - recovered
            if results.isEmpty {
                statusMessage = "No interrupted recordings"
            } else if failed == 0 {
                statusMessage = "Recovered \(recovered) interrupted recording\(recovered == 1 ? "" : "s")"
            } else {
                statusMessage = "Recovered \(recovered), failed \(failed)"
            }
        } catch {
            lastError = String(describing: error)
            statusMessage = "Recovery failed"
            state = .idle
        }
    }

    // MARK: - Busy presentation, clock, health

    private func beginBusyPresentation(to busyState: RecorderMenuState, delayedStatusMessage: String) {
        // `state` is lifecycle truth and flips immediately so commands are disabled as
        // soon as the click is accepted. The menu-bar icon/title are presentation: a fast
        // start or stop should not flash a transitional state for a single frame.
        busyPresentationTask?.cancel()
        busyPresentationSourceState = presentedState
        isBusyStateVisible = false
        state = busyState

        busyPresentationTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.busyPresentationDelayNanoseconds)
            guard !Task.isCancelled, let self, self.state == busyState else { return }
            self.isBusyStateVisible = true
            self.statusMessage = delayedStatusMessage
        }
    }

    private func endBusyPresentation() {
        busyPresentationTask?.cancel()
        busyPresentationTask = nil
        busyPresentationSourceState = nil
        isBusyStateVisible = false
    }

    private func startHealthMonitor(folder: URL) {
        stopHealthMonitor()

        // After a short warm-up, sample both tracks every couple of seconds. This only
        // drives the live warning; the authoritative silence verdict is the stopped
        // track's RMS/peak in meeting.json.
        healthMonitorTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)

            while !Task.isCancelled {
                self?.checkLiveAudioHealth(folder: folder)
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    private func stopHealthMonitor() {
        healthMonitorTask?.cancel()
        healthMonitorTask = nil
    }

    private func startElapsedClock(startedAt: Date) {
        // Derive display time from wall clock instead of incrementing a counter. Menu-bar
        // apps can be de-prioritized briefly by AppKit; recomputing from `startedAt` keeps
        // the visible duration honest after scheduling delays.
        elapsedClockTask?.cancel()
        recordingStartedAt = startedAt
        recordingElapsedSeconds = 0

        elapsedClockTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.refreshRecordingElapsed()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    private func stopElapsedClock() {
        elapsedClockTask?.cancel()
        elapsedClockTask = nil
        recordingStartedAt = nil
        recordingElapsedSeconds = 0
    }

    private func refreshRecordingElapsed(now: Date = Date()) {
        guard case .recording = state, let recordingStartedAt else { return }
        recordingElapsedSeconds = max(0, Int(now.timeIntervalSince(recordingStartedAt)))
    }

    private func checkLiveAudioHealth(folder: URL) {
        guard case .recording = state,
              currentFolder == folder,
              let stats = recordingCoordinator.currentStats else {
            return
        }

        let now = Date()

        // System: warn on *sustained recent* silence — whether the call audio never
        // started or dropped mid-meeting. We use `recentLevel` (a decaying recent loudness)
        // with a grace, not cumulative `isSilent`: cumulative RMS never reads silent again
        // once any sound has occurred, so it would miss a mid-call drop. A short pause
        // won't trip it; ~6 s of quiet will, and it clears the moment audio returns.
        let systemQuiet = stats.system.hostStartTime == nil || stats.system.recentLevel < Self.liveSilenceLevel
        if systemQuiet {
            if systemSilentSince == nil { systemSilentSince = now }
        } else {
            systemSilentSince = nil
        }
        let systemBad = systemSilentSince.map { now.timeIntervalSince($0) >= Self.systemSilenceGraceSeconds } ?? false

        // Mic: only flag it if it has produced *no* audio at all past a long grace — a quiet
        // mic mid-call is normal (you're listening or muted), so we never re-flag once it
        // has had real audio. Both silent at once is the loudest, unambiguous case.
        if stats.mic.hostStartTime != nil, !stats.mic.isSilent {
            micEverHadAudio = true
        }
        let elapsed = recordingStartedAt.map { now.timeIntervalSince($0) } ?? 0
        let micBad = !micEverHadAudio && elapsed > Self.micSilenceGraceSeconds

        let warning: LiveAudioWarning
        if systemBad, micBad {
            warning = .both
        } else if systemBad {
            warning = .system
        } else if micBad {
            warning = .mic
        } else {
            warning = .none
        }

        guard warning != liveAudioWarning else { return }
        liveAudioWarning = warning
        DebugDiagnostics.log(
            recordingFolder: folder,
            "live audio warning=\(warning.rawValue) micEverHadAudio=\(micEverHadAudio) " +
            "systemRMS=\(stats.system.rms) micRMS=\(stats.mic.rms)"
        )
    }

    // MARK: - Error classification

    private func isPermissionError(_ error: Error) -> Bool {
        String(describing: error).lowercased().contains("permission")
    }

    private func isMissingAPIKeyError(_ error: Error) -> Bool {
        // Match the typed configuration error (unwrapping the pipeline's transcription
        // wrapper) rather than a substring of the message — the substring would silently
        // start nagging, or stop, if the wording ever changed.
        var candidate = error
        if case let .transcription(inner)? = error as? PostRecordingPipelineError {
            candidate = inner
        }
        if let configError = candidate as? TranscriptionConfigurationError, case .missingAPIKey = configError {
            return true
        }
        return false
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var coordinator: RecordingCoordinator?
    private var controller: RecorderMenuController?
    private var statusItemController: StatusItemController?
    private var library: RecordingsLibraryViewModel?
    private var windowController: RecordingsWindowController?
    private var autoRecordController: AutoRecordController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // One shared coordinator (store + pipeline), injected into both the menu and the
        // library — never a second pipeline/store that could diverge.
        let coordinator = RecordingCoordinator()
        self.coordinator = coordinator

        let controller = RecorderMenuController(coordinator: coordinator)
        self.controller = controller
        self.statusItemController = StatusItemController(controller: controller)

        let library = RecordingsLibraryViewModel(coordinator: coordinator)
        // Re-transcribe routes back through the menu controller so it's the same observed
        // sweep (menu shows progress, failures badge) as any other transcription.
        library.reTranscribeAction = { [weak controller] folder in controller?.reTranscribe(folder: folder) }
        self.library = library

        let windowController = RecordingsWindowController(viewModel: library)
        self.windowController = windowController
        controller.onOpenRecordings = { [weak windowController] in windowController?.show() }

        // Auto-detect: the controller owns the opt-in setting; we start/stop the mic-owner monitor
        // when it changes, and honour the persisted setting at launch.
        let autoRecordController = AutoRecordController(controller: controller)
        self.autoRecordController = autoRecordController
        controller.onAutoRecordChanged = { [weak autoRecordController] enabled in
            if enabled { autoRecordController?.enable() } else { autoRecordController?.disable() }
        }
        if controller.autoRecordEnabled { autoRecordController.enable() }

        // A minimal main menu so the recordings window behaves like a normal window while it's
        // up (⌘W to close, ⌘Q to quit, and Cut/Copy/Paste/Select-All in the rename field). It's
        // only shown when we flip to `.regular`; harmless to set at launch.
        NSApp.mainMenu = Self.buildMainMenu()

        DebugDiagnostics.log("menu app launched")
    }

    // ⌘Q / Dock Quit / Apple-menu Quit / status-menu Quit / logout all funnel through here. The
    // controller decides: defer while a recording is live or mid-stop, otherwise quit now.
    // (In-flight compression/transcription isn't waited on: it resumes on next launch via the
    // reconciler, and the audio is already on disk.)
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        controller?.terminationReply() ?? .terminateNow
    }

    private static func buildMainMenu() -> NSMenu {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        appMenu.addItem(withTitle: "About Meeting2", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Meeting2", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Meeting2", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editItem.submenu = editMenu
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let windowItem = NSMenuItem()
        mainMenu.addItem(windowItem)
        let windowMenu = NSMenu(title: "Window")
        windowItem.submenu = windowMenu
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        NSApp.windowsMenu = windowMenu

        return mainMenu
    }
}

// Program entry runs on the main thread, which is the main actor's executor — assert that
// so we can touch the @MainActor app objects. `run()` blocks here, keeping `appDelegate`
// (held only weakly by NSApplication.delegate) alive for the process lifetime.
MainActor.assumeIsolated {
    let application = NSApplication.shared
    application.setActivationPolicy(.accessory)  // menu-bar only: no Dock icon
    let appDelegate = AppDelegate()
    application.delegate = appDelegate
    application.run()
}

import AVFoundation
import Foundation

/// Owns the on-disk meeting library. There is no database: a "meeting" is a folder, and
/// the list of meetings is just the result of scanning a directory. This type is the
/// only place that reads or writes `meeting.json`.
///
/// Two principles run through everything below:
///  - **The filesystem is the source of truth.** A meeting's lifecycle state is *derived*
///    from which files exist (`deriveState`), never read back from a status field.
///    `meeting.json` only caches what the files can't say — display name, calendar link,
///    last error — so a crash can't leave the recorded state lying.
///  - **Every write goes through `AtomicJSON`,** so a crash leaves either the old file or
///    the new one, never a half-written one.
///
/// It's an `actor` purely to serialize concurrent access to the same folders (the UI,
/// the recorder finalize, and launch recovery can all touch a folder); nothing here is
/// long-running work being moved off another actor.
public actor MeetingStore {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    /// The entire "load the meeting list" operation: walk the folders and derive each
    /// one's state from its files. No index, no cache to invalidate — re-scanning is
    /// always correct because the disk is authoritative.
    public func scan() throws -> [MeetingSnapshot] {
        // One folder with unreadable metadata must not abort the whole sweep — skip and log
        // it (it can't be processed without readable metadata anyway) so the reconciler keeps
        // making progress on every other meeting. `meetingFolders()` can still throw on a
        // genuine top-level listing failure, which is global, not one-bad-folder.
        try meetingFolders().compactMap { folder in
            do {
                return try snapshot(folder: folder)
            } catch {
                DebugDiagnostics.log(recordingFolder: folder, "scan skipped unreadable folder error=\(error)")
                return nil
            }
        }
    }

    /// Writes the initial `meeting.json` *before* capture begins. This is the hinge of
    /// crash recovery: the durable `endedAt == nil` marker it leaves is exactly what
    /// `recoverInterruptedRecordings` looks for on the next launch. It must be one cheap
    /// atomic write off the audio path.
    ///
    /// If a folder is re-used, we keep its identity (`id`, `displayName`) but reset the
    /// per-recording fields — tracks, audio health, and job state all describe *this*
    /// take, so stale values from a previous one would be misleading.
    public func markRecordingStarted(folder: URL, startedAt: Date = Date()) throws -> MeetingMetadata {
        let metadataURL = Self.metadataURL(in: folder)
        let existing = FileManager.default.fileExists(atPath: metadataURL.path)
            ? try AtomicJSON.read(MeetingMetadata.self, from: metadataURL)
            : nil

        var metadata = existing ?? MeetingMetadata(
            id: stableID(for: folder),
            displayName: "Recording \(stableID(for: folder))",
            startedAt: startedAt
        )
        metadata.startedAt = startedAt
        metadata.endedAt = nil
        metadata.recoveredAt = nil
        metadata.tracks = MeetingTracks()
        metadata.audioHealth = MeetingAudioHealth()
        metadata.jobs = MeetingJobs()

        try AtomicJSON.write(metadata, to: metadataURL)
        DebugDiagnostics.log(recordingFolder: folder, "meeting metadata started id=\(metadata.id)")
        return metadata
    }

    /// The clean-stop counterpart to recovery: called right after `Recorder.stop()`, when
    /// we still hold live RMS/route stats in memory. Stamps `endedAt` and the per-track
    /// health into `meeting.json`. Shares `finalizedMetadata` with the crash path so both
    /// produce identical metadata — the only difference is that here we pass `stats` in
    /// rather than reconstructing what we can from disk.
    public func finalizeCompletedRecording(
        folder: URL,
        stats: RecordingStats?,
        now: Date = Date()
    ) throws -> MeetingMetadata {
        let existing = try readMetadataIfPresent(folder: folder)
        let metadata = try finalizedMetadata(
            for: folder,
            existing: existing,
            now: now,
            statsOverride: stats.map(storedStats(from:)),
            markRecovered: false
        )
        try AtomicJSON.write(metadata, to: Self.metadataURL(in: folder))
        DebugDiagnostics.log(
            recordingFolder: folder,
            "meeting finalized micRMS=\(metadata.tracks.mic.rms ?? -1) " +
            "systemRMS=\(metadata.tracks.system.rms ?? -1) " +
            "micSilent=\(metadata.audioHealth.micSilent.map(String.init) ?? "unknown") " +
            "systemSilent=\(metadata.audioHealth.systemSilent.map(String.init) ?? "unknown")"
        )
        return metadata
    }

    /// Run once at app launch. Any folder whose files say "recording was in progress" but
    /// whose `meeting.json` has no `endedAt` belonged to a process that died mid-record;
    /// this finalizes it from what's on disk and marks it recovered. Safe to run every
    /// launch: it's idempotent (once `endedAt` is set the folder no longer qualifies), and
    /// fault-isolated per folder (see the `catch` below) so one bad recording can't strand
    /// the rest. The cost of a crash is therefore at most the last few seconds of audio.
    public func recoverInterruptedRecordings(now: Date = Date()) throws -> [MeetingRecoveryResult] {
        var results: [MeetingRecoveryResult] = []

        for folder in try meetingFolders() {
            let metadataURL = Self.metadataURL(in: folder)
            var previousState = MeetingDerivedState.incomplete

            do {
                let before = try snapshot(folder: folder)
                previousState = before.state
                guard shouldFinalize(before) else { continue }

                let metadata = try finalizedMetadata(
                    for: folder,
                    existing: before.metadata,
                    now: now,
                    statsOverride: nil,
                    markRecovered: true
                )
                try AtomicJSON.write(metadata, to: metadataURL)
                DebugDiagnostics.log(recordingFolder: folder, "interrupted recording recovered")

                let after = try snapshot(folder: folder)
                results.append(
                    MeetingRecoveryResult(
                        folder: folder,
                        previousState: before.state,
                        recoveredState: after.state,
                        metadataURL: metadataURL,
                        message: "Validated mic/system CAF and marked recording ended"
                    )
                )
            } catch {
                // Launch recovery must be fault-isolated. One corrupt/empty folder
                // should be visible to the user, but it must not strand every later
                // interrupted recording in the scan.
                results.append(
                    MeetingRecoveryResult(
                        folder: folder,
                        previousState: previousState,
                        recoveredState: previousState,
                        metadataURL: metadataURL,
                        message: "Recovery failed: \(error)"
                    )
                )
                DebugDiagnostics.log(recordingFolder: folder, "recovery failed error=\(error)")
            }
        }

        return results
    }

    /// Heals transcription job status that a crash could have left stale. A `transcript.json`
    /// on disk is proof the job finished — file presence is the source of truth — so any
    /// folder that has one but whose recorded status isn't `.done` (the small window between
    /// writing the transcript and marking the job) is reconciled to `.done`. Idempotent and
    /// fault-isolated per folder; run on launch alongside interrupted-recording recovery.
    public func reconcileTranscriptionJobStatus() {
        guard let folders = try? meetingFolders() else { return }
        for folder in folders {
            let transcriptURL = folder.appendingPathComponent("transcript.json")
            guard FileManager.default.fileExists(atPath: transcriptURL.path),
                  var metadata = try? readMetadataIfPresent(folder: folder),
                  metadata.jobs.transcription.status != .done else { continue }
            metadata.jobs.transcription = MeetingJob(status: .done, lastError: nil)
            try? AtomicJSON.write(metadata, to: Self.metadataURL(in: folder))
            DebugDiagnostics.log(recordingFolder: folder, "healed stale transcription status to done")
        }
    }

    public func markRecordingCompressed(folder: URL, now: Date = Date()) throws -> MeetingMetadata {
        let audioURL = folder.appendingPathComponent("audio.m4a")
        let audio = try audioInfo(url: audioURL)
        let existing = try readMetadataIfPresent(folder: folder)
        let startedAt = existing?.startedAt ?? inferredStartDate(folder: folder, audioURLs: [audioURL]) ?? now

        var metadata = existing ?? MeetingMetadata(
            id: stableID(for: folder),
            displayName: "Recording \(stableID(for: folder))",
            startedAt: startedAt,
            endedAt: now
        )
        if metadata.endedAt == nil {
            metadata.endedAt = inferredEndDate(
                startedAt: startedAt,
                audioInfo: [audio],
                audioURLs: [audioURL]
            ) ?? now
        }
        // The two raw tracks now live as the left/right channels of one file. Repoint both
        // channel records at it; their capture stats (alignment, RMS, health, route
        // changes) were measured from the CAFs at finalize and stay as the record of how
        // the audio was captured.
        metadata.tracks.mic.file = "audio.m4a"
        metadata.tracks.system.file = "audio.m4a"

        try AtomicJSON.write(metadata, to: Self.metadataURL(in: folder))
        DebugDiagnostics.log(recordingFolder: folder, "meeting metadata combined into audio.m4a")
        return metadata
    }

    public func markTranscriptionRunning(folder: URL) throws -> MeetingMetadata {
        try updateTranscriptionJob(folder: folder, status: .running, lastError: nil)
    }

    public func markTranscriptionCompleted(folder: URL) throws -> MeetingMetadata {
        try updateTranscriptionJob(folder: folder, status: .done, lastError: nil)
    }

    public func markTranscriptionFailed(folder: URL, error: Error) throws -> MeetingMetadata {
        try updateTranscriptionJob(folder: folder, status: .failed, lastError: String(describing: error))
    }

    /// Renames a recording: edits only `displayName` in `meeting.json`. The folder is left
    /// alone — its timestamp prefix is the stable identity and the slug is cosmetic — so a
    /// rename never moves a directory whose files may be open.
    public func setDisplayName(folder: URL, _ displayName: String) throws {
        guard var metadata = try readMetadataIfPresent(folder: folder) else {
            throw CaptureError.invalidState("No meeting.json to rename: \(folder.path)")
        }
        metadata.displayName = displayName
        try AtomicJSON.write(metadata, to: Self.metadataURL(in: folder))
        DebugDiagnostics.log(recordingFolder: folder, "renamed to \(displayName)")
    }

    /// Prepares a recording to be transcribed again. Deletes the transcript files **first** —
    /// their absence is what makes `TranscriptionJob.needsWork` true — then resets the job
    /// status to pending. Ordering is the crash contract: if it dies between the two, the
    /// missing `transcript.json` already requeues it on the next sweep. Idempotent.
    public func clearTranscript(folder: URL) throws {
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: folder.appendingPathComponent("transcript.json"))
        try? fileManager.removeItem(at: folder.appendingPathComponent("transcript.md"))
        if var metadata = try readMetadataIfPresent(folder: folder) {
            metadata.jobs.transcription = MeetingJob(status: .pending, lastError: nil)
            try AtomicJSON.write(metadata, to: Self.metadataURL(in: folder))
        }
        DebugDiagnostics.log(recordingFolder: folder, "transcript cleared for re-transcribe")
    }

    public static func metadataURL(in folder: URL) -> URL {
        folder.appendingPathComponent("meeting.json")
    }

    private func shouldFinalize(_ snapshot: MeetingSnapshot) -> Bool {
        // On app launch there is, by definition, no live in-memory session for the
        // previous process. Any folder with both CAFs and no endedAt is recoverable.
        snapshot.hasMicCAF &&
            snapshot.hasSystemCAF &&
            (snapshot.metadata?.endedAt == nil || snapshot.state == .interrupted)
    }

    /// Enumerates meeting folders under `root`. Handles both shapes the callers use: when
    /// `root` is itself a meeting folder (the recovery tool can be pointed at a single
    /// recording) we return just it; otherwise we list its immediate subdirectories.
    /// Sorted by name so the timestamp-prefixed folders come out in chronological order.
    private func meetingFolders() throws -> [URL] {
        if try isMeetingFolder(root) {
            return [root]
        }

        guard FileManager.default.fileExists(atPath: root.path) else {
            return []
        }

        let children = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        return try children
            .filter { url in
                let values = try url.resourceValues(forKeys: [.isDirectoryKey])
                return values.isDirectory == true
            }
            .filter { try isMeetingFolder($0) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// A folder counts as a meeting if it holds any of the known artifacts. We detect by
    /// content, not by name pattern, so a folder is recognized at every lifecycle stage —
    /// even a crash that produced only a raw CAF and no `meeting.json` yet — and unrelated
    /// directories under `root` are ignored.
    private func isMeetingFolder(_ folder: URL) throws -> Bool {
        let fileManager = FileManager.default
        let markers = [
            "meeting.json",
            "mic.caf",
            "system.caf",
            "audio.m4a",
            "transcript.json"
        ]

        return markers.contains { marker in
            fileManager.fileExists(atPath: folder.appendingPathComponent(marker).path)
        }
    }

    public func snapshot(folder: URL) throws -> MeetingSnapshot {
        let fileManager = FileManager.default
        let metadata = try readMetadataIfPresent(folder: folder)

        let hasMicCAF = fileManager.fileExists(atPath: folder.appendingPathComponent("mic.caf").path)
        let hasSystemCAF = fileManager.fileExists(atPath: folder.appendingPathComponent("system.caf").path)
        let hasAudioM4A = fileManager.fileExists(atPath: folder.appendingPathComponent("audio.m4a").path)
        let hasTranscript = fileManager.fileExists(atPath: folder.appendingPathComponent("transcript.json").path)

        return MeetingSnapshot(
            folder: folder,
            state: deriveState(
                metadata: metadata,
                hasMicCAF: hasMicCAF,
                hasSystemCAF: hasSystemCAF,
                hasAudioM4A: hasAudioM4A,
                hasTranscript: hasTranscript
            ),
            metadata: metadata,
            hasMicCAF: hasMicCAF,
            hasSystemCAF: hasSystemCAF,
            hasAudioM4A: hasAudioM4A,
            hasTranscript: hasTranscript
        )
    }

    /// Maps "what's on disk" to a lifecycle state. This is the function that makes the
    /// filesystem the source of truth, so the order of the checks is the contract:
    ///
    ///  - a transcript present ⇒ `.transcribed` (the furthest stage; nothing supersedes it);
    ///  - both raw CAFs present ⇒ recording happened, but CAFs mean compression hasn't run
    ///    yet, so it's either still in progress (`.interrupted`, if `endedAt` was never
    ///    written — the crash signature) or cleanly `.recorded`;
    ///  - the combined `audio.m4a` present ⇒ `.recorded` (capture + compression done);
    ///  - only a single raw CAF present ⇒ `.incomplete` (one track is missing — partial/odd);
    ///  - no audio at all ⇒ `.recording` if metadata exists with no `endedAt` (the window
    ///    after `markRecordingStarted` before the first sample lands), else `.recorded`.
    ///
    /// `endedAt` is only consulted to disambiguate the two "both CAFs" cases; everything
    /// else is decided purely by file presence, which is why a stale/partial JSON can't
    /// produce a wrong state.
    private func deriveState(
        metadata: MeetingMetadata?,
        hasMicCAF: Bool,
        hasSystemCAF: Bool,
        hasAudioM4A: Bool,
        hasTranscript: Bool
    ) -> MeetingDerivedState {
        if hasTranscript {
            return .transcribed
        }

        if hasMicCAF && hasSystemCAF {
            return metadata?.endedAt == nil ? .interrupted : .recorded
        }

        if hasAudioM4A {
            return .recorded
        }

        if hasMicCAF || hasSystemCAF {
            return .incomplete
        }

        return metadata?.endedAt == nil ? .recording : .recorded
    }

    /// Builds the finalized `meeting.json` for a completed recording, shared by the clean
    /// stop and crash-recovery paths. The defining constraint: on recovery there is no live
    /// session, so every field has to be reconstructable from what's on disk —
    ///  - `startedAt`: prefer the existing value, else parse it from the folder's timestamp
    ///    name, else fall back to the file creation date, else `now`;
    ///  - `endedAt`: prefer existing, else `startedAt + longest track duration`, else `now`;
    ///  - track stats: from in-memory `statsOverride` when finalizing a live stop, otherwise
    ///    from a `stats.json` left by the harness if present (a recovered crash usually has
    ///    neither, so health is left *unknown* rather than guessed — see `MeetingAudioHealth`).
    ///
    /// `markRecovered` stamps `recoveredAt` only when this was genuinely an interrupted
    /// recording (`existing?.endedAt == nil`), so re-running recovery never relabels a
    /// meeting that was already finalized.
    private func finalizedMetadata(
        for folder: URL,
        existing: MeetingMetadata?,
        now: Date,
        statsOverride: HarnessRecordingStats?,
        markRecovered: Bool
    ) throws -> MeetingMetadata {
        let micURL = folder.appendingPathComponent("mic.caf")
        let systemURL = folder.appendingPathComponent("system.caf")
        let micAudio = try audioInfo(url: micURL)
        let systemAudio = try audioInfo(url: systemURL)
        let stats: HarnessRecordingStats?
        if let statsOverride {
            stats = statsOverride
        } else {
            stats = try readHarnessStatsIfPresent(folder: folder)
        }

        let startedAt = existing?.startedAt ?? inferredStartDate(folder: folder, audioURLs: [micURL, systemURL]) ?? now
        let endedAt = existing?.endedAt ?? inferredEndDate(
            startedAt: startedAt,
            audioInfo: [micAudio, systemAudio],
            audioURLs: [micURL, systemURL]
        ) ?? now

        var metadata = existing ?? MeetingMetadata(
            id: stableID(for: folder),
            displayName: "Recording \(stableID(for: folder))",
            startedAt: startedAt
        )

        metadata.endedAt = endedAt
        metadata.tracks = MeetingTracks(
            mic: trackMetadata(
                file: "mic.caf",
                audioInfo: micAudio,
                stats: stats?.mic,
                startOffsetSeconds: offsets(from: stats).mic
            ),
            system: trackMetadata(
                file: "system.caf",
                audioInfo: systemAudio,
                stats: stats?.system,
                startOffsetSeconds: offsets(from: stats).system
            )
        )
        metadata.audioHealth = MeetingAudioHealth(
            micSilent: stats?.mic.isSilent,
            systemSilent: stats?.system.isSilent
        )
        metadata.jobs.transcription.status = FileManager.default.fileExists(
            atPath: folder.appendingPathComponent("transcript.json").path
        ) ? .done : .pending
        metadata.recoveredAt = markRecovered && existing?.endedAt == nil ? now : existing?.recoveredAt

        return metadata
    }

    private func readMetadataIfPresent(folder: URL) throws -> MeetingMetadata? {
        let metadataURL = Self.metadataURL(in: folder)
        guard FileManager.default.fileExists(atPath: metadataURL.path) else {
            return nil
        }

        return try AtomicJSON.read(MeetingMetadata.self, from: metadataURL)
    }

    private func updateTranscriptionJob(
        folder: URL,
        status: MeetingJobStatus,
        lastError: String?
    ) throws -> MeetingMetadata {
        guard var metadata = try readMetadataIfPresent(folder: folder) else {
            throw CaptureError.invalidState("Missing meeting.json before transcription update: \(folder.path)")
        }

        metadata.jobs.transcription = MeetingJob(status: status, lastError: lastError)
        try AtomicJSON.write(metadata, to: Self.metadataURL(in: folder))
        DebugDiagnostics.log(
            recordingFolder: folder,
            "transcription job status=\(status.rawValue) error=\(lastError ?? "none")"
        )
        return metadata
    }

    private func trackMetadata(
        file: String,
        audioInfo: AudioFileInfo,
        stats: HarnessTrackStats?,
        startOffsetSeconds: Double
    ) -> MeetingTrackMetadata {
        MeetingTrackMetadata(
            file: file,
            startOffsetSeconds: startOffsetSeconds,
            durationSeconds: audioInfo.durationSeconds,
            rms: stats?.rms,
            peak: stats?.peak,
            droppedBytes: stats?.droppedBytes,
            routeChanges: stats?.routeChanges
        )
    }

    /// Turns the measured "mic started N ms after system" delta into a per-track start
    /// offset. The two tracks never start at the same instant (the system tap spins up
    /// before the mic engine), so we express the offset relative to whichever started
    /// first: the later track carries its lead in seconds, the earlier track is 0. A
    /// consumer aligns the recordings by shifting the offset track forward. Missing delta
    /// (e.g. a recovered crash with no stats) means we don't know — so both are 0.
    private func offsets(from stats: HarnessRecordingStats?) -> (mic: Double, system: Double) {
        guard let deltaMS = stats?.micMinusSystemStartDeltaMS else {
            return (0, 0)
        }

        if deltaMS >= 0 {
            return (deltaMS / 1_000, 0)
        } else {
            return (0, abs(deltaMS) / 1_000)
        }
    }

    /// Reads a CAF's duration — and doubles as the "is this file actually usable" check
    /// during recovery. Opening with `AVAudioFile` is also the moment of truth for crash
    /// safety: it only works if a CAF that was being written when the process was killed
    /// can still report its frame count. A zero-length/unreadable file throws here, which
    /// the per-folder `catch` in `recoverInterruptedRecordings` turns into a visible
    /// failure result rather than a usable meeting — we never fabricate a duration for a
    /// file we couldn't read.
    private func audioInfo(url: URL) throws -> AudioFileInfo {
        let file = try AVAudioFile(forReading: url)
        let sampleRate = file.processingFormat.sampleRate
        let duration = sampleRate > 0 ? Double(file.length) / sampleRate : 0

        guard file.length > 0, duration > 0 else {
            throw CaptureError.invalidState("Recovered audio file is empty: \(url.path)")
        }

        return AudioFileInfo(durationSeconds: duration)
    }

    /// The meeting's permanent identity. Folders are named `"<timestamp-id> — <slug>"`,
    /// where the slug is a cosmetic, human-readable label (e.g. the calendar title) that
    /// may be re-derived or stripped. The id is only the stable timestamp prefix, so
    /// renaming the slug — or losing it — never changes a meeting's identity. The slug
    /// lives in `displayName`, not here.
    private func stableID(for folder: URL) -> String {
        let folderName = folder.lastPathComponent
        guard let separator = folderName.range(of: " — ") else {
            return folderName
        }
        return String(folderName[..<separator.lowerBound])
    }

    private func inferredStartDate(folder: URL, audioURLs: [URL]) -> Date? {
        if let date = parseStartDate(from: folder.lastPathComponent) {
            return date
        }

        let dates = audioURLs.compactMap { url in
            try? url.resourceValues(forKeys: [.creationDateKey]).creationDate
        }
        return dates.min()
    }

    private func parseStartDate(from folderName: String) -> Date? {
        var candidate = folderName
        if candidate.hasPrefix("harness-") {
            candidate = String(candidate.dropFirst("harness-".count))
        }
        if let separator = candidate.range(of: " — ") {
            candidate = String(candidate[..<separator.lowerBound])
        } else if candidate.count >= 19 {
            candidate = String(candidate.prefix(19))
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH-mm-ss"
        if let date = formatter.date(from: candidate) {
            return date
        }

        return nil
    }

    private func inferredEndDate(
        startedAt: Date,
        audioInfo: [AudioFileInfo],
        audioURLs: [URL]
    ) -> Date? {
        if let duration = audioInfo.map(\.durationSeconds).max(), duration > 0 {
            return startedAt.addingTimeInterval(duration)
        }

        let dates = audioURLs.compactMap { url in
            try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        }
        return dates.max()
    }

    private func readHarnessStatsIfPresent(folder: URL) throws -> HarnessRecordingStats? {
        let url = folder.appendingPathComponent("stats.json")
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }

        return try AtomicJSON.read(HarnessRecordingStats.self, from: url)
    }

    private func storedStats(from stats: RecordingStats) -> HarnessRecordingStats {
        let delta: Double?
        if let micHost = stats.mic.hostStartTime, let systemHost = stats.system.hostStartTime {
            delta = HostClock.milliseconds(from: systemHost, to: micHost)
        } else {
            delta = nil
        }

        return HarnessRecordingStats(
            mic: HarnessTrackStats(stats.mic),
            system: HarnessTrackStats(stats.system),
            micMinusSystemStartDeltaMS: delta
        )
    }
}

private struct AudioFileInfo: Equatable {
    let durationSeconds: Double
}

// The on-disk shape of the harness `stats.json`. It is intentionally a *private mirror*
// of the in-memory `RecordingStats`/`TrackStats`, not those types directly: the JSON is a
// test-tool artifact whose layout we want to pin independently of the live capture types,
// so the public API can evolve without silently changing a file format (or vice versa).
// The store reads it when present and shrugs when it isn't.
private struct HarnessRecordingStats: Codable {
    let mic: HarnessTrackStats
    let system: HarnessTrackStats
    let micMinusSystemStartDeltaMS: Double?
}

private struct HarnessTrackStats: Codable {
    let rms: Double
    let peak: Float
    let droppedBytes: Int
    let routeChanges: Int

    init(
        rms: Double,
        peak: Float,
        droppedBytes: Int,
        routeChanges: Int
    ) {
        self.rms = rms
        self.peak = peak
        self.droppedBytes = droppedBytes
        self.routeChanges = routeChanges
    }

    init(_ stats: TrackStats) {
        self.init(
            rms: stats.rms,
            peak: stats.peak,
            droppedBytes: stats.droppedBytes,
            routeChanges: stats.routeChanges
        )
    }

    var isSilent: Bool {
        rms < 0.000_001 && peak < 0.000_01
    }
}

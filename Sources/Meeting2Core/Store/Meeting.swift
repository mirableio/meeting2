import Foundation

// This file is the disk contract, not just an internal DTO. Keep it provider- and
// UI-neutral: the recorder, recovery scanner, compression, transcription, and UI
// all meet at `meeting.json`, so fields here should describe durable facts about
// the recording rather than the needs of whichever feature is being built today.
/// A meeting's lifecycle stage. This is a *derived* view computed from which files exist
/// (`MeetingStore.deriveState`), never a stored field — so it can't disagree with reality.
///  - `recording`: metadata exists, capture in progress, no audio finalized yet.
///  - `interrupted`: raw audio present but never marked ended — a process died mid-record;
///    this is the state launch recovery looks for.
///  - `recorded`: capture finished (raw or compressed), ready for transcription.
///  - `transcribed`: a transcript exists — the terminal stage.
///  - `incomplete`: only some audio is present (a track is missing) — partial/unusual.
public enum MeetingDerivedState: String, Codable {
    case recording
    case interrupted
    case recorded
    case transcribed
    case incomplete
}

public enum MeetingJobStatus: String, Codable {
    case pending
    case running
    case done
    case failed
}

public struct MeetingJob: Codable, Equatable {
    public var status: MeetingJobStatus
    public var lastError: String?

    public init(status: MeetingJobStatus = .pending, lastError: String? = nil) {
        self.status = status
        self.lastError = lastError
    }
}

/// Tracks only the jobs whose outcome can't be re-derived from the files. Transcription
/// is here because its *failure reason* ("rate limited") isn't recoverable by looking at
/// the folder. Compression deliberately has no entry: its state is pure file presence
/// (`.caf` gone, `.m4a` present), so storing it would just be a second source of truth
/// that could drift. Add a job here only when the same is true of it.
public struct MeetingJobs: Codable, Equatable {
    public var transcription: MeetingJob

    public init(transcription: MeetingJob = MeetingJob()) {
        self.transcription = transcription
    }
}

public struct MeetingTrackMetadata: Codable, Equatable {
    public var file: String
    public var startOffsetSeconds: Double
    public var durationSeconds: Double?
    public var rms: Double?
    public var peak: Float?
    public var droppedBytes: Int?
    public var routeChanges: Int?

    public init(
        file: String,
        startOffsetSeconds: Double = 0,
        durationSeconds: Double? = nil,
        rms: Double? = nil,
        peak: Float? = nil,
        droppedBytes: Int? = nil,
        routeChanges: Int? = nil
    ) {
        self.file = file
        self.startOffsetSeconds = startOffsetSeconds
        self.durationSeconds = durationSeconds
        self.rms = rms
        self.peak = peak
        self.droppedBytes = droppedBytes
        self.routeChanges = routeChanges
    }
}

public struct MeetingTracks: Codable, Equatable {
    public var mic: MeetingTrackMetadata
    public var system: MeetingTrackMetadata

    public init(
        mic: MeetingTrackMetadata = MeetingTrackMetadata(file: "mic.caf"),
        system: MeetingTrackMetadata = MeetingTrackMetadata(file: "system.caf")
    ) {
        self.mic = mic
        self.system = system
    }
}

public struct MeetingAudioHealth: Codable, Equatable {
    public var micSilent: Bool?
    public var systemSilent: Bool?

    public init(micSilent: Bool? = nil, systemSilent: Bool? = nil) {
        // Unknown is better than false for recovered crash fixtures: if the app was
        // killed before RMS stats were flushed, pretending the track was healthy
        // would hide exactly the silent-recording class M2 is meant to surface.
        self.micSilent = micSilent
        self.systemSilent = systemSilent
    }
}

public struct MeetingSource: Codable, Equatable {
    public var micOwnerBundleId: String?

    public init(micOwnerBundleId: String? = nil) {
        self.micOwnerBundleId = micOwnerBundleId
    }
}

public struct MeetingMetadata: Codable, Equatable {
    public var schemaVersion: Int
    public var id: String
    public var displayName: String
    public var startedAt: Date
    public var endedAt: Date?
    public var tracks: MeetingTracks
    public var source: MeetingSource
    public var audioHealth: MeetingAudioHealth
    public var jobs: MeetingJobs
    public var recoveredAt: Date?

    public init(
        schemaVersion: Int = 1,
        id: String,
        displayName: String,
        startedAt: Date,
        endedAt: Date? = nil,
        tracks: MeetingTracks = MeetingTracks(),
        source: MeetingSource = MeetingSource(),
        audioHealth: MeetingAudioHealth = MeetingAudioHealth(),
        jobs: MeetingJobs = MeetingJobs(),
        recoveredAt: Date? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.displayName = displayName
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.tracks = tracks
        self.source = source
        self.audioHealth = audioHealth
        self.jobs = jobs
        self.recoveredAt = recoveredAt
    }
}

public struct MeetingSnapshot: Equatable {
    public let folder: URL
    public let state: MeetingDerivedState
    public let metadata: MeetingMetadata?
    public let hasMicCAF: Bool
    public let hasSystemCAF: Bool
    public let hasAudioM4A: Bool
    public let hasTranscript: Bool
}

public struct MeetingRecoveryResult: Equatable {
    public let folder: URL
    public let previousState: MeetingDerivedState
    public let recoveredState: MeetingDerivedState
    public let metadataURL: URL
    public let message: String

    public var didRecover: Bool {
        previousState != recoveredState && recoveredState == .recorded
    }
}

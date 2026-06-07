import Foundation

/// A health summary for one recorded track, produced when recording stops.
/// It answers the questions that matter after the fact: did we actually capture
/// sound (`rms`/`peak`, see `isSilent`), did we lose any samples because the disk
/// couldn't keep up (`droppedBytes`), did the audio device change underneath us
/// (`routeChanges`), and when did the first sample arrive (`hostStartTime`, used to
/// line the two tracks up against each other).
public struct TrackStats {
    public let url: URL
    public let rms: Double
    public let peak: Float
    public let droppedBytes: Int
    public let routeChanges: Int
    /// The system clock time of the first captured sample, in mach host-time units.
    /// `nil` means no audio was ever received. Comparing the mic's value to the
    /// system track's gives the offset needed to align the two files.
    public let hostStartTime: UInt64?
    /// Recent loudness (fast-attack / slow-release), for live UI like the breathing
    /// menu-bar indicator. Not persisted — purely a live read while recording.
    public let recentLevel: Float

    init(
        url: URL,
        rms: Double,
        peak: Float,
        droppedBytes: Int,
        routeChanges: Int = 0,
        hostStartTime: UInt64? = nil,
        recentLevel: Float = 0
    ) {
        self.url = url
        self.rms = rms
        self.peak = peak
        self.droppedBytes = droppedBytes
        self.routeChanges = routeChanges
        self.hostStartTime = hostStartTime
        self.recentLevel = recentLevel
    }

    /// True if the track is effectively pure silence. We require *both* the average
    /// level and the single loudest sample to be near zero so that one stray click
    /// doesn't mask an otherwise-dead recording. The thresholds are just "below the
    /// noise floor of real capture" — a genuinely recorded room is orders of magnitude
    /// louder than this.
    public var isSilent: Bool {
        rms < 0.000_001 && peak < 0.000_01
    }
}

/// The pair of `TrackStats` for one finished recording (your mic and the system audio).
public struct RecordingStats {
    public let mic: TrackStats
    public let system: TrackStats
}

/// Records one meeting: the microphone and the system audio, into two files in `folder`.
///
/// This app only ever records one meeting at a time, so this type is the single owner
/// of both tracks. Making that explicit here keeps the later "detect a meeting / show
/// the UI" code from ever starting two overlapping sessions by accident.
@available(macOS 14.2, *)
public final class DualTrackRecorder {
    private let folder: URL
    private let mic: MicCapture
    private var system: SystemTapCapture?
    private var isRunning = false

    public init(folder: URL) {
        self.folder = folder
        self.mic = MicCapture(outputURL: folder.appendingPathComponent("mic.caf"))
    }

    public func start() throws {
        guard !isRunning else { return }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        DebugDiagnostics.log(recordingFolder: folder, "recorder start requested")

        // Start the system tap before the mic. If the harder permission/API path
        // fails, we leave no growing microphone recording behind. Once both tracks
        // start, stop() unwinds in the opposite order and returns final RMS stats.
        let systemTap = try SystemTapCapture(outputURL: folder.appendingPathComponent("system.caf"))
        do {
            try systemTap.start()
            DebugDiagnostics.log(recordingFolder: folder, "system tap started")
        } catch {
            DebugDiagnostics.log(recordingFolder: folder, "system tap start failed error=\(error)")
            throw error
        }

        do {
            try mic.start()
            DebugDiagnostics.log(recordingFolder: folder, "microphone started")
            isRunning = true
            system = systemTap
        } catch {
            systemTap.stop()
            mic.stop()
            DebugDiagnostics.log(recordingFolder: folder, "microphone start failed error=\(error)")
            throw error
        }
    }

    public func stop() -> RecordingStats {
        guard isRunning else {
            let empty = TrackStats(url: folder, rms: 0, peak: 0, droppedBytes: 0)
            return RecordingStats(mic: empty, system: empty)
        }

        mic.stop()

        let systemStats: TrackStats
        if let systemTap = system {
            systemTap.stop()
            systemStats = systemTap.stats
        } else {
            systemStats = TrackStats(url: folder.appendingPathComponent("system.caf"), rms: 0, peak: 0, droppedBytes: 0)
        }

        let stats = RecordingStats(mic: mic.stats, system: systemStats)
        system = nil
        isRunning = false
        DebugDiagnostics.log(
            recordingFolder: folder,
            "recorder stopped micRMS=\(stats.mic.rms) micPeak=\(stats.mic.peak) " +
            "systemRMS=\(stats.system.rms) systemPeak=\(stats.system.peak) " +
            "systemDropped=\(stats.system.droppedBytes) routeChanges=\(stats.system.routeChanges)"
        )
        return stats
    }

    /// A cheap, read-only health snapshot for UI diagnostics while recording is still
    /// running. This deliberately reuses the same RMS/host-time counters as final
    /// metadata; the menu app should observe capture health, not invent a second
    /// definition of "silent" that can disagree with meeting.json.
    public var currentStats: RecordingStats {
        guard isRunning else {
            let empty = TrackStats(url: folder, rms: 0, peak: 0, droppedBytes: 0)
            return RecordingStats(mic: empty, system: empty)
        }

        let systemStats: TrackStats
        if let systemTap = system {
            systemStats = systemTap.stats
        } else {
            systemStats = TrackStats(url: folder.appendingPathComponent("system.caf"), rms: 0, peak: 0, droppedBytes: 0)
        }

        return RecordingStats(mic: mic.stats, system: systemStats)
    }
}

import AVFoundation
import Foundation

public enum MeetingCompressionStatus: String, Codable, Equatable {
    case missingSource
    case alreadyCompressed
    case compressed
}

public struct MeetingCompressionResult: Equatable {
    public let folder: URL
    public let status: MeetingCompressionStatus
    public let audioURL: URL
    public let metadataURL: URL

    public var didCompress: Bool {
        status == .compressed
    }
}

public struct CompressionJob {
    private let audioBuilder: CombinedAudioBuilder

    public init(audioBuilder: CombinedAudioBuilder = CombinedAudioBuilder()) {
        self.audioBuilder = audioBuilder
    }

    public func needsWork(_ snapshot: MeetingSnapshot) -> Bool {
        // Compression is file-derived: a finalized recording whose raw CAFs are still
        // present needs work. Do not compress `.interrupted` folders; recovery must first
        // prove those CAFs are readable and write `endedAt`, otherwise we could delete raw
        // crash evidence before the recovery path has done its job.
        snapshot.metadata?.endedAt != nil && (snapshot.hasMicCAF || snapshot.hasSystemCAF)
    }

    public func runPending(
        in store: MeetingStore
    ) async throws -> (results: [MeetingCompressionResult], failures: [PostRecordingFailure]) {
        var results: [MeetingCompressionResult] = []
        var failures: [PostRecordingFailure] = []

        for snapshot in try await store.scan() where needsWork(snapshot) {
            do {
                results.append(try await perform(folder: snapshot.folder, store: store))
            } catch {
                // Isolate per item — one bad recording must not abort the batch (mirrors the
                // app's PostRecordingPipeline). The raw CAFs are preserved for a later retry.
                failures.append(PostRecordingFailure(folder: snapshot.folder, message: String(describing: error)))
            }
        }

        return (results, failures)
    }

    public func perform(folder: URL, store: MeetingStore) async throws -> MeetingCompressionResult {
        let snapshot = try await store.snapshot(folder: folder)
        let micCAF = folder.appendingPathComponent("mic.caf")
        let systemCAF = folder.appendingPathComponent("system.caf")
        let audioURL = folder.appendingPathComponent("audio.m4a")

        let status = try ensureCombinedAudio(
            micCAF: micCAF,
            systemCAF: systemCAF,
            audioURL: audioURL,
            metadata: snapshot.metadata
        )

        // Ordering is the crash-safety contract: retain each raw track as a kept `.m4a` and
        // write metadata FIRST, then delete the raw CAFs. If we die anywhere before the CAFs
        // are gone, the folder still has CAFs, so `needsWork` re-triggers and the next pass
        // heals it — the folder can never end up compressed-but-with-stale-metadata. Both
        // the combined build and the per-track retention are idempotent, so a re-run is safe.
        // (Nothing to do for a missing source: there are no CAFs and no combined file.)
        if status != .missingSource {
            try retainSourceTracksAsM4A(micCAF: micCAF, systemCAF: systemCAF)
            _ = try await store.markRecordingCompressed(folder: folder)
            let fileManager = FileManager.default
            try? fileManager.removeItem(at: micCAF)
            try? fileManager.removeItem(at: systemCAF)
        }

        DebugDiagnostics.log(recordingFolder: folder, "compression finished status=\(status.rawValue)")

        return MeetingCompressionResult(
            folder: folder,
            status: status,
            audioURL: audioURL,
            metadataURL: MeetingStore.metadataURL(in: folder)
        )
    }

    /// Makes sure `audio.m4a` exists and validates, without touching the CAFs (the caller
    /// deletes those only after metadata is written — see `perform`). Idempotent: an
    /// already-present combined file is just re-validated.
    private func ensureCombinedAudio(
        micCAF: URL,
        systemCAF: URL,
        audioURL: URL,
        metadata: MeetingMetadata?
    ) throws -> MeetingCompressionStatus {
        let fileManager = FileManager.default

        if fileManager.fileExists(atPath: audioURL.path) {
            try Self.validateAudioFile(audioURL)
            return .alreadyCompressed
        }

        guard fileManager.fileExists(atPath: micCAF.path) || fileManager.fileExists(atPath: systemCAF.path) else {
            return .missingSource
        }

        // Alignment was measured at finalize and stored per channel; bake it into the
        // merged file so transcription needs no offsets. Missing metadata ⇒ no skew known.
        let micOffset = metadata?.tracks.mic.startOffsetSeconds ?? 0
        let systemOffset = metadata?.tracks.system.startOffsetSeconds ?? 0

        // On a loudspeaker recording the mic already contains the whole conversation and the
        // system track is just a delayed duplicate (echo), so the combined file is built
        // from the mic alone. Anything else — headphones, external, or unknown route — keeps
        // both tracks. The raw system audio is retained as system.m4a regardless.
        let includeSystemTrack = metadata?.outputRoute?.isLoudspeaker != true

        let temporaryURL = audioURL.deletingLastPathComponent()
            .appendingPathComponent("audio.\(UUID().uuidString).m4a")
        do {
            try audioBuilder.build(
                micURL: micCAF,
                systemURL: systemCAF,
                destinationURL: temporaryURL,
                micOffsetSeconds: micOffset,
                systemOffsetSeconds: systemOffset,
                micPeak: metadata?.tracks.mic.peak,
                systemPeak: metadata?.tracks.system.peak,
                includeSystemTrack: includeSystemTrack
            )
            try Self.validateAudioFile(temporaryURL)
            try fileManager.moveItem(at: temporaryURL, to: audioURL)
            return .compressed
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            throw error
        }
    }

    /// Re-encodes each present raw CAF to a kept, compact `mic.m4a` / `system.m4a` alongside
    /// the combined file — a safety net so the individual tracks are always recoverable even
    /// though one of them may be dropped from the route-aware `audio.m4a`. Idempotent: an
    /// already-encoded track is left as-is, and a missing CAF (single-track recording) is
    /// simply skipped.
    private func retainSourceTracksAsM4A(micCAF: URL, systemCAF: URL) throws {
        let folder = micCAF.deletingLastPathComponent()
        try retainTrack(caf: micCAF, m4a: folder.appendingPathComponent("mic.m4a"))
        try retainTrack(caf: systemCAF, m4a: folder.appendingPathComponent("system.m4a"))
    }

    private func retainTrack(caf: URL, m4a: URL) throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: caf.path) else { return }
        if fileManager.fileExists(atPath: m4a.path) {
            // A prior pass already retained it; trust the validated artifact and move on.
            if (try? Self.validateAudioFile(m4a)) != nil { return }
            try? fileManager.removeItem(at: m4a)
        }

        let temporaryURL = m4a.deletingLastPathComponent()
            .appendingPathComponent("\(m4a.deletingPathExtension().lastPathComponent).\(UUID().uuidString).m4a")
        do {
            try Self.encodeToM4A(source: caf, destination: temporaryURL)
            try Self.validateAudioFile(temporaryURL)
            try fileManager.moveItem(at: temporaryURL, to: m4a)
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            throw error
        }
    }

    /// Streams a mono CAF into an AAC `.m4a`, preserving its channel count and sample rate.
    private static func encodeToM4A(source: URL, destination: URL) throws {
        let input = try AVAudioFile(forReading: source)
        let format = input.processingFormat
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: Int(format.channelCount),
            AVEncoderBitRateKey: 96_000
        ]
        let output = try AVAudioFile(
            forWriting: destination,
            settings: settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )

        let capacity: AVAudioFrameCount = 65_536
        while input.framePosition < input.length {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
                throw CaptureError.conversionFailed("Could not allocate track-retention buffer")
            }
            try input.read(into: buffer)
            if buffer.frameLength == 0 { break }
            try output.write(from: buffer)
        }
    }

    private static func validateAudioFile(_ url: URL) throws {
        let file = try AVAudioFile(forReading: url)
        let sampleRate = file.processingFormat.sampleRate
        let duration = sampleRate > 0 ? Double(file.length) / sampleRate : 0
        guard file.length > 0, duration > 0 else {
            throw CaptureError.conversionFailed("Compressed audio file is empty: \(url.path)")
        }
    }
}

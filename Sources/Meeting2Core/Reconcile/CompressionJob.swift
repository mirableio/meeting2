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

        // Ordering is the crash-safety contract: write metadata pointing at audio.m4a
        // FIRST, then delete the raw CAFs. If we die anywhere before the CAFs are gone, the
        // folder still has CAFs, so `needsWork` re-triggers and the next pass heals it — the
        // folder can never end up compressed-but-with-stale-metadata. (Nothing to do for a
        // missing source: there are no CAFs and no combined file to record.)
        if status != .missingSource {
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

        let temporaryURL = audioURL.deletingLastPathComponent()
            .appendingPathComponent("audio.\(UUID().uuidString).m4a")
        do {
            try audioBuilder.build(
                micURL: micCAF,
                systemURL: systemCAF,
                destinationURL: temporaryURL,
                micOffsetSeconds: micOffset,
                systemOffsetSeconds: systemOffset
            )
            try Self.validateAudioFile(temporaryURL)
            try fileManager.moveItem(at: temporaryURL, to: audioURL)
            return .compressed
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            throw error
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

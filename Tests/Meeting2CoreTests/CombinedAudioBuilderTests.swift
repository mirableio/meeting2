import AVFoundation
@testable import Meeting2Core
import XCTest

/// Covers the merge-time audio fixes: inter-track drift correction (so the two channels stay
/// time-aligned) and peak normalization (so capture above 1.0 doesn't clip).
final class CombinedAudioBuilderTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("Meeting2BuilderTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let dir { try? FileManager.default.removeItem(at: dir) }
    }

    func testDriftCorrectionAlignsTheTwoChannels() throws {
        // mic and system carry the *same* one-second chirp, but the system clock drifted: it holds
        // more samples for the same audio (48 384 vs 48 000 ≈ +0.8 %). Without correction the
        // shared content walks apart toward the end; the builder should resample system onto the
        // mic timeline so the two output channels line up everywhere.
        let micURL = dir.appendingPathComponent("mic.caf")
        let systemURL = dir.appendingPathComponent("system.caf")
        try writeChirpCAF(micURL, frames: 48_000)
        try writeChirpCAF(systemURL, frames: 48_384)
        let destination = dir.appendingPathComponent("audio.m4a")

        try CombinedAudioBuilder().build(
            micURL: micURL,
            systemURL: systemURL,
            destinationURL: destination,
            micOffsetSeconds: 0,
            systemOffsetSeconds: 0
        )

        let (mic, system) = try decodeStereo(destination)
        let n = min(mic.count, system.count)
        // Sample a window late in the file (70 %), where uncorrected drift would be ~270 samples.
        let start = Int(Double(n) * 0.7)
        let window = 8_192
        XCTAssertGreaterThan(n, start + window)
        let lag = bestLag(
            Array(mic[start..<start + window]),
            Array(system[start..<start + window]),
            maxLag: 600
        )
        XCTAssertLessThanOrEqual(abs(lag), 40, "channels still drifted by \(lag) samples after correction")
    }

    func testNormalizationBringsClippingPeakUnderUnity() throws {
        // mic captured hot (peak 1.2 — clips on playback); system normal. The merge should apply a
        // flat gain so the output peaks comfortably under 1.0.
        let micURL = dir.appendingPathComponent("mic.caf")
        let systemURL = dir.appendingPathComponent("system.caf")
        try writeToneCAF(micURL, frames: 48_000, amplitude: 1.2)
        try writeToneCAF(systemURL, frames: 48_000, amplitude: 0.5)
        let destination = dir.appendingPathComponent("audio.m4a")

        try CombinedAudioBuilder().build(
            micURL: micURL,
            systemURL: systemURL,
            destinationURL: destination,
            micOffsetSeconds: 0,
            systemOffsetSeconds: 0,
            micPeak: 1.2,
            systemPeak: 0.5
        )

        let (mic, _) = try decodeStereo(destination)
        let peak = mic.map(abs).max() ?? 0
        XCTAssertLessThan(peak, 1.0, "clipping not corrected (peak \(peak))")
        XCTAssertGreaterThan(peak, 0.80, "over-attenuated (peak \(peak))")
    }

    func testQuietRecordingIsLeftAtItsLevel() throws {
        // A recording that never approaches clipping must not be touched — no gratuitous gain.
        let micURL = dir.appendingPathComponent("mic.caf")
        let systemURL = dir.appendingPathComponent("system.caf")
        try writeToneCAF(micURL, frames: 48_000, amplitude: 0.5)
        try writeToneCAF(systemURL, frames: 48_000, amplitude: 0.5)
        let destination = dir.appendingPathComponent("audio.m4a")

        try CombinedAudioBuilder().build(
            micURL: micURL,
            systemURL: systemURL,
            destinationURL: destination,
            micOffsetSeconds: 0,
            systemOffsetSeconds: 0,
            micPeak: 0.5,
            systemPeak: 0.5
        )

        let (mic, _) = try decodeStereo(destination)
        let peak = mic.map(abs).max() ?? 0
        // Left near 0.5, not pulled up toward the 0.97 normalize target.
        XCTAssertLessThan(peak, 0.7, "quiet recording was gained up (peak \(peak))")
        XCTAssertGreaterThan(peak, 0.3, "quiet recording lost its signal (peak \(peak))")
    }

    func testMicOnlyModeDuplicatesMicAndExcludesSystem() throws {
        // Loudspeaker recording path: the system track (here a louder, distinct tone) must
        // not appear; the mic is placed on both channels (centered mono).
        let micURL = dir.appendingPathComponent("mic.caf")
        let systemURL = dir.appendingPathComponent("system.caf")
        try writeToneCAF(micURL, frames: 48_000, amplitude: 0.5)
        try writeToneCAF(systemURL, frames: 48_000, amplitude: 0.9)
        let destination = dir.appendingPathComponent("audio.m4a")

        try CombinedAudioBuilder().build(
            micURL: micURL,
            systemURL: systemURL,
            destinationURL: destination,
            micOffsetSeconds: 0,
            systemOffsetSeconds: 0,
            micPeak: 0.5,
            systemPeak: 0.9,
            includeSystemTrack: false
        )

        let (left, right) = try decodeStereo(destination)
        let n = min(left.count, right.count)
        XCTAssertGreaterThan(n, 0)
        var maxDelta: Float = 0
        var rightPeak: Float = 0
        for i in 0..<n {
            maxDelta = max(maxDelta, abs(left[i] - right[i]))
            rightPeak = max(rightPeak, abs(right[i]))
        }
        XCTAssertLessThan(maxDelta, 0.02, "channels differ — system leaked into the mic-only output")
        // Right channel carries the mic (0.5), not the louder system tone (0.9).
        XCTAssertLessThan(rightPeak, 0.7, "right channel carries the system track, not the mic")
        XCTAssertGreaterThan(rightPeak, 0.3, "right channel lost the mic signal")
    }

    // MARK: - Helpers

    /// Writes `frames` samples of one fixed 1-second chirp (300→3000 Hz). Two files with different
    /// frame counts therefore sample the *same* underlying sweep at different rates — exactly the
    /// clock-drift situation the builder corrects.
    private func writeChirpCAF(_ url: URL, frames: Int) throws {
        try writeCAF(url, frames: frames) { i in
            let t = Double(i) / Double(frames)          // normalized position in the 1 s sweep
            let f0 = 300.0, f1 = 3_000.0
            let phase = 2 * Double.pi * (f0 * t + 0.5 * (f1 - f0) * t * t)
            return Float(0.6 * sin(phase))
        }
    }

    private func writeToneCAF(_ url: URL, frames: Int, amplitude: Float) throws {
        try writeCAF(url, frames: frames) { i in amplitude * sin(Float(i) / 24) }
    }

    private func writeCAF(_ url: URL, frames: Int, sample: (Int) -> Float) throws {
        let file = try AVAudioFile(
            forWriting: url,
            settings: AudioFormat.cafSettings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        guard let buffer = AVAudioPCMBuffer(pcmFormat: AudioFormat.pcmFormat, frameCapacity: AVAudioFrameCount(frames)),
              let channel = buffer.floatChannelData?.pointee else {
            XCTFail("Could not allocate CAF buffer"); return
        }
        buffer.frameLength = AVAudioFrameCount(frames)
        for i in 0..<frames { channel[i] = sample(i) }
        try file.write(from: buffer)
    }

    private func decodeStereo(_ url: URL) throws -> ([Float], [Float]) {
        let file = try AVAudioFile(forReading: url)
        XCTAssertEqual(file.processingFormat.channelCount, 2)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw CaptureError.conversionFailed("decode buffer")
        }
        try file.read(into: buffer)
        let n = Int(buffer.frameLength)
        let left = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: n))
        let right = Array(UnsafeBufferPointer(start: buffer.floatChannelData![1], count: n))
        return (left, right)
    }

    /// Normalized cross-correlation lag (samples) that best aligns `b` to `a`.
    private func bestLag(_ a: [Float], _ b: [Float], maxLag: Int) -> Int {
        let n = min(a.count, b.count)
        var bestLag = 0
        var best = -Float.greatestFiniteMagnitude
        for lag in -maxLag...maxLag {
            var dot: Float = 0, ea: Float = 0, eb: Float = 0
            for i in 0..<n {
                let j = i + lag
                guard j >= 0, j < n else { continue }
                dot += a[i] * b[j]; ea += a[i] * a[i]; eb += b[j] * b[j]
            }
            let corr = dot / (sqrt(ea * eb) + 1e-9)
            if corr > best { best = corr; bestLag = lag }
        }
        return bestLag
    }
}

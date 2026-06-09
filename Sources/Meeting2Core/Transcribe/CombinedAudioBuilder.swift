import AVFoundation
import Foundation

public struct CombinedAudioBuilder {
    private let frameCapacity: AVAudioFrameCount = 4096
    private let bitRate = 128_000

    public init() {}

    /// Merges the two raw mono tracks into one durable stereo `.m4a`: the local mic on the
    /// left channel, system audio (everyone else) on the right. This is the single file a
    /// person plays back later *and* the single file the transcriber receives — keeping the
    /// channels split preserves speaker separation (you vs. them) without any real-time
    /// mixing.
    ///
    /// The two tracks never start at the same instant (the system tap spins up before the
    /// mic engine), so each carries a start offset. We bake that alignment in here by
    /// prepending silence to the later track; the result is already time-aligned and
    /// nothing downstream has to carry offsets.
    ///
    /// Tolerant by design: if one track is missing or empty (e.g. mic permission was denied
    /// so no `mic.caf` was ever written), the other is still saved with the absent channel
    /// left silent — we never drop audio we did capture. Only when *both* tracks are
    /// unusable do we fail.
    public func build(
        micURL: URL,
        systemURL: URL,
        destinationURL: URL,
        micOffsetSeconds: Double,
        systemOffsetSeconds: Double,
        micPeak: Float? = nil,
        systemPeak: Float? = nil
    ) throws {
        let micFile = try openReadableTrack(micURL, role: "mic")
        var systemFile = try openReadableTrack(systemURL, role: "system")
        guard micFile != nil || systemFile != nil else {
            throw CaptureError.conversionFailed("Cannot build combined audio: both tracks missing or empty")
        }

        let sampleRate = AudioFormat.sampleRate
        let micOffsetFrames = max(0, AVAudioFramePosition((micOffsetSeconds * sampleRate).rounded()))
        let systemOffsetFrames = max(0, AVAudioFramePosition((systemOffsetSeconds * sampleRate).rounded()))

        // Drift correction. The mic and system tracks are captured on two independent clocks, so
        // over a long meeting the same sound drifts to progressively different sample offsets —
        // which plays back as echo. We treat the mic as the reference timeline and resample the
        // system track (using its exact frame count, no estimation) so its content ends where the
        // mic's does, keeping shared content aligned throughout. Only when both tracks exist — a
        // lone track has nothing to align to. This is the resampler-sync follow-up from
        // plans/INIT.md §5.4.
        var driftTempURL: URL?
        defer { driftTempURL.map { try? FileManager.default.removeItem(at: $0) } }
        if let mic = micFile, let system = systemFile {
            let targetSystemFrames = (micOffsetFrames + mic.length) - systemOffsetFrames
            if let corrected = try driftCorrectedSystemTrack(
                systemURL: systemURL,
                sourceFrames: system.length,
                targetFrames: targetSystemFrames,
                nearDestination: destinationURL
            ) {
                driftTempURL = corrected
                systemFile = try openReadableTrack(corrected, role: "system")
            }
        }

        let micEndFrame = micFile.map { micOffsetFrames + $0.length } ?? 0
        let systemEndFrame = systemFile.map { systemOffsetFrames + $0.length } ?? 0
        let totalFrames = max(micEndFrame, systemEndFrame)
        guard totalFrames > 0 else {
            throw CaptureError.conversionFailed("Cannot build combined audio from empty tracks")
        }

        try FileManager.default.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? FileManager.default.removeItem(at: destinationURL)

        try writeStereoM4A(
            micFile: micFile,
            systemFile: systemFile,
            destinationURL: destinationURL,
            micOffsetFrames: micOffsetFrames,
            systemOffsetFrames: systemOffsetFrames,
            totalFrames: totalFrames,
            gain: Self.normalizationGain(micPeak: micPeak, systemPeak: systemPeak)
        )

        try validateStereoM4A(destinationURL)
    }

    private func writeStereoM4A(
        micFile: AVAudioFile?,
        systemFile: AVAudioFile?,
        destinationURL: URL,
        micOffsetFrames: AVAudioFramePosition,
        systemOffsetFrames: AVAudioFramePosition,
        totalFrames: AVAudioFramePosition,
        gain: Float
    ) throws {
        let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: AudioFormat.sampleRate,
            channels: 2,
            interleaved: false
        )!
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: AudioFormat.sampleRate,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: bitRate
        ]

        let outputFile = try AVAudioFile(
            forWriting: destinationURL,
            settings: settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )

        var outputFrame: AVAudioFramePosition = 0
        while outputFrame < totalFrames {
            let framesThisChunk = min(
                AVAudioFramePosition(frameCapacity),
                totalFrames - outputFrame
            )
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: outputFormat,
                frameCapacity: AVAudioFrameCount(framesThisChunk)
            ) else {
                throw CaptureError.conversionFailed("Could not allocate combined-audio stereo buffer")
            }
            buffer.frameLength = AVAudioFrameCount(framesThisChunk)
            zero(buffer)

            if let micFile {
                try copy(
                    file: micFile,
                    offsetFrames: micOffsetFrames,
                    outputFrame: outputFrame,
                    frameCount: framesThisChunk,
                    into: buffer,
                    channel: 0
                )
            }
            if let systemFile {
                try copy(
                    file: systemFile,
                    offsetFrames: systemOffsetFrames,
                    outputFrame: outputFrame,
                    frameCount: framesThisChunk,
                    into: buffer,
                    channel: 1
                )
            }

            if gain < 1.0 { Self.applyGain(buffer, gain) }
            try outputFile.write(from: buffer)
            outputFrame += framesThisChunk
        }
    }

    /// Opens a track for reading, or returns `nil` when it is simply absent or empty so the
    /// caller can leave that channel silent. A present-but-malformed file (wrong rate or no
    /// channels) throws instead of being silently dropped — that signals corruption the
    /// pipeline should surface and retry, not bury.
    private func openReadableTrack(_ url: URL, role: String) throws -> AVAudioFile? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let file = try AVAudioFile(forReading: url)
        guard file.length > 0 else { return nil }
        guard file.processingFormat.channelCount >= 1 else {
            throw CaptureError.unsupportedFormat("\(role) audio has no readable channels")
        }
        guard abs(file.processingFormat.sampleRate - AudioFormat.sampleRate) < 0.5 else {
            throw CaptureError.unsupportedFormat(
                "\(role) audio sample rate \(file.processingFormat.sampleRate) does not match \(AudioFormat.sampleRate)"
            )
        }
        return file
    }

    private func copy(
        file: AVAudioFile,
        offsetFrames: AVAudioFramePosition,
        outputFrame: AVAudioFramePosition,
        frameCount: AVAudioFramePosition,
        into outputBuffer: AVAudioPCMBuffer,
        channel: Int
    ) throws {
        let sourceStart = outputFrame - offsetFrames
        let outputStart = max(AVAudioFramePosition(0), -sourceStart)
        let sourceFrame = max(AVAudioFramePosition(0), sourceStart)
        guard outputStart < frameCount, sourceFrame < file.length else { return }

        let readableFrames = min(frameCount - outputStart, file.length - sourceFrame)
        guard readableFrames > 0,
              let sourceBuffer = AVAudioPCMBuffer(
                  pcmFormat: file.processingFormat,
                  frameCapacity: AVAudioFrameCount(readableFrames)
              ) else {
            return
        }

        file.framePosition = sourceFrame
        try file.read(into: sourceBuffer, frameCount: AVAudioFrameCount(readableFrames))
        guard let source = sourceBuffer.floatChannelData?.pointee,
              let destination = outputBuffer.floatChannelData?[channel] else {
            throw CaptureError.unsupportedFormat("Could not access combined-audio float channels")
        }

        let framesRead = Int(sourceBuffer.frameLength)
        let destinationStart = Int(outputStart)
        for index in 0..<framesRead {
            destination[destinationStart + index] = source[index]
        }
    }

    private func zero(_ buffer: AVAudioPCMBuffer) {
        guard let channels = buffer.floatChannelData else { return }
        let byteCount = Int(buffer.frameLength) * MemoryLayout<Float>.stride
        for channel in 0..<Int(buffer.format.channelCount) {
            memset(channels[channel], 0, byteCount)
        }
    }

    // MARK: - Drift correction

    private static let minDriftFrames: AVAudioFramePosition = 48     // ~1 ms; below this, ignore
    private static let maxDriftRatioDeviation = 0.01                 // >1% length change ⇒ bad data, skip

    /// Resamples the system track onto the mic timeline when the inter-track clock drift is
    /// meaningful and plausible; returns a temp file the caller merges then deletes, or nil to use
    /// the original unchanged. The resample ratio is exact (from frame counts), so the alignment
    /// holds across the whole recording. A sanity bound skips an implausible ratio (real drift is
    /// well under 1 %) rather than wreck the audio on bad inputs.
    private func driftCorrectedSystemTrack(
        systemURL: URL,
        sourceFrames: AVAudioFramePosition,
        targetFrames: AVAudioFramePosition,
        nearDestination: URL
    ) throws -> URL? {
        guard sourceFrames > 0, targetFrames > 0 else { return nil }
        guard abs(targetFrames - sourceFrames) >= Self.minDriftFrames else { return nil }

        let ratio = Double(targetFrames) / Double(sourceFrames)
        guard abs(ratio - 1.0) <= Self.maxDriftRatioDeviation else {
            DebugDiagnostics.log(
                recordingFile: systemURL,
                "drift correction skipped: implausible length ratio \(ratio) (\(sourceFrames)->\(targetFrames))"
            )
            return nil
        }

        let tempURL = nearDestination.deletingLastPathComponent()
            .appendingPathComponent("system.drift.\(UUID().uuidString).caf")
        do {
            try resampleFile(
                sourceURL: systemURL,
                sourceFrames: sourceFrames,
                targetFrames: targetFrames,
                destinationURL: tempURL
            )
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            throw error
        }
        DebugDiagnostics.log(
            recordingFile: systemURL,
            "drift corrected system \(sourceFrames)->\(targetFrames) frames ratio=\(ratio)"
        )
        return tempURL
    }

    /// Resamples a 48 kHz mono track to `targetFrames`, written back at 48 kHz. The trick: tell
    /// `AVAudioConverter` the source ran at a slightly-off *effective* rate and convert to the true
    /// 48 kHz — so the output is genuinely 48 kHz-labelled and longer/shorter by exactly the drift,
    /// using sinc (not linear) interpolation. Streamed in chunks; never holds the whole track in
    /// memory.
    private func resampleFile(
        sourceURL: URL,
        sourceFrames: AVAudioFramePosition,
        targetFrames: AVAudioFramePosition,
        destinationURL: URL
    ) throws {
        let source = try AVAudioFile(forReading: sourceURL)
        let effectiveRate = AudioFormat.sampleRate * Double(sourceFrames) / Double(targetFrames)
        guard let inputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: effectiveRate, channels: 1, interleaved: false
        ), let converter = AVAudioConverter(from: inputFormat, to: AudioFormat.pcmFormat) else {
            throw CaptureError.conversionFailed("Could not create drift-correction converter")
        }
        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue

        let outputFile = try AVAudioFile(
            forWriting: destinationURL,
            settings: AudioFormat.cafSettings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )

        let readCapacity: AVAudioFrameCount = 16_384
        guard let readBuffer = AVAudioPCMBuffer(pcmFormat: source.processingFormat, frameCapacity: readCapacity) else {
            throw CaptureError.conversionFailed("Could not allocate drift-correction read buffer")
        }
        let outputCapacity = AVAudioFrameCount(Double(readCapacity) * AudioFormat.sampleRate / effectiveRate) + 1_024

        var conversionError: NSError?
        while true {
            guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: AudioFormat.pcmFormat, frameCapacity: outputCapacity) else {
                throw CaptureError.conversionFailed("Could not allocate drift-correction output buffer")
            }
            let status = converter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
                // `AVAudioFile.read` throws ("nilError") when called at EOF instead of returning
                // zero frames, so check the position first and signal end-of-stream cleanly. A
                // genuine read failure also degrades to end-of-stream; the length check after the
                // loop catches a short (truncated) result.
                guard source.framePosition < source.length else {
                    outStatus.pointee = .endOfStream
                    return nil
                }
                readBuffer.frameLength = 0
                do {
                    try source.read(into: readBuffer, frameCount: readCapacity)
                } catch {
                    outStatus.pointee = .endOfStream
                    return nil
                }
                guard readBuffer.frameLength > 0,
                      let input = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: readBuffer.frameLength) else {
                    outStatus.pointee = .endOfStream
                    return nil
                }
                input.frameLength = readBuffer.frameLength
                memcpy(
                    input.floatChannelData![0],
                    readBuffer.floatChannelData![0],
                    Int(readBuffer.frameLength) * MemoryLayout<Float>.size
                )
                outStatus.pointee = .haveData
                return input
            }

            if let conversionError { throw conversionError }
            if outputBuffer.frameLength > 0 { try outputFile.write(from: outputBuffer) }
            if status != .haveData { break }
        }

        // Guard against a truncated resample (e.g. a genuine mid-file read failure): the converter
        // preserves duration, so the output must be within a hair of the target length.
        let tolerance = max(AVAudioFramePosition(64), targetFrames / 1_000)
        guard abs(outputFile.length - targetFrames) <= tolerance else {
            throw CaptureError.conversionFailed(
                "Drift-correction output length \(outputFile.length) != target \(targetFrames)"
            )
        }
    }

    // MARK: - Normalization

    private static let normalizeThreshold: Float = 0.99   // only act on (near-)clipping output
    private static let normalizeTarget: Float = 0.89      // ~ -1 dBFS: headroom for AAC inter-sample (true) peaks

    /// The stereo file is the two mono tracks on L/R (never summed), so its peak is the louder of
    /// the two channel peaks. Capture can exceed 1.0 (we have seen 1.24), which clips on playback;
    /// a single flat gain brings it back under while preserving dynamics and L/R balance. Unknown
    /// peaks (e.g. a recovered crash with no stats) ⇒ no change.
    private static func normalizationGain(micPeak: Float?, systemPeak: Float?) -> Float {
        let peak = max(micPeak ?? 0, systemPeak ?? 0)
        guard peak > normalizeThreshold else { return 1.0 }
        return min(1.0, normalizeTarget / peak)
    }

    private static func applyGain(_ buffer: AVAudioPCMBuffer, _ gain: Float) {
        guard let channels = buffer.floatChannelData else { return }
        let frames = Int(buffer.frameLength)
        for channel in 0..<Int(buffer.format.channelCount) {
            let data = channels[channel]
            for index in 0..<frames {
                data[index] = max(-1.0, min(1.0, data[index] * gain))
            }
        }
    }

    private func validateStereoM4A(_ url: URL) throws {
        let file = try AVAudioFile(forReading: url)
        guard file.length > 0, file.processingFormat.channelCount == 2 else {
            throw CaptureError.conversionFailed("Combined audio is not a readable stereo M4A: \(url.path)")
        }
    }
}

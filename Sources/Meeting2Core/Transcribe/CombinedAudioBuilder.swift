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
        systemOffsetSeconds: Double
    ) throws {
        let micFile = try openReadableTrack(micURL, role: "mic")
        let systemFile = try openReadableTrack(systemURL, role: "system")
        guard micFile != nil || systemFile != nil else {
            throw CaptureError.conversionFailed("Cannot build combined audio: both tracks missing or empty")
        }

        let sampleRate = AudioFormat.sampleRate
        let micOffsetFrames = max(0, AVAudioFramePosition((micOffsetSeconds * sampleRate).rounded()))
        let systemOffsetFrames = max(0, AVAudioFramePosition((systemOffsetSeconds * sampleRate).rounded()))
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
            totalFrames: totalFrames
        )

        try validateStereoM4A(destinationURL)
    }

    private func writeStereoM4A(
        micFile: AVAudioFile?,
        systemFile: AVAudioFile?,
        destinationURL: URL,
        micOffsetFrames: AVAudioFramePosition,
        systemOffsetFrames: AVAudioFramePosition,
        totalFrames: AVAudioFramePosition
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

    private func validateStereoM4A(_ url: URL) throws {
        let file = try AVAudioFile(forReading: url)
        guard file.length > 0, file.processingFormat.channelCount == 2 else {
            throw CaptureError.conversionFailed("Combined audio is not a readable stereo M4A: \(url.path)")
        }
    }
}

import AVFoundation
import Foundation

final class TrackWriter {
    // The process tap callback only enqueues raw frames. This writer owns every
    // operation that is too expensive or unsafe for the IOProc: format conversion,
    // RMS accounting, and disk writes. That separation is the main reliability
    // boundary for system-audio capture.
    let url: URL

    private var sourceFormat: AVAudioFormat
    private let outputFormat = AudioFormat.pcmFormat
    private let file: AVAudioFile
    private let ring: CircularAudioBuffer
    private let queue: DispatchQueue
    private var timer: DispatchSourceTimer?
    private var bytesPerFrame: Int
    private let scratchFrameCapacity: AVAudioFrameCount = 4096
    private var converter: AVAudioConverter?
    private let meter = LockedRMSMeter()
    private var didLogFirstBuffer = false
    private var didLogFirstNonSilentBuffer = false
    private var didStop = false

    init(url: URL, sourceFormat: AVAudioFormat, ring: CircularAudioBuffer) throws {
        self.url = url
        self.sourceFormat = sourceFormat
        self.ring = ring
        self.bytesPerFrame = 0
        self.file = try AVAudioFile(
            forWriting: url,
            settings: AudioFormat.cafSettings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        self.queue = DispatchQueue(label: "meetingrec.track-writer.\(url.lastPathComponent)")

        try configureSourceFormat(sourceFormat)
    }

    deinit {
        stop()
    }

    func start() {
        guard timer == nil, !didStop else { return }

        // The timer is created here, not in init, on purpose. If Core Audio times out
        // while creating the IOProc, SystemTapCapture tears this object down before
        // writing ever starts, and releasing a DispatchSource that was never resumed
        // crashes — so we only make one once we're committed to running.
        //
        // 20 ms is a balance: often enough that the ring buffer never comes close to
        // filling (it holds ~10 s), but not so often that the queue just spins. The
        // leeway lets the OS batch wake-ups to save power.
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(20), leeway: .milliseconds(5))
        timer.setEventHandler { [weak self] in
            self?.drain()
        }
        self.timer = timer
        timer.resume()
        DebugDiagnostics.log(
            recordingFile: url,
            "\(url.lastPathComponent) writer started sourceRate=\(sourceFormat.sampleRate) " +
            "channels=\(sourceFormat.channelCount) converter=\(converter != nil)"
        )
    }

    func stop() {
        guard !didStop else { return }
        didStop = true

        if let timer {
            timer.setEventHandler {}
            timer.cancel()
            self.timer = nil
        }

        queue.sync {
            drainAll()
            let snapshot = meter.snapshot
            DebugDiagnostics.log(
                recordingFile: url,
                "\(url.lastPathComponent) writer stopped rms=\(snapshot.rms) " +
                "peak=\(snapshot.peak) samples=\(snapshot.sampleCount)"
            )
        }
    }

    func drainBacklogBeforeRouteRebuild() {
        queue.sync {
            drainAll()
        }
    }

    func reconfigure(sourceFormat newSourceFormat: AVAudioFormat) throws {
        try queue.sync {
            // Route rebuilds can change the tap's native sample rate. Drain with
            // the old converter first, then swap the source format so one CAF file
            // remains continuous without mislabeling pre-change frames.
            drainAll()
            try configureSourceFormat(newSourceFormat)
        }
    }

    var stats: TrackStats {
        let snapshot = meter.snapshot
        return TrackStats(
            url: url,
            rms: snapshot.rms,
            peak: snapshot.peak,
            droppedBytes: 0,
            recentLevel: snapshot.recentLevel
        )
    }

    private func drain() {
        _ = drainOneChunk()
    }

    private func drainAll() {
        while drainOneChunk() {}
    }

    @discardableResult
    private func drainOneChunk() -> Bool {
        var available: UInt32 = 0
        guard let tail = ring.tail(availableBytes: &available), available >= UInt32(bytesPerFrame) else {
            return false
        }

        let readableFrames = min(Int(available) / bytesPerFrame, Int(scratchFrameCapacity))
        let readableBytes = readableFrames * bytesPerFrame

        guard let sourceBuffer = AVAudioPCMBuffer(
            pcmFormat: sourceFormat,
            frameCapacity: AVAudioFrameCount(readableFrames)
        ) else {
            ring.consume(byteCount: readableBytes)
            return true
        }

        sourceBuffer.frameLength = AVAudioFrameCount(readableFrames)
        // The ring buffer stores the tap's native non-interleaved Float32 bytes.
        // Copy into an AVAudioPCMBuffer here so AVFoundation can handle conversion
        // and CAF writing on the non-real-time side of the boundary.
        guard copyRawSamples(from: tail, byteCount: readableBytes, into: sourceBuffer) else {
            ring.consume(byteCount: readableBytes)
            fputs("TrackWriter could not map \(url.lastPathComponent) source buffer as mono Float32\n", stderr)
            DebugDiagnostics.log(recordingFile: url, "\(url.lastPathComponent) writer failed to map source buffer")
            return true
        }
        ring.consume(byteCount: readableBytes)

        do {
            if let converter {
                try writeConverted(sourceBuffer, converter: converter)
            } else {
                try file.write(from: sourceBuffer)
                meter.ingest(sourceBuffer)
                logWrittenBuffer(sourceBuffer)
            }
        } catch {
            fputs("TrackWriter failed for \(url.lastPathComponent): \(error)\n", stderr)
            DebugDiagnostics.log(recordingFile: url, "\(url.lastPathComponent) writer failed error=\(error)")
        }

        return true
    }

    private func copyRawSamples(
        from source: UnsafeMutableRawPointer,
        byteCount: Int,
        into buffer: AVAudioPCMBuffer
    ) -> Bool {
        guard let floatChannel = buffer.floatChannelData?.pointee else {
            return false
        }

        memcpy(floatChannel, source, byteCount)
        return true
    }

    private func writeConverted(_ sourceBuffer: AVAudioPCMBuffer, converter: AVAudioConverter) throws {
        // Size the output by the sample-rate ratio (e.g. 44.1 kHz in → 48 kHz out needs
        // more frames out than in), plus a small fixed margin so rounding can never
        // leave the resampler without room for its last few frames.
        let ratio = outputFormat.sampleRate / sourceFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(sourceBuffer.frameLength) * ratio + 512)

        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            throw CaptureError.conversionFailed("Could not allocate conversion output buffer")
        }

        var didProvideInput = false
        var conversionError: NSError?
        let status = converter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
            if didProvideInput {
                outStatus.pointee = .noDataNow
                return nil
            }

            didProvideInput = true
            outStatus.pointee = .haveData
            return sourceBuffer
        }

        if let conversionError {
            throw conversionError
        }

        switch status {
        case .haveData, .inputRanDry, .endOfStream:
            if outputBuffer.frameLength > 0 {
                try file.write(from: outputBuffer)
                meter.ingest(outputBuffer)
                logWrittenBuffer(outputBuffer)
            }
        case .error:
            throw CaptureError.conversionFailed("AVAudioConverter returned error")
        @unknown default:
            throw CaptureError.conversionFailed("AVAudioConverter returned unknown status")
        }
    }

    private func configureSourceFormat(_ newSourceFormat: AVAudioFormat) throws {
        try validateSourceFormat(newSourceFormat)

        sourceFormat = newSourceFormat
        bytesPerFrame = Int(newSourceFormat.streamDescription.pointee.mBytesPerFrame)

        guard bytesPerFrame > 0 else {
            throw CaptureError.unsupportedFormat("source bytesPerFrame is zero")
        }

        if newSourceFormat.isEquivalent(to: outputFormat) {
            converter = nil
            DebugDiagnostics.log(
                recordingFile: url,
                "\(url.lastPathComponent) writer configured without converter sourceRate=\(newSourceFormat.sampleRate)"
            )
            return
        }

        guard let converter = AVAudioConverter(from: newSourceFormat, to: outputFormat) else {
            throw CaptureError.conversionFailed("Could not create AVAudioConverter for \(url.lastPathComponent)")
        }
        self.converter = converter
        DebugDiagnostics.log(
            recordingFile: url,
            "\(url.lastPathComponent) writer configured converter sourceRate=\(newSourceFormat.sampleRate) " +
            "outputRate=\(outputFormat.sampleRate)"
        )
    }

    private func validateSourceFormat(_ format: AVAudioFormat) throws {
        let streamDescription = format.streamDescription.pointee
        let expectedBytesPerFrame = UInt32(MemoryLayout<Float>.stride)

        // The realtime side copies opaque bytes from the tap. This writer can
        // convert sample rates, but it must fail loudly if the memory layout is
        // anything other than one non-interleaved Float32 channel.
        guard format.commonFormat == .pcmFormatFloat32,
              format.channelCount == AudioFormat.channelCount,
              !format.isInterleaved,
              streamDescription.mFormatID == kAudioFormatLinearPCM,
              streamDescription.mBitsPerChannel == 32,
              streamDescription.mBytesPerFrame == expectedBytesPerFrame else {
            throw CaptureError.unsupportedFormat(
                "TrackWriter requires mono non-interleaved Float32 input, got \(streamDescription)"
            )
        }
    }

    private func logWrittenBuffer(_ buffer: AVAudioPCMBuffer) {
        guard DebugDiagnostics.isEnabled else { return }

        if !didLogFirstBuffer {
            didLogFirstBuffer = true
            DebugDiagnostics.log(
                recordingFile: url,
                "\(url.lastPathComponent) writer first buffer frames=\(buffer.frameLength)"
            )
        }

        let snapshot = meter.snapshot
        guard !didLogFirstNonSilentBuffer, !snapshot.isSilent else { return }
        didLogFirstNonSilentBuffer = true
        DebugDiagnostics.log(
            recordingFile: url,
            "\(url.lastPathComponent) writer first non-silent buffer rms=\(snapshot.rms) peak=\(snapshot.peak)"
        )
    }
}

import AVFoundation
import Foundation
import TPCircularBuffer

private final class HostTimeAtomicCell {
    // The mic tap and UI/finalize path touch this from different threads. Keep the
    // storage as an explicit heap pointer, matching the system tap's IOProc context,
    // so the C atomic wrappers always receive one stable address instead of an `&` to
    // a Swift stored property whose address is only borrowed for the duration of a call.
    private let storage: UnsafeMutablePointer<UInt64>

    init() {
        storage = UnsafeMutablePointer<UInt64>.allocate(capacity: 1)
        storage.initialize(to: 0)
    }

    deinit {
        storage.deinitialize(count: 1)
        storage.deallocate()
    }

    func recordFirstHostTimeIfNeeded(_ hostTime: UInt64) {
        MeetingAtomicUInt64CompareExchange(storage, 0, hostTime)
    }

    var loaded: UInt64? {
        let value = MeetingAtomicUInt64Load(storage)
        return value == 0 ? nil : value
    }
}

final class MicCapture {
    // Captures the microphone (your voice) via AVAudioEngine, Apple's standard audio
    // framework. This path is deliberately simpler than SystemTapCapture: AVAudioEngine
    // delivers buffers on an ordinary background thread, not Core Audio's hard real-time
    // thread, so it is safe to convert and write to the file directly in the callback —
    // there is no need for the ring-buffer + separate-writer machinery the system tap
    // requires. We still convert through AVAudioConverter so mic.caf and system.caf end
    // up in the same fixed format (see Util/AudioFormat.swift and docs/CAPTURE.md).
    private let outputURL: URL
    private let engine = AVAudioEngine()
    private var file: AVAudioFile?
    private var converter: AVAudioConverter?
    private var sourceFormat: AVAudioFormat?
    private let meter = LockedRMSMeter()
    private let firstHostTime = HostTimeAtomicCell()
    private var isRunning = false
    private var didLogFirstBuffer = false
    private var didLogFirstNonSilentBuffer = false

    init(outputURL: URL) {
        self.outputURL = outputURL
    }

    deinit {
        stop()
    }

    func start() throws {
        guard !isRunning else { return }
        try Self.ensureMicrophonePermission()

        let input = engine.inputNode
        let sourceFormat = input.outputFormat(forBus: 0)
        self.sourceFormat = sourceFormat

        if sourceFormat.isEquivalent(to: AudioFormat.pcmFormat) {
            // Skip the converter entirely when the microphone hardware already gives
            // us the exact file format (mono/48 kHz/float). One less thing happening
            // per buffer; the format check makes the conversion provably unnecessary.
            converter = nil
        } else {
            guard let converter = AVAudioConverter(from: sourceFormat, to: AudioFormat.pcmFormat) else {
                throw CaptureError.conversionFailed("Could not create mic AVAudioConverter")
            }
            self.converter = converter
        }
        DebugDiagnostics.log(
            recordingFile: outputURL,
            "mic start sourceRate=\(sourceFormat.sampleRate) channels=\(sourceFormat.channelCount) " +
            "converter=\(converter != nil)"
        )

        file = try AVAudioFile(
            forWriting: outputURL,
            settings: AudioFormat.cafSettings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )

        input.installTap(onBus: 0, bufferSize: 4096, format: sourceFormat) { [weak self] buffer, time in
            self?.handle(buffer, time: time)
        }

        try engine.start()
        isRunning = true
        DebugDiagnostics.log(recordingFile: outputURL, "mic engine started")
    }

    func stop() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        file = nil
        converter = nil
        sourceFormat = nil
        isRunning = false
        let snapshot = meter.snapshot
        DebugDiagnostics.log(
            recordingFile: outputURL,
            "mic stopped rms=\(snapshot.rms) peak=\(snapshot.peak) samples=\(snapshot.sampleCount) " +
            "firstHostTime=\(loadedFirstHostTime.map(String.init) ?? "unknown")"
        )
    }

    var stats: TrackStats {
        let snapshot = meter.snapshot
        return TrackStats(
            url: outputURL,
            rms: snapshot.rms,
            peak: snapshot.peak,
            droppedBytes: 0,
            hostStartTime: loadedFirstHostTime,
            recentLevel: snapshot.recentLevel
        )
    }

    private func handle(_ buffer: AVAudioPCMBuffer, time: AVAudioTime) {
        if time.hostTime != 0 {
            firstHostTime.recordFirstHostTimeIfNeeded(time.hostTime)
        }

        guard let sourceFormat, let file else { return }

        guard let converter else {
            do {
                try file.write(from: buffer)
                meter.ingest(buffer)
                logWrittenBuffer(buffer)
            } catch {
                fputs("Mic write failed: \(error)\n", stderr)
                DebugDiagnostics.log(recordingFile: outputURL, "mic write failed error=\(error)")
            }
            return
        }

        let ratio = AudioFormat.sampleRate / sourceFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 512)
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: AudioFormat.pcmFormat, frameCapacity: capacity) else {
            DebugDiagnostics.log(recordingFile: outputURL, "mic conversion output buffer allocation failed")
            return
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
            return buffer
        }

        if let conversionError {
            fputs("Mic conversion failed: \(conversionError)\n", stderr)
            DebugDiagnostics.log(recordingFile: outputURL, "mic conversion failed error=\(conversionError)")
            return
        }

        guard status != .error, outputBuffer.frameLength > 0 else { return }

        do {
            try file.write(from: outputBuffer)
            meter.ingest(outputBuffer)
            logWrittenBuffer(outputBuffer)
        } catch {
            fputs("Mic write failed: \(error)\n", stderr)
            DebugDiagnostics.log(recordingFile: outputURL, "mic write failed error=\(error)")
        }
    }

    private func logWrittenBuffer(_ buffer: AVAudioPCMBuffer) {
        guard DebugDiagnostics.isEnabled else { return }

        if !didLogFirstBuffer {
            didLogFirstBuffer = true
            DebugDiagnostics.log(recordingFile: outputURL, "mic first buffer frames=\(buffer.frameLength)")
        }

        let snapshot = meter.snapshot
        guard !didLogFirstNonSilentBuffer, !snapshot.isSilent else { return }
        didLogFirstNonSilentBuffer = true
        DebugDiagnostics.log(
            recordingFile: outputURL,
            "mic first non-silent buffer rms=\(snapshot.rms) peak=\(snapshot.peak)"
        )
    }

    private var loadedFirstHostTime: UInt64? {
        firstHostTime.loaded
    }

    private static func ensureMicrophonePermission(timeout: TimeInterval = 20) throws {
        // Request permission before installing the tap. That keeps partial-start
        // failures simple: DualTrackRecorder can stop the system tap without also
        // having a half-open mic file to reason about.
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return
        case .denied, .restricted:
            throw CaptureError.invalidState("Microphone permission is denied or restricted")
        case .notDetermined:
            let semaphore = DispatchSemaphore(value: 0)
            var granted = false
            AVCaptureDevice.requestAccess(for: .audio) { allowed in
                granted = allowed
                semaphore.signal()
            }

            let result = semaphore.wait(timeout: .now() + timeout)
            guard result == .success else {
                throw CaptureError.invalidState("Timed out waiting for microphone permission")
            }
            guard granted else {
                throw CaptureError.invalidState("Microphone permission was not granted")
            }
        @unknown default:
            throw CaptureError.invalidState("Unknown microphone permission state")
        }
    }
}

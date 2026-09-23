import AVFoundation
import Darwin
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

    func recordLatestHostTime(_ hostTime: UInt64) {
        MeetingAtomicUInt64Store(storage, hostTime)
    }

    var loaded: UInt64? {
        let value = MeetingAtomicUInt64Load(storage)
        return value == 0 ? nil : value
    }
}

/// A configuration change may post several notifications while the engine is down.
/// One pending timer covers those signals; three attempts span device settling without
/// polling for the rest of the meeting. A later change can retry after cooldown.
/// `MicCapture` owns this under its lifecycle lock; no audio callback touches it.
struct MicRecoveryRetryState {
    private static let retryDelays: [TimeInterval] = [1, 5]
    private static let cooldownSeconds: TimeInterval = 5

    private var scheduledAttempt: Int?
    private var attempts = 0
    private var cooldownUntil: TimeInterval = 0

    var attemptNumber: Int { attempts }

    mutating func mayAttempt(isScheduledRetry: Bool, now: TimeInterval) -> Bool {
        if isScheduledRetry {
            guard let scheduledAttempt else { return false }
            attempts = scheduledAttempt
            self.scheduledAttempt = nil
            return true
        }
        guard scheduledAttempt == nil, now >= cooldownUntil else { return false }
        attempts = 1
        return true
    }

    /// Returns the next delay, or nil after the final failed attempt.
    mutating func failed(now: TimeInterval) -> TimeInterval? {
        guard attempts > 0 else { return nil }
        if attempts <= Self.retryDelays.count {
            scheduledAttempt = attempts + 1
            return Self.retryDelays[attempts - 1]
        }
        cooldownUntil = now + Self.cooldownSeconds
        return nil
    }

    mutating func reset() {
        scheduledAttempt = nil
        attempts = 0
        cooldownUntil = 0
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
    private let lifecycleLock = NSLock()
    private let recoveryQueue = DispatchQueue(label: "com.mirable.Meeting2.mic-recovery")
    private var file: AVAudioFile?
    private let meter = LockedRMSMeter()
    private let firstHostTime = HostTimeAtomicCell()
    private let lastWrittenBufferHostTime = HostTimeAtomicCell()
    // Live stats may be read on the main actor while an engine restart blocks on
    // Core Audio. Keep this counter's lock separate from `lifecycleLock`.
    private let routeChangeCountLock = NSLock()
    private var routeChangeCount = 0
    private var isRunning = false
    private var hasInstalledTap = false
    private var didLogFirstBuffer = false
    private var didLogFirstNonSilentBuffer = false
    private var engineStartRequestedHostTime: UInt64?
    private var previousInputHostTime: UInt64?
    private var previousInputDurationMilliseconds = 0.0
    private var configurationChangeObserver: NSObjectProtocol?
    private var recoveryRetryState = MicRecoveryRetryState()

    init(outputURL: URL) {
        self.outputURL = outputURL
    }

    deinit {
        stop()
    }

    func start() throws {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        guard !isRunning else { return }
        recoveryRetryState.reset()
        try Self.ensureMicrophonePermission()

        let input = engine.inputNode
        let sourceFormat = input.outputFormat(forBus: 0)
        let converter = try Self.makeConverter(from: sourceFormat)
        DebugDiagnostics.log(
            recordingFile: outputURL,
            "mic start sourceRate=\(sourceFormat.sampleRate) channels=\(sourceFormat.channelCount) " +
            "converter=\(converter != nil)"
        )

        let file = try AVAudioFile(
            forWriting: outputURL,
            settings: AudioFormat.cafSettings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        self.file = file

        // The notification can arrive on an internal audio queue, including during
        // `start()`. Only schedule recovery here; engine teardown on that queue can deadlock.
        configurationChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            DebugDiagnostics.log(
                recordingFile: self.outputURL,
                "mic engine configuration changed running=\(self.engine.isRunning)"
            )
            self.recoveryQueue.async { [weak self] in self?.restartAfterConfigurationChange() }
        }
        installTap(format: sourceFormat, converter: converter, file: file)
        engineStartRequestedHostTime = mach_absolute_time()
        do {
            try engine.start()
        } catch {
            // The tap and file already exist even if the engine never reached running.
            stopLocked()
            throw error
        }
        isRunning = true
        DebugDiagnostics.log(recordingFile: outputURL, "mic engine started")
    }

    func stop() {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        stopLocked()
    }

    private func stopLocked() {
        if let configurationChangeObserver {
            NotificationCenter.default.removeObserver(configurationChangeObserver)
            self.configurationChangeObserver = nil
        }
        let wasRunning = isRunning
        if hasInstalledTap {
            engine.inputNode.removeTap(onBus: 0)
            hasInstalledTap = false
        }
        if engine.isRunning {
            engine.stop()
        }
        file = nil
        isRunning = false
        recoveryRetryState.reset()
        guard wasRunning else { return }
        let snapshot = meter.snapshot
        DebugDiagnostics.log(
            recordingFile: outputURL,
            "mic stopped rms=\(snapshot.rms) peak=\(snapshot.peak) samples=\(snapshot.sampleCount) " +
            "routeChanges=\(routeChanges) " +
            "firstHostTime=\(loadedFirstHostTime.map(String.init) ?? "unknown") " +
            "lastWrittenBufferHostTime=\(lastWrittenBufferHostTime.loaded.map(String.init) ?? "unknown")"
        )
    }

    private func restartAfterConfigurationChange(isScheduledRetry: Bool = false) {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        guard recoveryRetryState.mayAttempt(
            isScheduledRetry: isScheduledRetry,
            now: ProcessInfo.processInfo.systemUptime
        ) else { return }
        // A change during start or after Stop must not revive a finished recording.
        // Some configuration notifications leave the engine running; those need no work.
        guard isRunning, let file else { return }
        guard !engine.isRunning else {
            recoveryRetryState.reset()
            return
        }
        let attempt = recoveryRetryState.attemptNumber
        if attempt == 1 {
            routeChangeCountLock.lock()
            routeChangeCount += 1
            routeChangeCountLock.unlock()
        }

        let input = engine.inputNode
        if hasInstalledTap {
            input.removeTap(onBus: 0)
            hasInstalledTap = false
        }
        do {
            let format = input.outputFormat(forBus: 0)
            let converter = try Self.makeConverter(from: format)
            installTap(format: format, converter: converter, file: file)
            try engine.start()
            recoveryRetryState.reset()
            DebugDiagnostics.log(
                recordingFile: outputURL,
                "mic engine restarted attempt=\(attempt) " +
                "sourceRate=\(format.sampleRate) channels=\(format.channelCount) " +
                "converter=\(converter != nil)"
            )
        } catch {
            if hasInstalledTap {
                input.removeTap(onBus: 0)
                hasInstalledTap = false
            }
            DebugDiagnostics.log(
                recordingFile: outputURL,
                "mic engine restart failed attempt=\(attempt) error=\(error)"
            )
            if let delay = recoveryRetryState.failed(now: ProcessInfo.processInfo.systemUptime) {
                DebugDiagnostics.log(recordingFile: outputURL, "mic engine restart retry scheduled after \(delay)s")
                recoveryQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
                    self?.restartAfterConfigurationChange(isScheduledRetry: true)
                }
            }
        }
    }

    private static func makeConverter(from format: AVAudioFormat) throws -> AVAudioConverter? {
        // Recheck the hardware format after each route change. A tap bound to the old
        // channel count or a converter built for it cannot safely resume capture.
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw CaptureError.unsupportedFormat("Microphone input has no usable audio format")
        }
        if format.isEquivalent(to: AudioFormat.pcmFormat) { return nil }
        guard let converter = AVAudioConverter(from: format, to: AudioFormat.pcmFormat) else {
            throw CaptureError.conversionFailed("Could not create mic AVAudioConverter")
        }
        return converter
    }

    private func installTap(format: AVAudioFormat, converter: AVAudioConverter?, file: AVAudioFile) {
        // Capture format-specific objects in the tap closure. A route rebuild replaces
        // them without racing a callback already finishing on the previous format.
        engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, time in
            self?.handle(buffer, time: time, sourceFormat: format, converter: converter, file: file)
        }
        hasInstalledTap = true
    }

    var stats: TrackStats {
        let snapshot = meter.snapshot
        return TrackStats(
            url: outputURL,
            rms: snapshot.rms,
            peak: snapshot.peak,
            droppedBytes: 0,
            routeChanges: routeChanges,
            hostStartTime: loadedFirstHostTime,
            lastBufferHostTime: lastWrittenBufferHostTime.loaded,
            recentLevel: snapshot.recentLevel
        )
    }

    private var routeChanges: Int {
        routeChangeCountLock.lock()
        defer { routeChangeCountLock.unlock() }
        return routeChangeCount
    }

    private func handle(
        _ buffer: AVAudioPCMBuffer,
        time: AVAudioTime,
        sourceFormat: AVAudioFormat,
        converter: AVAudioConverter?,
        file: AVAudioFile
    ) {
        logInputTiming(buffer, time: time)
        if time.hostTime != 0 {
            firstHostTime.recordFirstHostTimeIfNeeded(time.hostTime)
        }

        guard let converter else {
            do {
                try file.write(from: buffer)
                didWrite(buffer)
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
            didWrite(outputBuffer)
        } catch {
            fputs("Mic write failed: \(error)\n", stderr)
            DebugDiagnostics.log(recordingFile: outputURL, "mic write failed error=\(error)")
        }
    }

    private func logInputTiming(_ buffer: AVAudioPCMBuffer, time: AVAudioTime) {
        // This callback already writes mic.caf. Diagnostics only queue rare log text;
        // do not pad gaps or add another synchronous write on the capture thread.
        guard DebugDiagnostics.isEnabled, time.hostTime != 0 else { return }
        if let previousInputHostTime {
            let gapMilliseconds = HostClock.milliseconds(from: previousInputHostTime, to: time.hostTime)
                - previousInputDurationMilliseconds
            if gapMilliseconds > 1_000 {
                let fileFrame = meter.snapshot.sampleCount
                DebugDiagnostics.log(
                    recordingFile: outputURL,
                    "mic input gap seconds=\(gapMilliseconds / 1_000) " +
                    "previousHostTime=\(previousInputHostTime) currentHostTime=\(time.hostTime) " +
                    "micFileFrame=\(fileFrame)"
                )
            }
        } else if let engineStartRequestedHostTime {
            let delayMilliseconds = HostClock.milliseconds(from: engineStartRequestedHostTime, to: time.hostTime)
            if delayMilliseconds > 1_000 {
                DebugDiagnostics.log(
                    recordingFile: outputURL,
                    "mic first input delay seconds=\(delayMilliseconds / 1_000) " +
                    "micFileFrame=\(meter.snapshot.sampleCount)"
                )
            }
        }
        previousInputHostTime = time.hostTime
        previousInputDurationMilliseconds = Double(buffer.frameLength) / buffer.format.sampleRate * 1_000
    }

    private func didWrite(_ buffer: AVAudioPCMBuffer) {
        meter.ingest(buffer)
        // A quiet or muted mic still supplies buffers. Stamp successful writes, not
        // loudness, so a stalled tap can be distinguished from ordinary silence.
        lastWrittenBufferHostTime.recordLatestHostTime(mach_absolute_time())
        logWrittenBuffer(buffer)
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

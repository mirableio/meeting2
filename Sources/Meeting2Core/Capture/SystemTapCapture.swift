import AVFoundation
import CoreAudio
import Foundation
import TPCircularBuffer

private struct SystemTapIOProcContext {
    let ring: UnsafeMutablePointer<TPCircularBuffer>
    var firstHostTime: UInt64 = 0
    var droppedByteCount: UInt64 = 0
}

@available(macOS 14.2, *)
private struct SystemTapGraph {
    let tapID: AudioObjectID
    let aggregateID: AudioObjectID
    let sourceFormat: AVAudioFormat
}

@available(macOS 14.2, *)
private struct SystemAudioDeviceSnapshot {
    let id: AudioObjectID
    let uid: String
    let name: String

    var debugDescription: String {
        "\(name) uid=\(uid) id=\(id)"
    }
}

@available(macOS 14.2, *)
private struct SystemAudioRouteSnapshot {
    let defaultOutput: SystemAudioDeviceSnapshot
    let defaultSystemOutput: SystemAudioDeviceSnapshot?
    let defaultInput: SystemAudioDeviceSnapshot?

    var debugDescription: String {
        let systemOutput = defaultSystemOutput?.debugDescription ?? "unknown"
        let input = defaultInput?.debugDescription ?? "unknown"
        return "defaultOutput=\(defaultOutput.debugDescription) " +
            "defaultSystemOutput=\(systemOutput) defaultInput=\(input)"
    }
}

private let systemTapIOProc: AudioDeviceIOProc = { _, _, inputData, inputTime, _, _, clientData in
    guard let clientData else { return noErr }

    let context = clientData.assumingMemoryBound(to: SystemTapIOProcContext.self)
    let hostTime = inputTime.pointee.mHostTime
    if hostTime != 0 {
        MeetingAtomicUInt64CompareExchange(&context.pointee.firstHostTime, 0, hostTime)
    }

    // This runs on Core Audio's real-time thread: it is called on a strict schedule
    // and MUST return immediately. Allocating, locking, logging, or touching the disk
    // here would miss the deadline and make the audio system drop samples — i.e. lose
    // meeting audio. So it does only three things: read a pointer, one bounded memcpy
    // into the lock-free ring, and bump relaxed atomic counters. All slow work (format
    // conversion, RMS, disk writes) happens later in TrackWriter on a normal thread.
    let bufferList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
    guard let first = bufferList.first, let data = first.mData else {
        return noErr
    }

    let byteCount = Int(first.mDataByteSize)
    guard byteCount > 0 else { return noErr }

    if !TPCircularBufferProduceBytes(context.pointee.ring, data, UInt32(byteCount)) {
        MeetingAtomicUInt64FetchAdd(&context.pointee.droppedByteCount, UInt64(byteCount))
    }

    return noErr
}

@available(macOS 14.2, *)
final class SystemTapCapture {
    // Captures "system audio" — the sound the Mac plays, i.e. everyone else on the
    // call. macOS has no simple "give me the speakers' output" API, so we use a
    // *process tap* (an OS object that listens to processes' audio output) hosted by
    // a private *aggregate device* (a virtual input device that exists only in this
    // process). The aggregate device then drives an IOProc — a real-time callback
    // that hands us buffers of audio. This is the most delicate code in the app;
    // it is kept in one type so nothing else depends on its internals.
    //
    // New here? Read docs/CAPTURE.md first — it explains every term and decision.
    private let outputURL: URL
    private let listenerQueue = DispatchQueue(label: "meetingrec.system-tap.listeners")
    private let listenerQueueKey = DispatchSpecificKey<Void>()
    private let ring: CircularAudioBuffer
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    // `stats` is intentionally callable from the main actor while route rebuilds are
    // busy on `listenerQueue`. These ownership slots therefore need their own tiny
    // lock: Swift reference reads (`writer`) and raw-pointer reads (`ioProcContext`)
    // are not made safe just because the pointee counters are atomic. Keep this lock
    // scoped to copying references and loading scalar counters; never hold it across
    // HAL calls, writer drains, or filesystem work.
    private let stateLock = NSLock()
    private var ioProcContext: UnsafeMutablePointer<SystemTapIOProcContext>?
    private var writer: TrackWriter?
    private var lastStats: TrackStats?
    private let routeChangeCountLock = NSLock()
    private var routeChangeCount = 0
    private var defaultOutputListener: AudioObjectPropertyListenerBlock?
    private var aggregateAliveListener: AudioObjectPropertyListenerBlock?
    private var isRunning = false
    private var isRebuildingRoute = false
    private var pendingRouteRebuild = false
    private var routeRebuildScheduled = false
    private var recordingFolder: URL {
        outputURL.deletingLastPathComponent()
    }
    private var isOnListenerQueue: Bool {
        DispatchQueue.getSpecific(key: listenerQueueKey) != nil
    }

    init(outputURL: URL, ringByteCapacity: Int = 48_000 * 4 * 10) throws {
        self.outputURL = outputURL
        self.ring = try CircularAudioBuffer(byteCapacity: ringByteCapacity)
        listenerQueue.setSpecific(key: listenerQueueKey, value: ())
    }

    deinit {
        stop()
    }

    func start(timeout: TimeInterval = 10) throws {
        try listenerQueue.sync {
            guard !isRunning else { return }
            DebugDiagnostics.log(recordingFolder: recordingFolder, "system tap start requested")

            let maxAttempts = 5
            for attempt in 1...maxAttempts {
                do {
                    try startAttempt(timeout: timeout, attempt: attempt)
                    return
                } catch {
                    stopUnlocked()

                    guard shouldRetryStart(after: error, attempt: attempt, maxAttempts: maxAttempts) else {
                        DebugDiagnostics.log(recordingFolder: recordingFolder, "system tap start failed error=\(error)")
                        throw error
                    }

                    // `AudioDeviceStart` can occasionally return `kAudioHardwareIllegalOperationError`
                    // for a freshly-created private aggregate whose Core Audio server side has no
                    // "master engine info" yet. The failed graph cannot be trusted after that, so
                    // rebuild the tap/aggregate from scratch instead of retrying the same IDs.
                    DebugDiagnostics.log(
                        recordingFolder: recordingFolder,
                        "system tap start retrying attempt=\(attempt + 1) after error=\(error)"
                    )
                    try? FileManager.default.removeItem(at: outputURL)
                    Thread.sleep(forTimeInterval: retryDelay(after: error, attempt: attempt))
                }
            }
        }
    }

    private func startAttempt(timeout: TimeInterval, attempt: Int) throws {
        DebugDiagnostics.log(recordingFolder: recordingFolder, "system tap start attempt=\(attempt)")

        let graph = try createTapGraph()
        installTapGraph(graph)
        try registerRouteChangeListeners()
        DebugDiagnostics.log(recordingFolder: recordingFolder, "system tap route listeners registered")
        DebugDiagnostics.log(
            recordingFolder: recordingFolder,
            "system tap graph installed tapID=\(graph.tapID) aggregateID=\(graph.aggregateID) " +
            "sampleRate=\(graph.sourceFormat.sampleRate)"
        )

        let writer = try TrackWriter(url: outputURL, sourceFormat: graph.sourceFormat, ring: ring)
        installWriter(writer)

        try createIOProc(timeout: timeout)
        writer.start()
        try startDevice(timeout: timeout)

        isRunning = true
        DebugDiagnostics.log(recordingFolder: recordingFolder, "system tap device started")
    }

    private func shouldRetryStart(after error: Error, attempt: Int, maxAttempts: Int) -> Bool {
        guard attempt < maxAttempts else {
            return false
        }

        switch error {
        case let CaptureError.coreAudio(status, operation):
            return operation == "AudioDeviceStart" && status == kAudioHardwareIllegalOperationError
        case CaptureError.unknownTapObject, CaptureError.unknownAggregateObject:
            return true
        default:
            return false
        }
    }

    private func retryDelay(after error: Error, attempt: Int) -> TimeInterval {
        // These pauses are deliberately longer than the tap-format retry above.
        // A failed `AudioDeviceStart` is not a local readiness blip; it means HAL's
        // server-side aggregate graph just rejected startup and can spend another
        // second reporting half-destroyed tap IDs. Rebuilding immediately only
        // amplifies that race, so give Core Audio time to retire the old graph before
        // asking for the next private tap/aggregate pair.
        switch error {
        case let CaptureError.coreAudio(status, operation)
            where operation == "AudioDeviceStart" && status == kAudioHardwareIllegalOperationError:
            return 1.5
        case CaptureError.unknownTapObject, CaptureError.unknownAggregateObject:
            return 2.0
        default:
            return min(3.0, 0.5 * Double(attempt))
        }
    }

    func stop() {
        // HAL property listeners are delivered on `listenerQueue`. If a listener is the
        // last holder of this object, `deinit` also runs on that queue. Calling
        // `sync` there is a libdispatch client bug and crashes immediately, so stop
        // inline when we already own the queue.
        if isOnListenerQueue {
            stopUnlocked()
            return
        }

        listenerQueue.sync {
            stopUnlocked()
        }
    }

    var stats: TrackStats {
        // Live UI health checks call this from the main actor. Do not synchronize with
        // `listenerQueue`: route rebuilds run there and may wait on HAL for seconds.
        // The state lock below only copies ownership slots and atomically loads
        // counters, so this remains advisory and non-blocking even while Core Audio is
        // reconfiguring.
        let state = liveStateSnapshot()
        return statsSnapshot(from: state.writer?.stats ?? state.lastStats, counters: state.counters)
    }

    private func stopUnlocked() {
        guard tapID != AudioObjectID(kAudioObjectUnknown) ||
                aggregateID != AudioObjectID(kAudioObjectUnknown) ||
                hasWriter else {
            return
        }
        DebugDiagnostics.log(recordingFolder: recordingFolder, "system tap stop requested")

        isRunning = false
        pendingRouteRebuild = false
        routeRebuildScheduled = false

        stopDeviceAndDestroyIOProc()
        unregisterRouteChangeListeners()

        let writer = currentWriter()
        writer?.stop()
        let stoppedStats = statsSnapshot(from: writer?.stats, counters: liveCounterSnapshot())
        clearWriterAndRememberStats(stoppedStats)
        DebugDiagnostics.log(
            recordingFolder: recordingFolder,
            "system tap stopped rms=\(stoppedStats.rms) peak=\(stoppedStats.peak) " +
            "dropped=\(stoppedStats.droppedBytes) routeChanges=\(stoppedStats.routeChanges) " +
            "firstHostTime=\(stoppedStats.hostStartTime.map(String.init) ?? "unknown")"
        )

        destroyTapGraph()
        destroyIOProcContext()

        isRebuildingRoute = false
    }

    private func createTapGraph() throws -> SystemTapGraph {
        var newTapID = AudioObjectID(kAudioObjectUnknown)
        var newAggregateID = AudioObjectID(kAudioObjectUnknown)
        let route = try readSystemAudioRouteSnapshot()
        DebugDiagnostics.log(recordingFolder: recordingFolder, "system audio route \(route.debugDescription)")

        let desc = CATapDescription(monoGlobalTapButExcludeProcesses: [])
        desc.name = "meetingrec-tap"
        desc.uuid = UUID()
        desc.isPrivate = true
        desc.muteBehavior = .unmuted

        do {
            try CaptureError.check(
                AudioHardwareCreateProcessTap(desc, &newTapID),
                "AudioHardwareCreateProcessTap"
            )
            guard newTapID != AudioObjectID(kAudioObjectUnknown) else {
                throw CaptureError.unknownTapObject
            }
            DebugDiagnostics.log(recordingFolder: recordingFolder, "process tap created tapID=\(newTapID)")

            var asbd = try readTapStreamDescriptionWithRetry(tapID: newTapID)
            DebugDiagnostics.log(recordingFolder: recordingFolder, "process tap format \(asbd)")

            guard let tapFormat = AVAudioFormat(streamDescription: &asbd) else {
                throw CaptureError.unsupportedFormat("Could not build AVAudioFormat from tap stream description")
            }

            try Self.validateTapFormat(asbd, format: tapFormat)

            guard let sourceFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: asbd.mSampleRate,
                channels: AudioFormat.channelCount,
                interleaved: false
            ) else {
                throw CaptureError.unsupportedFormat("Could not build normalized tap source format")
            }

            let aggregateUID = "meetingrec-tap-\(UUID().uuidString)"
            let anchorUID = route.defaultOutput.uid
            let anchorSubDevice: [String: Any] = [
                kAudioSubDeviceUIDKey as String: anchorUID
            ]
            let aggregateDescription: [String: Any] = [
                kAudioAggregateDeviceUIDKey as String: aggregateUID,
                kAudioAggregateDeviceNameKey as String: "meetingrec-tap",
                kAudioAggregateDeviceIsPrivateKey as String: true,
                kAudioAggregateDeviceSubDeviceListKey as String: [anchorSubDevice],
                kAudioAggregateDeviceMainSubDeviceKey as String: anchorUID
            ]

            try CaptureError.check(
                AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &newAggregateID),
                "AudioHardwareCreateAggregateDevice"
            )
            guard newAggregateID != AudioObjectID(kAudioObjectUnknown) else {
                throw CaptureError.unknownAggregateObject
            }
            DebugDiagnostics.log(
                recordingFolder: recordingFolder,
                "aggregate device created aggregateID=\(newAggregateID) anchor=\(route.defaultOutput.debugDescription)"
            )
            // macOS 15 gained typed Swift wrappers for aggregate subtaps. The project
            // floor is 14.2, so keep the property-based fallback until we intentionally
            // raise the deployment target.
            if #available(macOS 15.0, *) {
                try AudioHardwareAggregateDevice(id: newAggregateID).setSubtaps([AudioHardwareTap(id: newTapID)])
            } else {
                let tapUID = try AudioObjectReader.readCFString(newTapID, selector: kAudioTapPropertyUID)
                try setAggregateTapList(tapUID: tapUID, aggregateID: newAggregateID)
            }

            return SystemTapGraph(tapID: newTapID, aggregateID: newAggregateID, sourceFormat: sourceFormat)
        } catch {
            destroyTapGraph(tapID: newTapID, aggregateID: newAggregateID)
            throw error
        }
    }

    private func readSystemAudioRouteSnapshot() throws -> SystemAudioRouteSnapshot {
        // The private aggregate must have a concrete time base. Without this snapshot
        // we were creating a tap-only aggregate and trusting HAL to infer a master
        // engine, which fails as `kAudioHardwareIllegalOperationError` when virtual
        // meeting devices churn the route graph. We log the whole route on each retry
        // because the default output can legitimately change while Zoom/Krisp starts.
        let defaultOutput = try readDefaultDevice(
            selector: kAudioHardwarePropertyDefaultOutputDevice,
            role: "default output"
        )
        let defaultSystemOutput = try? readDefaultDevice(
            selector: kAudioHardwarePropertyDefaultSystemOutputDevice,
            role: "default system output"
        )
        let defaultInput = try? readDefaultDevice(
            selector: kAudioHardwarePropertyDefaultInputDevice,
            role: "default input"
        )

        return SystemAudioRouteSnapshot(
            defaultOutput: defaultOutput,
            defaultSystemOutput: defaultSystemOutput,
            defaultInput: defaultInput
        )
    }

    private func readDefaultDevice(
        selector: AudioObjectPropertySelector,
        role: String
    ) throws -> SystemAudioDeviceSnapshot {
        let id = try AudioObjectReader.readAudioObjectID(
            AudioObjectID(kAudioObjectSystemObject),
            selector: selector
        )
        guard id != AudioObjectID(kAudioObjectUnknown) else {
            throw CaptureError.invalidState("Missing \(role) device")
        }

        let uid = try AudioObjectReader.readCFString(id, selector: kAudioDevicePropertyDeviceUID)
        let name = (try? AudioObjectReader.readCFString(id, selector: kAudioDevicePropertyDeviceNameCFString)) ?? "unknown"

        return SystemAudioDeviceSnapshot(id: id, uid: uid, name: name)
    }

    private func installTapGraph(_ graph: SystemTapGraph) {
        tapID = graph.tapID
        aggregateID = graph.aggregateID
    }

    private func readTapStreamDescriptionWithRetry(tapID: AudioObjectID) throws -> AudioStreamBasicDescription {
        // A freshly created tap doesn't always report its audio format on the very
        // first read — the format can take a moment to become available. Rather than
        // fail the whole start, retry a few times with a short pause before giving up.
        var lastError: Error?

        for attempt in 0..<5 {
            do {
                return try AudioObjectReader.readStreamDescription(
                    tapID,
                    selector: kAudioTapPropertyFormat
                )
            } catch {
                lastError = error
                if attempt < 4 {
                    Thread.sleep(forTimeInterval: 0.1)
                }
            }
        }

        throw lastError ?? CaptureError.invalidState("Could not read process tap stream description")
    }

    private static func validateTapFormat(_ asbd: AudioStreamBasicDescription, format: AVAudioFormat) throws {
        let expectedBytesPerFrame = UInt32(MemoryLayout<Float>.stride)

        // The IOProc intentionally treats the tap buffer as raw Float32 bytes.
        // A mono packed buffer and a mono non-interleaved buffer have the same
        // memory layout, so the guard is on the actual byte contract and the
        // writer receives an explicit non-interleaved AVAudioFormat separately.
        guard asbd.mFormatID == kAudioFormatLinearPCM,
              asbd.mBitsPerChannel == 32,
              asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              asbd.mBytesPerFrame == expectedBytesPerFrame,
              format.commonFormat == .pcmFormatFloat32,
              format.channelCount == AudioFormat.channelCount else {
            throw CaptureError.unsupportedFormat("Expected mono Float32 LPCM from process tap, got \(asbd)")
        }
    }

    private func destroyTapGraph() {
        destroyTapGraph(tapID: tapID, aggregateID: aggregateID)
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    private func destroyTapGraph(tapID: AudioObjectID, aggregateID: AudioObjectID) {
        if aggregateID != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }

        if tapID != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyProcessTap(tapID)
        }
    }

    private func startDevice(timeout: TimeInterval) throws {
        guard let procID else {
            throw CaptureError.invalidState("Missing IOProc before AudioDeviceStart")
        }

        final class StartBox {
            var status: OSStatus?
        }

        let box = StartBox()
        let semaphore = DispatchSemaphore(value: 0)
        let aggregateID = aggregateID

        // When system-audio permission hasn't been granted, this call has been seen to
        // block forever instead of returning an error. Run it off the calling thread
        // with a timeout so a missing permission surfaces as a clear failure we can
        // clean up from, rather than hanging the whole app on a half-started recorder.
        DispatchQueue.global(qos: .userInitiated).async {
            box.status = AudioDeviceStart(aggregateID, procID)
            semaphore.signal()
        }

        guard semaphore.wait(timeout: .now() + timeout) == .success else {
            throw CaptureError.invalidState("Timed out starting Core Audio process tap after \(timeout)s")
        }

        try CaptureError.check(box.status ?? kAudioHardwareUnspecifiedError, "AudioDeviceStart")
        DebugDiagnostics.log(recordingFolder: recordingFolder, "AudioDeviceStart succeeded aggregateID=\(aggregateID)")
    }

    private func stopDeviceAndDestroyIOProc() {
        if let procID, aggregateID != AudioObjectID(kAudioObjectUnknown) {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        procID = nil
    }

    private func createIOProc(timeout: TimeInterval) throws {
        final class CreateBox {
            var status: OSStatus?
            var procID: AudioDeviceIOProcID?
        }

        let context = ensureIOProcContext()
        let box = CreateBox()
        let semaphore = DispatchSemaphore(value: 0)
        let aggregateID = aggregateID

        // Use the C IOProc API rather than the Swift block API. The block variant
        // retains a Swift closure and encourages object access in the callback; a
        // raw client-data pointer makes the realtime boundary visible and auditable.
        DispatchQueue.global(qos: .userInitiated).async {
            var localProcID: AudioDeviceIOProcID?
            box.status = AudioDeviceCreateIOProcID(
                aggregateID,
                systemTapIOProc,
                UnsafeMutableRawPointer(context),
                &localProcID
            )
            box.procID = localProcID
            semaphore.signal()
        }

        guard semaphore.wait(timeout: .now() + timeout) == .success else {
            throw CaptureError.invalidState(
                "Timed out creating Core Audio IOProc after \(timeout)s. " +
                "This usually means System Audio Recording permission has not been granted to the signed app bundle."
            )
        }

        try CaptureError.check(box.status ?? kAudioHardwareUnspecifiedError, "AudioDeviceCreateIOProcID")
        procID = box.procID
        DebugDiagnostics.log(recordingFolder: recordingFolder, "IOProc created aggregateID=\(aggregateID)")
    }

    private func ensureIOProcContext() -> UnsafeMutablePointer<SystemTapIOProcContext> {
        stateLock.lock()
        if let existing = ioProcContext {
            stateLock.unlock()
            return existing
        }
        stateLock.unlock()

        let context = UnsafeMutablePointer<SystemTapIOProcContext>.allocate(capacity: 1)
        context.initialize(to: SystemTapIOProcContext(ring: ring.realtimeStorage))

        stateLock.lock()
        if let existing = ioProcContext {
            stateLock.unlock()
            context.deinitialize(count: 1)
            context.deallocate()
            return existing
        }
        ioProcContext = context
        stateLock.unlock()
        return context
    }

    private func destroyIOProcContext() {
        stateLock.lock()
        let ioProcContext = ioProcContext
        self.ioProcContext = nil
        stateLock.unlock()

        guard let ioProcContext else { return }
        ioProcContext.deinitialize(count: 1)
        ioProcContext.deallocate()
    }

    private func setAggregateTapList(tapUID: String, aggregateID: AudioObjectID) throws {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioAggregateDevicePropertyTapList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var list: CFArray = [tapUID as CFString] as CFArray
        let size = UInt32(MemoryLayout.size(ofValue: list))
        let status = withUnsafeMutablePointer(to: &list) { pointer in
            AudioObjectSetPropertyData(aggregateID, &address, 0, nil, size, pointer)
        }
        try CaptureError.check(status, "AudioObjectSetPropertyData(kAudioAggregateDevicePropertyTapList)")
    }

    private func registerRouteChangeListeners() throws {
        try registerDefaultOutputListener()
        try registerAggregateAliveListener()
    }

    private func registerDefaultOutputListener() throws {
        guard defaultOutputListener == nil else { return }

        let routeListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.handleRouteChange(reason: "default output changed")
        }

        var defaultOutputAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        try CaptureError.check(
            AudioObjectAddPropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &defaultOutputAddress,
                listenerQueue,
                routeListener
            ),
            "AudioObjectAddPropertyListenerBlock(default output)"
        )
        defaultOutputListener = routeListener
    }

    private func registerAggregateAliveListener() throws {
        guard aggregateAliveListener == nil,
              aggregateID != AudioObjectID(kAudioObjectUnknown) else {
            return
        }

        let aggregateListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.handleRouteChange(reason: "aggregate device liveness changed")
        }

        var aggregateAliveAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        try CaptureError.check(
            AudioObjectAddPropertyListenerBlock(
                aggregateID,
                &aggregateAliveAddress,
                listenerQueue,
                aggregateListener
            ),
            "AudioObjectAddPropertyListenerBlock(aggregate alive)"
        )
        aggregateAliveListener = aggregateListener
    }

    private func unregisterRouteChangeListeners() {
        unregisterDefaultOutputListener()
        unregisterAggregateAliveListener()
    }

    private func unregisterDefaultOutputListener() {
        guard let defaultOutputListener else { return }

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            listenerQueue,
            defaultOutputListener
        )
        self.defaultOutputListener = nil
    }

    private func unregisterAggregateAliveListener() {
        guard let aggregateAliveListener,
              aggregateID != AudioObjectID(kAudioObjectUnknown) else {
            self.aggregateAliveListener = nil
            return
        }

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(
            aggregateID,
            &address,
            listenerQueue,
            aggregateAliveListener
        )
        self.aggregateAliveListener = nil
    }

    private func handleRouteChange(reason: String) {
        if DispatchQueue.getSpecific(key: listenerQueueKey) == nil {
            listenerQueue.async { [weak self] in
                self?.handleRouteChange(reason: reason)
            }
            return
        }

        let routeChangeCount = incrementRouteChangeCount()
        DebugDiagnostics.log(recordingFolder: recordingFolder, "route change event reason=\(reason) count=\(routeChangeCount)")

        guard isRunning else { return }
        pendingRouteRebuild = true
        scheduleRouteRebuildIfNeeded(reason: reason)
    }

    private func scheduleRouteRebuildIfNeeded(reason: String) {
        guard !routeRebuildScheduled else { return }

        // Switching audio devices often fires several notifications in quick succession
        // (e.g. an old device disappearing and a new one becoming default). Wait a beat
        // so a burst collapses into a single rebuild instead of tearing the tap down and
        // back up several times in a row.
        routeRebuildScheduled = true
        listenerQueue.asyncAfter(deadline: .now() + .milliseconds(500)) { [weak self] in
            self?.runScheduledRouteRebuild(reason: reason)
        }
    }

    private func runScheduledRouteRebuild(reason: String) {
        routeRebuildScheduled = false

        guard isRunning, pendingRouteRebuild else {
            pendingRouteRebuild = false
            return
        }

        guard !isRebuildingRoute else {
            scheduleRouteRebuildIfNeeded(reason: reason)
            return
        }

        isRebuildingRoute = true
        pendingRouteRebuild = false
        do {
            DebugDiagnostics.log(recordingFolder: recordingFolder, "route rebuild begin reason=\(reason)")
            try rebuildTapAfterRouteChange(reason: reason)
            DebugDiagnostics.log(recordingFolder: recordingFolder, "route rebuild finished reason=\(reason)")
        } catch {
            // This runs on a normal thread, never the real-time IOProc. A failed rebuild
            // means system audio is now silent; eventually that becomes a visible
            // capture-health warning, but until there is a UI, stderr is all we have.
            fputs("System tap route rebuild failed after \(reason): \(error)\n", stderr)
            DebugDiagnostics.log(recordingFolder: recordingFolder, "route rebuild failed reason=\(reason) error=\(error)")
        }
        isRebuildingRoute = false

        if pendingRouteRebuild && isRunning {
            scheduleRouteRebuildIfNeeded(reason: reason)
        }
    }

    private func rebuildTapAfterRouteChange(reason: String, timeout: TimeInterval = 5) throws {
        guard let writer = currentWriter() else {
            throw CaptureError.invalidState("Missing TrackWriter during route rebuild")
        }

        // The order here matters and is the whole reason this is one function:
        //  1. Build the replacement tap first, so a failure leaves the old one running.
        //  2. Stop the old IOProc, then flush whatever it already queued — those samples
        //     are still in the *old* format, so they must be written out before we
        //     switch formats, or the file would mix two layouts.
        //  3. Only then tear down the old graph, install the new one, and tell the
        //     writer the new format. The output file stays open and continuous the
        //     whole time; the first-sample timestamp is preserved so the two tracks
        //     still line up. The cost is a fraction of a second of system audio missed
        //     during the switch — far better than going silent for the rest of the call.
        let newGraph = try createTapGraph()

        stopDeviceAndDestroyIOProc()
        writer.drainBacklogBeforeRouteRebuild()

        unregisterAggregateAliveListener()
        destroyTapGraph()
        installTapGraph(newGraph)

        try writer.reconfigure(sourceFormat: newGraph.sourceFormat)
        try registerAggregateAliveListener()
        try createIOProc(timeout: timeout)
        try startDevice(timeout: timeout)
        DebugDiagnostics.log(
            recordingFolder: recordingFolder,
            "route rebuild installed tapID=\(newGraph.tapID) aggregateID=\(newGraph.aggregateID) " +
            "sampleRate=\(newGraph.sourceFormat.sampleRate)"
        )
    }

    private struct LiveStateSnapshot {
        let writer: TrackWriter?
        let lastStats: TrackStats?
        let counters: LiveCounterSnapshot
    }

    private struct LiveCounterSnapshot {
        let firstHostTime: UInt64?
        let droppedByteCount: Int?
    }

    private func installWriter(_ writer: TrackWriter) {
        stateLock.lock()
        self.writer = writer
        self.lastStats = nil
        stateLock.unlock()
    }

    private var hasWriter: Bool {
        stateLock.lock()
        let hasWriter = writer != nil
        stateLock.unlock()
        return hasWriter
    }

    private func currentWriter() -> TrackWriter? {
        stateLock.lock()
        let writer = writer
        stateLock.unlock()
        return writer
    }

    private func clearWriterAndRememberStats(_ stats: TrackStats) {
        stateLock.lock()
        lastStats = stats
        writer = nil
        stateLock.unlock()
    }

    private func liveStateSnapshot() -> LiveStateSnapshot {
        stateLock.lock()
        let snapshot = LiveStateSnapshot(
            writer: writer,
            lastStats: lastStats,
            counters: liveCounterSnapshotLocked()
        )
        stateLock.unlock()
        return snapshot
    }

    private func liveCounterSnapshot() -> LiveCounterSnapshot {
        stateLock.lock()
        let snapshot = liveCounterSnapshotLocked()
        stateLock.unlock()
        return snapshot
    }

    private func liveCounterSnapshotLocked() -> LiveCounterSnapshot {
        guard let ioProcContext else {
            return LiveCounterSnapshot(firstHostTime: nil, droppedByteCount: nil)
        }

        let firstHostTime = MeetingAtomicUInt64Load(&ioProcContext.pointee.firstHostTime)
        let droppedByteCount = MeetingAtomicUInt64Load(&ioProcContext.pointee.droppedByteCount)
        return LiveCounterSnapshot(
            firstHostTime: firstHostTime == 0 ? nil : firstHostTime,
            droppedByteCount: Int(min(droppedByteCount, UInt64(Int.max)))
        )
    }

    private func statsSnapshot(from base: TrackStats?, counters: LiveCounterSnapshot) -> TrackStats {
        let base = base ?? TrackStats(url: outputURL, rms: 0, peak: 0, droppedBytes: 0)
        let firstHostTime = counters.firstHostTime ?? base.hostStartTime
        let droppedBytes = counters.droppedByteCount ?? base.droppedBytes

        return TrackStats(
            url: base.url,
            rms: base.rms,
            peak: base.peak,
            droppedBytes: droppedBytes,
            routeChanges: routeChangeCountSnapshot,
            hostStartTime: firstHostTime,
            recentLevel: base.recentLevel
        )
    }

    private func incrementRouteChangeCount() -> Int {
        routeChangeCountLock.lock()
        routeChangeCount += 1
        let count = routeChangeCount
        routeChangeCountLock.unlock()
        return count
    }

    private var routeChangeCountSnapshot: Int {
        routeChangeCountLock.lock()
        let count = routeChangeCount
        routeChangeCountLock.unlock()
        return count
    }
}

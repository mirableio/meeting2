import CoreAudio
import Foundation

/// HAL's reported identity, without guessing which application owns a helper. PID is used only
/// for self-exclusion and best-effort presentation; bundle ID is the durable preference key.
public struct MicOwner: Equatable, Sendable {
    public let bundleID: String
    public let pid: pid_t

    public init(bundleID: String, pid: pid_t) {
        self.bundleID = bundleID
        self.pid = pid
    }
}

/// Watches the default input device so auto-detect can answer two questions without ever opening
/// the mic itself: "did the mic just go hot?" (the idle wake-up) and "which *other* apps hold the
/// mic right now?" (the start gate and the recording-liveness check). Pure observation.
///
/// All HAL reads run on a private serial queue — they are synchronous system calls that can stall,
/// so they must stay off the main actor (the rest of the capture code learned the same). The only
/// thing that touches the main thread is the `onWake` hop.
///
/// The device listener is only a fast wake-up. Owners must also be polled while idle: another
/// device can be in use, or an ignored app can already hold the watched microphone open.
public final class MicOwnerMonitor {
    public static let meeting2BundleID = "com.mirable.Meeting2"

    /// Called (on the main thread) when the input device's running state changes — "go look at the
    /// owners." Set by the owner before `start()`.
    public var onWake: (() -> Void)?

    private let queue = DispatchQueue(label: "com.mirable.Meeting2.mic-owner-monitor")
    private var runningListener: AudioObjectPropertyListenerBlock?
    private var defaultInputListener: AudioObjectPropertyListenerBlock?
    private var observedDevice = AudioObjectID(kAudioObjectUnknown)

    public init() {}

    public func start() {
        queue.async { [weak self] in self?.installListeners() }
    }

    public func stop() {
        queue.async { [weak self] in self?.removeListeners() }
    }

    /// Nil means incomplete knowledge, not silence. In particular, losing one process during
    /// enumeration must not become evidence for stopping or discarding a live recording.
    /// Successful empty IDs are omitted: unbundled processes cannot be configured as app owners,
    /// but must not make otherwise valid ownership information unavailable.
    public func refreshExternalOwners() async -> [MicOwner]? {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: Self.readExternalOwners()) }
        }
    }

    // MARK: - Listeners (serial queue only)

    private func installListeners() {
        guard defaultInputListener == nil else { return }
        // The default input device can change (plugging in a headset); re-bind the running-state
        // listener to the new device and treat the switch itself as a wake-up.
        var defaultAddress = Self.defaultInputAddress
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.rebindRunningListener()
            self?.fireWake()
        }
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &defaultAddress, queue, block
        )
        defaultInputListener = block
        rebindRunningListener()
    }

    private func removeListeners() {
        if let defaultInputListener {
            var address = Self.defaultInputAddress
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &address, queue, defaultInputListener
            )
        }
        defaultInputListener = nil
        unbindRunningListener()
    }

    private func rebindRunningListener() {
        unbindRunningListener()
        observedDevice = (try? AudioObjectReader.readAudioObjectID(
            AudioObjectID(kAudioObjectSystemObject), selector: kAudioHardwarePropertyDefaultInputDevice
        )) ?? AudioObjectID(kAudioObjectUnknown)
        guard observedDevice != AudioObjectID(kAudioObjectUnknown) else { return }

        var address = Self.runningSomewhereAddress
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.fireWake() }
        AudioObjectAddPropertyListenerBlock(observedDevice, &address, queue, block)
        runningListener = block
    }

    private func unbindRunningListener() {
        guard let runningListener, observedDevice != AudioObjectID(kAudioObjectUnknown) else {
            runningListener = nil
            return
        }
        var address = Self.runningSomewhereAddress
        AudioObjectRemovePropertyListenerBlock(observedDevice, &address, queue, runningListener)
        self.runningListener = nil
    }

    private func fireWake() {
        // Hop to the main thread; the owner re-enters the main actor via `assumeIsolated`.
        DispatchQueue.main.async { [weak self] in self?.onWake?() }
    }

    // MARK: - Reads (serial queue only)

    // These two read boundaries let tests reproduce HAL failures without opening a microphone.
    // Any required-property failure invalidates the whole absence claim; presentation lookups
    // happen later in the app layer and cannot invalidate a successfully identified owner.
    static func readExternalOwners(
        listProcesses: () throws -> [AudioObjectID] = {
            try AudioObjectReader.readAudioObjectIDList(
                AudioObjectID(kAudioObjectSystemObject), selector: kAudioHardwarePropertyProcessObjectList
            )
        },
        readProcess: (AudioObjectID) throws -> MicOwner? = readActiveProcess
    ) -> [MicOwner]? {
        do {
            var owners: [MicOwner] = []
            for process in try listProcesses() {
                guard let owner = try readProcess(process) else { continue }
                guard owner.pid != getpid(), owner.bundleID != meeting2BundleID else { continue }
                // HAL successfully returns an empty string for unbundled processes. That is an
                // unsupported owner identity, not a read failure that should poison every app.
                guard !owner.bundleID.isEmpty else { continue }
                owners.append(owner)
            }
            return owners
        } catch {
            return nil
        }
    }

    private static func readActiveProcess(_ process: AudioObjectID) throws -> MicOwner? {
        let running = try AudioObjectReader.readUInt32(process, selector: kAudioProcessPropertyIsRunningInput)
        guard running != 0 else { return nil }
        let pid = try AudioObjectReader.readPID(process, selector: kAudioProcessPropertyPID)
        guard pid != getpid() else { return nil }
        return MicOwner(
            bundleID: try AudioObjectReader.readCFString(process, selector: kAudioProcessPropertyBundleID),
            pid: pid
        )
    }

    private static let defaultInputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    private static let runningSomewhereAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
}

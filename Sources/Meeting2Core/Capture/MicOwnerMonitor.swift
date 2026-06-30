import CoreAudio
import Foundation

/// Watches the default input device so auto-detect can answer two questions without ever opening
/// the mic itself: "did the mic just go hot?" (the idle wake-up) and "which *other* apps hold the
/// mic right now?" (the start gate and the recording-liveness check). Pure observation.
///
/// All HAL reads run on a private serial queue — they are synchronous system calls that can stall,
/// so they must stay off the main actor (the rest of the capture code learned the same). The only
/// thing that touches the main thread is the `onWake` hop.
///
/// Why a poll and not just the listener: once Meeting2 starts recording it holds the input device,
/// so `DeviceIsRunningSomewhere` stays true and stops edging. The listener is therefore only a
/// wake-up for the idle path; the active recording path calls `refreshExternalOwners()` on a timer.
public final class MicOwnerMonitor {
    /// Mic owners that aren't meetings — always-on speech services etc. `com.apple.CoreSpeech` is
    /// the important one: with "Hey Siri"/dictation enabled it holds the mic input *continuously*.
    /// Best-effort and tunable; shared by auto-detect (start gate) and the "forgot to stop" nudge.
    public static let nonMeetingOwners: Set<String> = [
        "com.apple.CoreSpeech",    // "Hey Siri" / on-device speech & dictation (always-on mic)
        "com.apple.assistantd",    // Siri / the assistant daemon
        "com.apple.corespeechd",   // older speech-daemon naming, kept defensively
        "com.apple.VoiceOver",
    ]

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

    /// The live set of *external* mic-owner bundle ids (our own process excluded by PID). Reads HAL
    /// on the serial queue, so the caller's actor never blocks on the system call. There is no
    /// cached snapshot on purpose — while we hold the mic the listener stops firing, so a cache
    /// would go stale and never show the owner leaving.
    public func refreshExternalOwners() async -> Set<String> {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: Self.readExternalOwners()) }
        }
    }

    // MARK: - Listeners (serial queue only)

    private func installListeners() {
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

    private static func readExternalOwners() -> Set<String> {
        let me = getpid()
        guard let processes = try? AudioObjectReader.readAudioObjectIDList(
            AudioObjectID(kAudioObjectSystemObject), selector: kAudioHardwarePropertyProcessObjectList
        ) else { return [] }

        var owners: Set<String> = []
        for process in processes {
            guard let running = try? AudioObjectReader.readUInt32(
                process, selector: kAudioProcessPropertyIsRunningInput
            ), running != 0 else { continue }
            // Self-exclusion is by PID, not bundle id, so our own capture never reads as an owner.
            if let pid = try? AudioObjectReader.readPID(process, selector: kAudioProcessPropertyPID),
               pid == me { continue }
            if let bundle = try? AudioObjectReader.readCFString(
                process, selector: kAudioProcessPropertyBundleID
            ), !bundle.isEmpty {
                owners.insert(bundle)
            }
        }
        return owners
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

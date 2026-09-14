import Foundation
import Meeting2Core

/// The small command boundary needed to test delayed HAL results without creating real audio
/// files. Production still uses the exact same start/stop commands as the status menu.
@MainActor
protocol AutoRecordingCommands: AnyObject {
    var canStart: Bool { get }
    var canStop: Bool { get }
    var currentFolder: URL? { get }
    func startRecording(source: MeetingSource, completion: ((Bool) -> Void)?)
    func stopAutoRecording(ownerActiveSeconds: TimeInterval)
}

/// Only genuine stop commands install restrictions. Owner disappearance is a normal end, while
/// the silence/duration limits must not turn into an endless stop-and-restart loop.
enum RecordingStopReason: CaseIterable {
    case manual, silenceLimit, durationLimit, ownersGone, quit
    var restrictsRestart: Bool { self != .ownersGone }
}

/// Observes without opening the mic, then applies policy through the recording command surface.
/// Folder checks protect recordings; the generation also invalidates reads across disable/enable
/// and fast Stop/Start cycles that could otherwise return to the same idle state.
@MainActor
final class AutoRecordController {
    private let controller: any AutoRecordingCommands
    private let preferences: AutoRecordPreferences
    private let monitor: MicOwnerMonitor
    private let readOwners: () async -> [MicOwner]?
    private let now: () -> TimeInterval
    private var pollTask: Task<Void, Never>?
    private var policy = AutoRecordPolicy()
    private var generation: UInt64 = 0
    private var reading = false
    private var checkRequested = false
    private var starting = false
    private var latestOwners: Set<String>?
    private var latestFolder: URL?
    private var lastLog: String?
    private var automaticSession: (folder: URL, detectedAt: TimeInterval, owners: Set<String>, isFirstDetection: Bool)?

    init(
        controller: any AutoRecordingCommands, preferences: AutoRecordPreferences,
        monitor: MicOwnerMonitor = MicOwnerMonitor(),
        readOwners: (() async -> [MicOwner]?)? = nil,
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.controller = controller
        self.preferences = preferences
        self.monitor = monitor
        self.readOwners = readOwners ?? { await monitor.refreshExternalOwners() }
        self.now = now
    }

    func enable() {
        guard pollTask == nil else { return }
        generation &+= 1
        UserNotifier.requestAuthorization()
        monitor.onWake = { [weak self] in
            MainActor.assumeIsolated { self?.requestCheck() }
        }
        monitor.start()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.checkOwners()
                do { try await Task.sleep(nanoseconds: 5_000_000_000) } catch { return }
            }
        }
    }

    func disable() {
        generation &+= 1
        monitor.onWake = nil
        monitor.stop()
        pollTask?.cancel()
        pollTask = nil
        automaticSession = nil
        starting = false
        policy = AutoRecordPolicy()
        latestOwners = nil
    }

    func requestCheck() {
        let token = generation
        Task { [weak self] in
            guard let self, self.generation == token else { return }
            await self.checkOwners()
        }
    }

    /// Called synchronously by every stop path, before capture teardown or short-take pruning.
    /// Only an observation for this recording can identify its owners. A failed or pending read
    /// leaves ownership uncertain; an older snapshot cannot prove who is holding the mic now.
    func recordingWillStop(folder: URL, reason: RecordingStopReason) {
        guard preferences.enabled, controller.currentFolder == folder else { return }
        generation &+= 1
        if reason.restrictsRestart {
            let owners = latestFolder == folder && !reading ? latestOwners : nil
            policy.restrict(owners.map { preferences.eligibleOwners($0) })
        }
        automaticSession = nil
        latestOwners = nil
        starting = false
        policy.recordingChanged()
    }

    var disableTarget: ObservedApp? {
        guard preferences.enabled, controller.canStop, let session = automaticSession,
              session.isFirstDetection,
              session.folder == controller.currentFolder, latestFolder == session.folder,
              session.owners.count == 1, let owners = latestOwners else { return nil }
        let eligible = preferences.eligibleOwners(owners)
        guard eligible == session.owners, let id = eligible.first else { return nil }
        return preferences.apps.first { $0.bundleID == id }
    }

    /// Internal so regression tests can suspend a real controller read across Stop/Start. The
    /// tests replace only commands and the owner read, not the async orchestration under test.
    func checkOwners() async {
        guard preferences.enabled, !starting else { return }
        guard !reading else { checkRequested = true; return }
        reading = true
        defer {
            reading = false
            if checkRequested {
                checkRequested = false
                requestCheck()
            }
        }
        let token = generation
        let folder = controller.currentFolder
        if automaticSession?.folder != folder {
            automaticSession = nil
            policy.recordingChanged()
        }
        let result = await readOwners()
        guard !Task.isCancelled, preferences.enabled, generation == token,
              controller.currentFolder == folder else { return }
        let discovered = result.map { preferences.observe($0) } ?? []
        let owners = result.map { Set($0.map(\.bundleID)) }
        let eligible = preferences.eligibleOwners(owners ?? [])
        latestOwners = owners
        latestFolder = folder
        let log = owners.map { "owners=\($0.sorted()) eligible=\(eligible.sorted())" } ?? "owners=unknown"
        if log != lastLog { DebugDiagnostics.log("auto-record \(log)"); lastLog = log }

        let decision = policy.evaluate(
            owners: owners, eligible: eligible, canStart: controller.canStart,
            detectedAt: controller.canStop ? automaticSession?.detectedAt : nil, now: now()
        )
        switch decision {
        case .none:
            break
        case .start(let owner):
            starting = true
            let detectedAt = now()
            controller.startRecording(source: MeetingSource(micOwnerBundleId: owner)) { [weak self] started in
                guard let self, self.preferences.enabled, self.generation == token else { return }
                self.starting = false
                if started, let folder = self.controller.currentFolder, self.controller.canStop {
                    // Keep the discovery action through subsequent polls of this recording,
                    // but never offer it again once the app is already in the saved list.
                    self.automaticSession = (folder, detectedAt, eligible, discovered.contains(owner))
                    self.latestFolder = folder
                    UserNotifier.post(title: "Recording started", body: "Meeting2 is recording what looks like a meeting. Stop it from the menu bar.")
                } else {
                    // A failed capture already offers Try Again in the menu. Polling must not
                    // repeatedly retry the same owner and create failed folders every five seconds.
                    self.policy.restrict(eligible)
                }
            }
        case .stop(let seconds):
            guard let session = automaticSession, session.folder == controller.currentFolder,
                  controller.canStop, generation == token else { return }
            controller.stopAutoRecording(ownerActiveSeconds: seconds)
        }
    }
}

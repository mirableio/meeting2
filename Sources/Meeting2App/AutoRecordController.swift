import AppKit
import Foundation
import Meeting2Core
import UserNotifications

/// Auto-detect (online meetings only): when a *non-denylisted* app opens the mic, eagerly start a
/// recording; when that app lets the mic go for a grace period, stop and let the coordinator keep or
/// prune the take. F2F meetings have no external mic owner, so they can't be detected — that stays
/// manual by design (see plans/AUTODETECT.md).
///
/// This drives the same `RecorderMenuController` commands the menu does, so the status item, live
/// row, elapsed clock, and pipeline all behave exactly as for a manual start. The only thing it owns
/// is the *policy*: the denylist gate, the poll, and the start notification.
@MainActor
final class AutoRecordController {
    private let controller: RecorderMenuController
    private let monitor = MicOwnerMonitor()
    private var pollTask: Task<Void, Never>?
    private var enabled = false
    private var notificationsRequested = false

    /// A tiny state machine so the poll can tell "we're waiting for our start to take hold" apart
    /// from "the recording ended" — both read as `!canStop` otherwise.
    private enum AutoState { case idle, starting, recording }
    private var autoState: AutoState = .idle

    /// Known non-meeting mic owners to ignore. Best-effort and tunable (P2); unknown brief grabs get
    /// recorded and then pruned by the short/silent rule. (Our own process is excluded by PID inside
    /// `MicOwnerMonitor`, so it doesn't need to be listed here.)
    ///
    /// `com.apple.CoreSpeech` is the important one: with "Hey Siri"/dictation enabled it holds the
    /// mic input *continuously*, so without it here auto-record fires the instant it's switched on.
    private static let denylist: Set<String> = [
        "com.apple.CoreSpeech",    // "Hey Siri" / on-device speech & dictation (always-on mic)
        "com.apple.assistantd",    // Siri / the assistant daemon
        "com.apple.corespeechd",   // older speech-daemon naming, kept defensively
        "com.apple.VoiceOver",
    ]
    private static let stopGraceSeconds: TimeInterval = 120
    private static let pollIntervalNanoseconds: UInt64 = 5 * 1_000_000_000

    init(controller: RecorderMenuController) {
        self.controller = controller
    }

    func enable() {
        guard !enabled else { return }
        enabled = true
        requestNotificationAuthorizationOnce()
        monitor.onWake = { [weak self] in
            MainActor.assumeIsolated { self?.maybeStart() }
        }
        monitor.start()
        // The mic may already be hot (launched with auto-record on during a call, or toggled on
        // mid-call) — there'd be no new HAL edge, so check once now.
        maybeStart()
    }

    func disable() {
        guard enabled else { return }
        enabled = false
        monitor.onWake = nil
        monitor.stop()
        pollTask?.cancel()
        pollTask = nil
        autoState = .idle
    }

    // MARK: - Start

    private func maybeStart() {
        guard enabled, autoState == .idle, controller.canStart else { return }
        Task {
            let owners = await monitor.refreshExternalOwners().subtracting(Self.denylist)
            // Re-check the gate after the await — state may have moved while we read HAL.
            guard enabled, autoState == .idle, controller.canStart, !owners.isEmpty else { return }
            // Sets are unordered; pick deterministically and log the full set.
            let owner = owners.sorted().first!
            DebugDiagnostics.log("auto-record start owner=\(owner) owners=\(owners.sorted())")
            autoState = .starting
            // Stamp the meeting's start *now*, when the owner is confirmed present — not in the
            // completion below. `startRecording` can block/retry in Core Audio for seconds, and that
            // startup is time the owner was already active; measuring from the completion would
            // understate the meeting length and wrongly prune short-but-valid calls.
            let detectedAt = Date()
            controller.startRecording(source: MeetingSource(micOwnerBundleId: owner)) { [weak self] started in
                guard let self, self.enabled else { return }
                if started {
                    // Only now is it really recording — notify, and start judging liveness.
                    self.autoState = .recording
                    self.notifyStarted()
                    self.startPolling(detectedAt: detectedAt)
                } else {
                    // Capture failed — reset so a later mic-owner wake-up can try again (no wedge).
                    self.autoState = .idle
                }
            }
        }
    }

    // MARK: - Stop (poll the external owner while recording)

    private func startPolling(detectedAt: Date) {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            var ownerGoneSince: Date?
            while !Task.isCancelled {
                guard let self, self.enabled, self.autoState == .recording else { return }

                if !self.controller.canStop {
                    // Ended by another path (manual Stop / quit); the take is kept by that path.
                    self.autoState = .idle
                    return
                }
                let live = !(await self.monitor.refreshExternalOwners())
                    .subtracting(Self.denylist).isEmpty
                if live {
                    ownerGoneSince = nil
                } else {
                    let goneSince = ownerGoneSince ?? Date()
                    ownerGoneSince = goneSince
                    if Date().timeIntervalSince(goneSince) >= Self.stopGraceSeconds {
                        // The real meeting length is detection → owner left, excluding the grace.
                        self.autoState = .idle
                        self.controller.stopAutoRecording(
                            ownerActiveSeconds: goneSince.timeIntervalSince(detectedAt)
                        )
                        return
                    }
                }

                try? await Task.sleep(nanoseconds: Self.pollIntervalNanoseconds)
            }
        }
    }

    // MARK: - Notification (informational; the menu Stop is the escape hatch)

    private func requestNotificationAuthorizationOnce() {
        guard !notificationsRequested, Bundle.main.bundleIdentifier != nil else { return }
        notificationsRequested = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { _, _ in }
    }

    private func notifyStarted() {
        // `UNUserNotificationCenter.current()` traps when there's no app bundle (e.g. the raw
        // SwiftPM binary), so only touch it from a real .app. Best-effort: if it's denied, the menu
        // Stop is still the way out.
        guard Bundle.main.bundleIdentifier != nil else { return }
        let content = UNMutableNotificationContent()
        content.title = "Recording started"
        content.body = "Meeting2 is recording what looks like a meeting. Stop it from the menu bar."
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

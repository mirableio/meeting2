import AppKit
import Foundation
import Meeting2Core

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

    /// Non-meeting mic owners to ignore — shared with the "forgot to stop" nudge. (Our own process
    /// is excluded by PID inside `MicOwnerMonitor`, so it isn't listed here.)
    private static let denylist = MicOwnerMonitor.nonMeetingOwners
    // How long the external owner must be gone before we stop. Kept short: major conferencing
    // apps hold the mic open while muted (so this isn't riding over mutes), it's really only for
    // brief device/route blips — and a long grace makes a short meeting linger as a live recording
    // for minutes before it's evaluated and pruned, which reads as "short recordings are kept".
    private static let stopGraceSeconds: TimeInterval = 20
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
        guard !notificationsRequested else { return }
        notificationsRequested = true
        UserNotifier.requestAuthorization()
    }

    private func notifyStarted() {
        UserNotifier.post(
            title: "Recording started",
            body: "Meeting2 is recording what looks like a meeting. Stop it from the menu bar."
        )
    }
}

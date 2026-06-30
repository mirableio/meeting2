# Auto-detect: start recordings without being asked

The failure this fixes is concrete: you sit down for a meeting and forget to hit Start, and
there's no second chance — the audio is gone. Manual start is a single point of human failure
for the app's entire reason to exist ("never miss a meeting"). Auto-detect removes that point —
**for the meetings it can see.**

This is the **implementation plan** for `INIT.md` §6 (Milestone 4). Where this doc and §6 ever
disagree, **§6 wins**. Auto-detect is a *new trigger* that drives the same recording commands the
menu does, plus a keep/discard decision after the fact. The capture path, file-as-database model,
and post-recording pipeline are unchanged.

## Scope: online (app-mediated) meetings only

The signal is **"some app opened the microphone."** That happens for online calls — Zoom, Teams,
Meet/Slack in a browser, FaceTime — where a conferencing app holds the mic. It does **not**
happen for an **in-person (f2f) meeting**: no app opens the mic, so there is no owner to detect
and nothing to trigger on. The only way to catch f2f would be for Meeting2 to hold the mic open
continuously and listen — which lights the macOS recording indicator forever, a privacy cost we
reject.

**So f2f stays manual, by design.** This is an accepted limitation, called out up front so it
isn't a surprise. The only *non-invasive* way to ever help f2f is a **calendar prompt** ("Record
your 2pm?") — a nudge, not an auto-start — which is deferred to P3. (This corrects an earlier
draft that wrongly claimed duration-pruning could classify f2f; with no owner there is nothing to
start in the first place.)

## The core signal: which external process holds the mic

When the mic goes hot, the question is *which app* turned it on. A call is a conferencing app; a
non-meeting is dictation (`com.apple.assistantd`), Siri, a voice note. So the core signal is the
**external mic owner**, the real filter is a **denylist** of known non-meeting owners, and a
**duration prune** is the backstop for an unknown app that grabs the mic briefly. Self (Meeting2)
is always excluded from "external owner."

## Why device-level activity can't be the stop signal

`kAudioDevicePropertyDeviceIsRunningSomewhere` is a fine *wake-up* — it tells us the input device
just went hot so we can look at who owns it. But it **cannot** tell us when the meeting ends:
once we start recording, *Meeting2 itself* holds the device, so it stays "running somewhere" and
the external owner can disappear with **no device-level edge**. Therefore:

- **Idle path** — use the device listener as a cheap wake-up.
- **Active (recording) path** — **poll** the running-input process owners at low frequency (a few
  seconds) and stop when no external owner remains for the grace period. (A process-list listener
  could replace the poll *if* it proves to fire reliably; the poll is the safe default.)

## Signals and APIs (one subsystem)

- **Mic went hot (wake-up)** — listen to `kAudioDevicePropertyDeviceIsRunningSomewhere` on the
  default input, plus `kAudioHardwarePropertyDefaultInputDevice` to re-bind on device switch.
  Same `AudioObjectReader` + property-listener machinery `SystemTapCapture.swift` already uses.
- **External owners (start gate + recording liveness)** — enumerate audio process objects
  (`kAudioHardwarePropertyProcessObjectList`), keep those with input running
  (`kAudioProcessPropertyIsRunningInput`) and PID ≠ ours, resolve each to a bundle id
  (`kAudioProcessPropertyBundleID` / `…PID` → `NSRunningApplication`). **Verified to typecheck at
  the 14.0 and 14.2 targets** — same Core Audio process-tap family (14.0+) the app already uses;
  the floor is the app's own 14.2. The earlier "14.4+" caveat was wrong.
- **Off the main actor.** These are synchronous HAL reads (`AudioObjectGetPropertyData`) that can
  stall — like the rest of the capture code, the enumeration runs on a small serial queue and the
  result is returned to `MainActor`. The active poll **triggers a fresh read each tick** (the
  device callbacks stop firing once *we* hold the mic, so a cached snapshot would go stale and
  never show the owner leaving) — the read is still off-main, so the main actor never blocks on it.
- **No output/camera subsystem in the core.** Output-active detection stays an *optional later
  add* for the rare listen-only webinar where you never hold the mic. Not needed for keep/discard.

## Lifecycle of an auto recording

1. **Wake-up (idle)** → resolve external owners. If the set minus the denylist is empty, ignore.
   Otherwise **start immediately** — eager, no wait (waiting loses the meeting's opening). Persist
   the **triggering** owner (see "deterministic owner" below) via the start seam; no durable
   "auto" tag.
2. **Notify** — a non-modal "Recording — looks like a meeting." Informational in P1; the escape
   hatch is the existing menu/status-item **Stop** (an *actionable* notification with a
   stop/discard button is extra plumbing → P2).
3. **Watch (recording)** → poll external owners; when none remain for the grace period (~2 min,
   to ride over brief mute/route blips), stop.
4. **Stop via the auto seam, not `stopAndProcess`** → finalize, then decide: if the **external
   owner was active for less than ~30s** **or** both tracks are silent, move the folder to
   **Trash**; otherwise enqueue the normal pipeline. "Short" is measured on *owner-active* time
   (start → owner left), **not** the recording's wall-clock duration — the file also contains the
   ~2 min stop grace, so a 5-second grab is a ~125-second file and would survive a wall-clock test.
   **On uncertainty, keep.** The both-silent check needs a finalized snapshot; if it's unreadable,
   enqueue (or leave for recovery) — **never Trash on uncertainty**.

### Seams: where auto-detect plugs in

**Correction to an earlier draft:** calling `RecordingCoordinator.start()` does *not* light up the
status item, elapsed clock, health monitor, or library row. Those live in `RecorderMenuController`
— it owns the recording *presentation state* and the live monitors, and only *then* calls the
coordinator. `coordinator.start()` alone just starts capture. So auto-detect must drive the same
lifecycle the menu does; the lowest-risk way is to reuse that controller, not reimplement it.

- **Controller — start/stop (the UI lifecycle seam).** Auto-detect calls the controller's
  `startRecording(source:)` and a new `stopAutoRecording()` (UI teardown + the prune-aware
  coordinator stop below). `RecorderMenuController` is really the recording *orchestrator*, not a
  menu widget (the status item is just the renderer); renaming it `RecordingController` makes the
  dependency honest — worth doing while we're already adding these methods, but optional, not a
  blocker.
- **Coordinator — start with a source.** `coordinator.start()` → `MeetingStore.markRecordingStarted`
  only take `outputRoute` today. Add a `MeetingSource` (carrying `micOwnerBundleId`) so the owner
  is persisted at start. The schema field already exists.
- **Coordinator — stop-then-decide.** `stopAndProcess()` enqueues compression/transcription
  *immediately*, so a provisional clip would start processing before we decide to trash it. Add
  `stopAutoRecording(...)` that stops + finalizes, inspects duration/health, then **either**
  trashes **or** enqueues — keep/discard *before* any processing is queued.

**Why not move all session state into the coordinator** (so auto-detect never touches the
controller)? Cleaner in principle, but it relocates a lot of working state — elapsed clock, health
monitor, attention, busy presentation, success flash — at real regression risk. The
controller-command seam (plus an optional rename) gets the same decoupling (auto-detect depends on
a *recording* controller, not "the menu") for far less churn. The bigger refactor can come later.

## Prune means Trash — and so does user delete

For a "never miss" recorder, automatic *permanent* deletion is the wrong default: a real call
that ran short, or one mis-flagged as silent, would be unrecoverable. `FileManager.trashItem` is
one API call, OS-native, reversible for ~30 days — the Trash *is* the "pending review" state, no
custom queue needed (`INIT.md` §6.2). **User-initiated delete already trashes too**
(`RecordingCoordinator.deleteRecording`), so both paths are consistent and recoverable.
Owner-suppression also keeps the Trash from filling with dictation clips, since those are
filtered before they're ever recorded.

## What we deliberately reject

- **Auto-detecting f2f** — impossible without holding the mic open continuously (privacy cost).
  Manual start; calendar prompt is the only future non-invasive help (P3).
- **Device-cold as the stop signal** — we hold the device while recording; poll external owners.
- **A multi-state confidence machine / keep-boosters** — eager-start + denylist +
  prune-short/silent reaches the goal with far less code (`INIT.md` §6.2).
- **Calendar-only or app-list triggering** — calendar is for naming/prompting later; an app list
  is a maintenance treadmill the mic-owner signal subsumes.

## Trust, privacy, consent

- **Opt-in, off by default.** The opt-in toggle is the *only* settings UI in P1; everything else
  ships as constants + logs (tuning/editing is P2). First-run explains it watches mic
  *activity/owner*, not content, and everything stays local.
- **Always announce a start**, always offer an instant **Stop** (via the menu/status item). A
  one-tap *discard* action is P2.
- **Optional short pre-roll** (ring-buffered, ≤ a few seconds) is **default off**: continuous
  capture lights the macOS recording indicator, a real privacy cost.
- **Consent is regulated** for call recording in some places; off-by-default + the start
  notification is the minimum.

## Phases

- **P1 — MVP (online meetings).** `MicOwnerMonitor` (device wake-up + published external-owner
  set, reads off-main, self excluded) + `AutoRecordController` (denylist gate → eager start →
  poll-while-recording → stop on owner-gone grace → keep/prune, keep-on-uncertainty). Seams: add
  `startRecording(source:)` / `stopAutoRecording()` to the controller (optional rename to
  `RecordingController`); coordinator `start(source:)` and `stopAutoRecording`. Opt-in toggle + **informational**
  notification + hardcoded constants (denylist, ~30s threshold, ~2 min grace) + logs.
- **P2 — Refinement.** Actionable notification (stop/discard button); tune the denylist from real
  usage; make threshold/grace/denylist editable; add the optional output-active signal for
  listen-only webinars.
- **P3 — Calendar.** Name recordings from the event happening now; **calendar prompt** for f2f
  meetings (the case auto-detect structurally can't catch).

## Sketch: `MicOwnerMonitor` and `AutoRecordController`

Illustrative, not final — shows the wake-up vs. poll split, self-exclusion, and the two seams.

```swift
/// Watches the default input device. Fires a wake-up edge (device went hot) for the idle path,
/// and publishes the current external mic owners (Meeting2 excluded) for the active poll. All HAL
/// reads run on a private serial queue; results are published to MainActor. Never touches capture.
final class MicOwnerMonitor {
    @MainActor var onWake: (() -> Void)?                           // device went hot — go look

    private let queue = DispatchQueue(label: "mic-owner-monitor")  // all AudioObject reads here

    func start() { /* listen DeviceIsRunningSomewhere + DefaultInputDevice; callbacks → onWake */ }
    func stop()  { /* remove listeners */ }

    /// Reads the live external-owner set on the serial queue and returns it. Both the wake-up
    /// check and the active poll call this — there is no cached snapshot, because once we hold the
    /// mic the device callbacks stop firing and a cache would never show the owner leaving.
    func refreshExternalOwners() async -> Set<String> {
        await withCheckedContinuation { cont in
            queue.async {
                // Enumerate kAudioHardwarePropertyProcessObjectList; keep those with
                // kAudioProcessPropertyIsRunningInput and PID != getpid(); resolve to bundle ids.
                cont.resume(returning: [])
            }
        }
    }
}
```

```swift
/// Policy: denylist gate at start, poll-driven stop, keep/prune. Drives the recording controller
/// (which owns the status item state, elapsed clock, health monitor, notifications).
@MainActor
final class AutoRecordController {
    private let controller: RecordingController     // RecorderMenuController (optionally renamed)
    private let monitor = MicOwnerMonitor()
    private var pollTask: Task<Void, Never>?

    private static let denylist: Set<String> =
        ["com.apple.assistantd", "com.apple.VoiceOver" /* + dictation, Meeting2 */]

    func enable() {
        monitor.onWake = { [weak self] in self?.maybeStart() }
        monitor.start()
    }

    private func maybeStart() {
        guard controller.canStart else { return }
        Task {
            let owners = await monitor.refreshExternalOwners().subtracting(Self.denylist)
            guard !owners.isEmpty, controller.canStart else { return }
            let owner = owners.sorted().first!   // deterministic: Sets are unordered (log them all)
            controller.startRecording(source: MeetingSource(micOwnerBundleId: owner))
            // notify (informational); startPolling()
        }
    }

    private func startPolling() {
        pollTask = Task {
            var goneSince: ContinuousClock.Instant?
            while !Task.isCancelled, controller.canStop {
                let live = !(await monitor.refreshExternalOwners()).subtracting(Self.denylist).isEmpty
                // track how long the owner's been gone; once past grace:
                //   controller.stopAutoRecording()  // finalize → keep/prune (keep on uncertainty)
                try? await Task.sleep(for: .seconds(5))
                _ = (live, goneSince)
            }
        }
    }
}
```

Wiring: in `AppDelegate`, build an `AutoRecordController(controller:)` next to the recording
controller and library, and `enable()` it when the opt-in is on. Because it calls the **same
controller commands the menu does**, the status item, live row, elapsed clock, health monitor, and
pipeline all behave exactly as for a manual start.

## Open questions

- **Threshold / grace** — ~30s prune, ~2 min stop grace (per `INIT.md`); P1 constants, P2 settings.
- **Poll cadence** — a few seconds is plenty; confirm it's not noticeable and survives sleep/wake.
- **Mute/route blips** — confirm common apps keep the device open while muted (so we don't false-
  stop); the grace period is the cushion.
- **Denylist coverage** — filters only *known* non-meeting owners; an unknown brief grab gets
  recorded then pruned. Honest limitation; the prune is the backstop.
- **Self-exclusion** — exclude by PID (not bundle id) so our own capture never reads as an owner.
- **Deterministic owner** — when several apps hold the mic at once, the schema stores one. Pick the
  one that *triggered* the start (or a stable sort), and log the full set; never `Set.first` (it's
  unordered).
- **Trailing grace audio** — a *kept* recording still contains the ~2 min stop grace after the
  meeting actually ended (the file runs start → owner-left + grace). Pruning is judged on
  owner-active time, so this doesn't affect keep/discard, but every kept auto recording is ~2 min
  longer than the call. Acceptable for now; revisit if it's annoying (shorten the grace, or trim
  the tail) — most conferencing apps hold the mic open while muted, so a shorter grace may be safe.

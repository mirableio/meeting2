# Background processing: isolation, progress, and recording-time visibility

How the app turns finished recordings into transcripts is a **stateless reconciler sweep**:
`MeetingStore.scan()` lists every meeting folder, builds a `MeetingSnapshot` from file
presence, and each job (`CompressionJob`, `TranscriptionJob`) exposes a pure `needsWork`
predicate. `PostRecordingPipeline` runs the sweep in two serial, stage-grouped passes —
compress every pending item, then transcribe every pending item — one at a time.

That design is right and we keep it. But three gaps surface once there is *more than one*
pending item, or work overlapping a new recording. This plan fixes them. It does **not**
change the capture path, the file-as-database model, or the serial-by-default policy.

## Problems, precisely

1. **Starvation on a poison item.** The transcription loop is
   `for snapshot in pending { try await job.perform(...) }`. `perform` marks the folder
   failed in metadata *and rethrows*, so the loop aborts — items after the failure are not
   attempted this run. Because `meetingFolders()` is oldest-first, a persistently-failing
   oldest item (a too-long meeting that times out, a corrupt file, a hard API error) is
   retried first on **every** sweep and aborts before reaching newer items. One bad meeting
   blocks transcripts for all meetings recorded after it, indefinitely. This directly breaks
   "never miss a meeting."

2. **No sense of how many are pending.** While a batch runs the menu says only
   `Transcribing…` — no "2 of 3". When idle with pending items (e.g. you set the key later,
   or several failed), there is no count anywhere; `Transcribe Pending Recordings` shows no
   number. The pipeline knows `pending.count` and the loop index but never surfaces them.

3. **A new recording hides an in-flight transcription.** `startRecording()` clears
   `processingActivity`, so the `Transcribing…` line and green pulse vanish even though the
   transcription keeps running in the background (separate task, different folder — safe).
   When it finishes mid-recording, `handlePostRecordingFinished` early-returns on
   `state != .idle`, so it completes with no trace. Visibility is lost; the completion is
   silent.

## Principles carried in

- **Items are independent.** A reconciler must make progress on every healthy item
  regardless of a sick one. Per-item failure is normal and must not be fatal to the batch.
- **Files remain the source of truth.** Per-folder job status is already persisted by
  `perform`; in-memory results only need to *report* outcomes honestly to the UI.
- **The icon reflects capture; background work lives in the menu.** The menu-bar dot belongs
  to recording state. Anything happening after a recording is surfaced in the dropdown.
- **Serial, minimal, no over-engineering.** No concurrency (concurrent Gemini uploads invite
  rate-limits and complicate the hot path). No new durable state unless a fact can't be
  re-derived from files.

---

## Change 1 — Per-item failure isolation (correctness, do first)

**Approach:** the batch loops catch each item's error, record `{folder, message}`, and
**continue**. The run returns successes *and* failures; it no longer aborts mid-batch. Global
failures — the transcriber can't be *built* at all (missing key) — still throw *before* the
loop, exactly as today, and touch no per-recording state (the P2.2 contract).

**Order retries last.** Isolation stops a bad item from *blocking* others, but oldest-first
ordering would still run a stuck item *first* and delay the fresh ones — and with the new
600s Gemini timeout that delay is minutes, every sweep. So order the pending list
**never-failed-first, previously-failed-last** (oldest-first within each), keying off the
existing `jobs.transcription.status == .failed` — no new durable state. Fresh meetings get
their transcripts promptly; a poison item retries at the back, where its slow timeout costs
nothing.

**Resilient scan.** Isolation in the loop is only half the promise: `MeetingStore.scan()`
itself throws if a single folder's `meeting.json` is unreadable, aborting the sweep *before*
the loop. Make `scan()` skip-and-log a folder it can't snapshot (a `try?` per folder) so one
corrupt folder can't freeze all background work. Atomic writes make corruption unlikely, but
the reconciler should degrade by skipping the bad folder, not stalling every other meeting.
Keep it to the `try?` + log — nothing more.

**Loop shape (transcription; compression is symmetric):**

```swift
var results: [MeetingTranscriptionResult] = []
var failures: [PostRecordingFailure] = []
let total = pending.count
for (index, snapshot) in pending.enumerated() {
    onProgress?(PostRecordingProgress(phase: .transcribing, current: index + 1, total: total))
    do {
        results.append(try await job.perform(folder: snapshot.folder, store: store, transcriber: transcriber))
    } catch {
        // `perform` has already marked this folder failed in metadata; record it for the UI.
        failures.append(PostRecordingFailure(folder: snapshot.folder, message: String(describing: error)))
    }
}
```

**Result type** gains the failures (kept `Equatable` by storing a message, not an `Error`):

```swift
public struct PostRecordingFailure: Equatable {
    public let folder: URL
    public let message: String
}

public struct PostRecordingPipelineResult: Equatable {
    public let compressionResults: [MeetingCompressionResult]
    public let transcriptionResults: [MeetingTranscriptionResult]
    public let compressionFailures: [PostRecordingFailure]
    public let transcriptionFailures: [PostRecordingFailure]
}
```

**Controller handling** splits cleanly:
- `handlePostRecordingFinished` (the run returned): clear `processingActivity`. If
  `transcriptionFailures` is non-empty → `addAttention(.transcriptionFailed)` and message
  "Transcribed N, M failed"; else `clearAttention(.transcriptionFailed)`, "✓ Transcribed N",
  success flash.
- Compression failures (`compressionFailures`) get a **minimal surface** — a status line
  ("Couldn't finish N recording(s); audio is safe") — **not** a new attention badge. They're
  rare, the raw CAFs are preserved, and the same pending sweep retries them. Add a badge only
  if they prove common.
- `handlePostRecordingFailed` (the run threw — i.e. a global/config failure): unchanged,
  including the missing-key suppression. Per-item failures never reach here now.

**Non-goals (deferred):** concurrency; a failure-count + backoff in `meeting.json` to stop
re-attempting a known-poison item after N tries — worth it eventually, but it's new durable
state, so not now.

**Files:** `PostRecordingPipeline.swift`, `CompressionJob.swift`/`TranscriptionJob.swift`
(only the `runPending*` loops if they keep their own; the pipeline owns the batch loops),
`main.swift` (the two handlers). **Tests:** a batch where item 1 fails and items 2–3 still
get transcribed; a batch where all fail reports failures without throwing; a global config
failure still throws and stains nothing.

---

## Change 2 — Progress and pending count (UX)

### 2a. Live "N of M" while running (rides on Change 1)

Replace the phase-only callback with a progress value carrying counts. Reuse the existing
`PostRecordingPhase` as the stage:

```swift
public struct PostRecordingProgress: Sendable, Equatable {
    public let phase: PostRecordingPhase   // .compressing / .transcribing
    public let current: Int                // 1-based index of the item in progress
    public let total: Int                  // pending count for this stage
}
public typealias PostRecordingProgressHandler = @Sendable (PostRecordingProgress) -> Void
```

`onPhase` params on `runAfterRecording` / `runPendingCompressionAndTranscription` /
`runPendingTranscriptionOnly` / `RecordingCoordinator.*` become `onProgress`, emitted **per
item** (see the loop above).

Controller's `ProcessingActivity` carries the counts and composes the label:

```swift
enum ProcessingActivity: Equatable {
    case processingAudio(current: Int, total: Int)
    case transcribing(current: Int, total: Int)

    var headerText: String {
        switch self {
        case let .transcribing(current, total):
            return total > 1 ? "Transcribing \(current) of \(total)…" : "Transcribing…"
        case let .processingAudio(current, total):
            return total > 1 ? "Processing audio \(current) of \(total)…" : "Processing audio…"
        }
    }
}
```

So the header reads `Transcribing 2 of 3…  4:30` (the batch elapsed clock still appends, and
stays out of `menuSignature` so it ticks the header in place). **The "N of M" count is shown
only when `total > 1`** — a single pending item reads `Transcribing…`, never `1 of 1`. The
batch clock starts when transcription begins and does **not** reset per item (it measures
total transcription time).

### 2b. Idle "N pending" on the button (smaller follow-up)

When nothing is running but meetings await transcription, surface it on the existing action:
`Transcribe N Pending Recordings`, hidden at zero. The menu build is synchronous and can't
`await` a store scan, so the controller keeps a cached `pendingTranscriptionCount` refreshed
by an async `refreshPendingCount()` (scan → count `TranscriptionJob.needsWork`). Refresh
triggers: on launch, after each post-recording run completes, and on `menuWillOpen` (the
live-refresh timer picks up the updated value). This is the only piece needing a new path, so
it's separable from 2a.

**Files:** `PostRecordingPipeline.swift`, `RecordingCoordinator.swift`, `main.swift`
(`ProcessingActivity`, `applyProgress`, `progressHandler`, `menuStatusHeader`, cached count),
`StatusItemController.swift` (button label + `menuSignature`).

---

## Change 3 — Background transcription visible during a recording (UX, last)

**Scope (corrected):** the transcription already keeps running across a new recording, and the
completion handler already does the right thing — so this is smaller than first written. Two
edits only.

- **The only real bug: `startRecording` clears `processingActivity`.** Stop clearing it. The
  masking that already makes `iconState` and `menuStatusHeader`'s recording branch ignore
  `processingActivity` stays — so the icon remains the recording dot, untouched. This also
  removes the stray-callback race (the masking becomes the single source of truth instead of
  racing a clear).
- **Completion already behaves — no change there.** `handlePostRecordingFinished` already
  clears `processingActivity`/`transcribingStartedAt` *before* its `state == .idle` guard, and
  only flashes the icon + sets the success message when idle. So a mid-recording completion
  already drops the line cleanly and leaves the recording icon alone.
- **Add one dimmed secondary line** in the menu, shown only when recording **and**
  `processingActivity != nil`:

  ```
  ● Recording  2:14
    Transcribing previous · 2 of 3…  3:30
  ──────────
  Stop Recording
  ```

  Implemented as a second `header(...)`-style item; its text comes from a new
  `backgroundActivityText` computed on the controller, and it must be added to
  `menuSignature()` so the open menu rebuilds when it appears/clears.

**Considered and rejected:** a transient notification/toast — heavier, and the menu is where
this app already lives.

**Files:** `main.swift` (`startRecording` — remove the clear; `backgroundActivityText`),
`StatusItemController.swift` (`populate`, `menuSignature`). `handlePostRecordingFinished`
needs no change.

---

## Sequencing

| Step | Change | Type | Notes |
|------|--------|------|-------|
| 1 | Per-item isolation + resilient `scan()` + aggregate failures | correctness | highest value; removes starvation |
| 1b | Failed-last ordering for transcription | correctness | a few lines on the same list; uses existing job status |
| 2a | Live "N of M" progress | UX | one change with step 1 (same loops/callback) |
| 2b | Idle "N pending" on the button | UX | needs the cached count; separable |
| 3 | Background line during recording | UX | stop the clear + one secondary line; lowest priority |

Do **1 + 1b + 2a together** (they all touch the same two batch loops, the pending list, and
the same callback), land and verify, then decide 2b and 3 independently.

## Out of scope (tracked elsewhere / future)

- **Streaming transcription** (`streamGenerateContent`) — the durable fix for long meetings
  and the root cause behind the timeout-poison item; separate from this plan.
- **Concurrency** across items, and **failure-count backoff** to retire a permanently-bad
  item — only if a real backlog or a stuck item proves it necessary.

# Recordings library window

The app is menu-bar only today: you can start/stop and see status, but there's no way to
*browse* what you've recorded. This adds a **recordings library** — one window that lists your
meetings, their status, and the few operations you actually need (open transcript, open folder,
delete, re-transcribe), with search and status filters.

It is deliberately a **small** surface. It comes *before* auto-detect and calendar, so it must
not assume either exists. No master-detail pane, no transcript preview, no attendees, no
calendar sync — those are later. The point now is "see my recordings and do the obvious things
to them."

## Principles carried in

- **Stay a menu-bar app.** The window is on-demand, opened from the dropdown; closing it leaves
  the app running in the menu bar. We are not becoming a Dock-first app.
- **Files are the source of truth.** The list is just a render of `MeetingStore.scan()`. No
  separate database, no cached index to drift. Every row is a folder.
- **One shared service, not parallel ones.** Today `RecorderMenuController` *privately* creates
  its own `RecordingCoordinator` (which owns the store + pipeline). The library must use the
  **same** instance, or a second pipeline/store would diverge — worst case two concurrent
  transcriptions, defeating the serialization the background work relies on. So we hoist **one**
  `RecordingCoordinator` up into `AppDelegate` and inject it into both the menu controller and the
  library. There is one path for rename, delete, and re-transcribe.
- **SwiftUI for the window, AppKit for the menu-bar icon.** The icon needs colour/animation that
  SwiftUI's `MenuBarExtra` can't do (that's why it's an `NSStatusItem`), but a *list* is exactly
  what SwiftUI is good at — `List`, `.searchable`, sections, context menus. The app keeps its
  manual AppKit lifecycle; the window is SwiftUI hosted in an `NSWindow`.
- **Minimal, no over-engineering.** Scroll, not pagination. One window, not a navigation stack.

---

## The window

**Opened from the menu** — a `Recordings…` item in the dropdown (`⌘0` or similar later). One
window, created lazily and reused; re-opening brings the existing one forward rather than making
a second.

**Hosted in an `NSWindow` via `NSHostingController`.** The app runs a manual `NSApplication`
loop with an `AppDelegate`, so we don't adopt the SwiftUI `App`/`WindowGroup` lifecycle; we just
host one SwiftUI root view in a standard resizable `NSWindow`. Default ~640×560, remembers size
and position (`setFrameAutosaveName`).

**Activation policy flips while the window is open.** An `LSUIElement` (`.accessory`) app can
show windows, but they get weak focus and no cmd-tab/Dock presence. So: on show, switch to
`.regular` and `NSApp.activate(ignoringOtherApps:)`; on close, switch back to `.accessory`. The
result is a window that behaves like a normal app window while open, and a pure menu-bar app the
rest of the time. **This flip is owned entirely by `RecordingsWindowController`** — it observes
`NSWindowDelegate.windowWillClose` and flips back on *every* close path (close button, ⌘W,
programmatic). It is never tied to the view-model's lifetime or to SwiftUI, so the app can't get
stranded in `.regular`.

---

## Layout

```
┌─────────────────────────────────────────────┐
│  [All ▾]                       🔍 Search…     │   ← toolbar: status filter + search
├─────────────────────────────────────────────┤
│  Today                                        │   ← date section header
│   ● Weekly Sync          2:30 PM · 47 min  ✓ │   ← row
│   ● 1:1 with Sam         11:00 AM · 25 min  … │
│  Yesterday                                    │
│   ● Design review        4:10 PM · 1h 2m   ⚠ │
│  Jun 3                                        │
│   …                                           │
└─────────────────────────────────────────────┘
```

**Row anatomy**, left → right:
- a **status dot** (colour-coded, see Status model);
- the **name** (bold, inline-editable);
- a **subtitle**: start time + duration, e.g. `2:30 PM · 47 min`;
- a trailing **status affordance**: a check when transcribed, a small spinner + `2 of 3…` while
  transcribing, a ⚠ / `Retry` when something needs attention.

**Sections by day**, newest first: `Today`, `Yesterday`, then `MMM d` headers. Within a section,
newest first.

**Empty states:** no recordings yet → "No recordings yet — start one from the menu bar." Search/
filter with no matches → "Nothing matches."

---

## Navigation — scroll + sections, not pagination

"Go to previous dates" is just **scrolling down** a single lazy list grouped by day. We
deliberately avoid pagination: it's a web paradigm that feels wrong on the Mac and adds state
(page numbers) for no benefit. `List` is already lazy, so this scales fine for personal volumes
(hundreds of meetings). Finding an *old* meeting by name is handled by **search**, so you rarely
need to scroll far. If volume ever reaches thousands and a month-jump is wanted, that's an
additive later feature — not the minimum.

---

## Status model

One enum drives both the row badge and the filters, derived from what `MeetingSnapshot` already
exposes (`state`, `metadata.jobs.transcription.status`, `audioHealth`, plus the live
recording/processing state the app already tracks):

| Status | Source | Dot |
|---|---|---|
| `recording` | the live session's folder | red |
| `processing` | being merged/compressed | green (pulse) |
| `transcribing` | pipeline working on it | green (pulse) + `N of M` |
| `transcribed` | `transcript.json` present | green ✓ |
| `notTranscribed` | finalized, no transcript, idle | grey |
| `failed` | `jobs.transcription.status == .failed` | orange |
| `needsAttention` | interrupted / incomplete / a silent track (`audioHealth`) | orange ⚠ |

**The live/in-flight statuses are *not* free from `scan()` — they need a small overlay.** Two
gotchas:
- A **live recording** has both CAFs and no `endedAt`, which `deriveState` reads as
  `.interrupted` — i.e. without help it would show under **Errors**, alarmingly wrong. So we
  overlay the coordinator's `currentFolder`: the one folder that equals it is `recording`,
  regardless of what the files say.
- **`transcribing`** is inferable from the file-derived job status (`meeting.json`
  `jobs.transcription.status == .running`, set by `markTranscriptionRunning`).
- **Compression has no per-folder signal** (it's purely file presence, and `PostRecordingProgress`
  carries phase/current/total but *no folder*). It's also brief. So the first slice does **not**
  promise a distinct "compressing this row" state — a mid-compression row just reads as
  `notTranscribed`/processing generically. If we later want exact per-row in-progress
  highlighting, the clean way is to add `folder` to `PostRecordingProgress`; not now.

(Decision flagged: include the live + transcribing rows. If you'd rather the window list *only
completed* recordings, drop the `currentFolder` overlay and the `.running` badge.)

---

## Status filters

A filter control in the toolbar (a segmented control), mapping to the status model:

- **All** — everything.
- **Pending** — not done and not broken: still recording, being transcribed, or awaiting one
  (`recording` / `transcribing` / `notTranscribed`). The "still needs a transcript" pile.
- **Errors** — `failed` + `needsAttention`. The "something's wrong" pile (this is the one you
  open to find what to retry).

(There is deliberately no **Transcribed** filter — three buckets proved clearer than four, and
finished recordings are the common case you see under **All** anyway.)

Filter and search **compose** (filter narrows the set, search narrows further). The current
filter is view state on the view-model, not persisted (resets to All each open) — simplest, and
re-opening to a clean slate is the expected behaviour.

**Caveat — a folder with unreadable `meeting.json` won't appear at all.** `scan()` now
skip-and-logs a corrupt folder, so it shows in *no* list, including **Errors**. That's accepted
for this UI (corruption is rare and the skip is logged, not silent). Surfacing such folders as a
visible error row would mean `scan()` returning an "unreadable" list too — over-engineering for
now; revisit only if it actually happens.

---

## Search + inline rename

**Search** is a `.searchable` toolbar field filtering by `displayName` substring,
case-insensitive, across *all* dates. It's the primary way to reach an old meeting by name.

**Rename is inline and JSON-only.** Click the name → it becomes a `TextField`; commit writes
`displayName` into `meeting.json` via a new `MeetingStore.setDisplayName(folder:_:)`. The
**folder is not renamed** — the folder's timestamp prefix is the stable identity and the slug is
cosmetic; editing only the JSON keeps the identity fixed and avoids renaming a directory whose
files might be open. The Finder folder name can drift from the display name; that's an accepted
trade for safety and simplicity.

**Calendar precedence (designed-for, not built):** when calendar naming lands it must not clobber
a manual edit. We won't build the flag now, but the rename path is the spot where a future
`displayNameIsUserEdited` marker would be set — noting it so we don't paint ourselves in.

---

## Operations

Native pattern: a **right-click context menu** on a row, mirrored by a **toolbar** acting on the
selected row. Four operations:

- **Open transcript** → `NSWorkspace.shared.open(transcript.md)`; enabled only when a transcript
  exists. Opens in the user's default Markdown app, per the requirement.
- **Open folder** → reveal the recording folder in Finder
  (`NSWorkspace.activateFileViewerSelecting`).
- **Delete** → a confirmation alert, then **move to Trash** (`FileManager.trashItem`), never
  `rm`. A "delete my meeting" action must be recoverable. The row disappears on success
  (re-scan / optimistic removal).
- **Re-transcribe** → remove `transcript.json` + `transcript.md` and reset the transcription job
  status to pending, which makes the reconciler's `needsWork` true again, then kick the pending
  sweep. This reuses everything from the background-processing work — no new transcription path.

**Destructive actions are disabled for in-flight rows.** Delete and Re-transcribe must not run on
a recording that is being written: the **live recording** (`currentFolder`) or anything currently
**transcribing** (`.running`). Otherwise the library races open CAF writes, the transcript write,
or a metadata update — corruption or lost work. The UI disables those items on those rows; the
coordinator methods *also* refuse them as a safety net (the UI can't pinpoint a brief
mid-compression folder, so the guard is the real protection, the dimming is just clarity).

**Where the mutations live:** the view-model calls the existing command surfaces, not the
filesystem directly, so there's one authority:
- `MeetingStore.setDisplayName(folder:_:)` — rename (new).
- `MeetingStore.clearTranscript(folder:)` — **delete `transcript.json`/`transcript.md` first,
  then reset the job status to pending** (new). Order is the crash contract: if it dies between
  the two, the missing `transcript.json` already makes `TranscriptionJob.needsWork` true, so the
  next sweep heals. Idempotent.
- `RecordingCoordinator.deleteRecording(folder:)` — trash the folder (new); refuses the current
  recording.
- `RecordingCoordinator.reTranscribe(folder:)` — `clearTranscript` then
  `runPendingTranscriptionOnly` (new; reuses the pipeline + progress handler); refuses a folder
  that's currently recording or transcribing.

---

## Live updates

The list must reflect reality without the user re-opening the window. Strategy, simplest-first:

1. **Reload on open** (and when the window becomes key).
2. **Reload on app events we already emit** — a recording stops, a post-recording run finishes,
   the pending count changes. Rather than couple the library view-model to the menu controller's
   presentation state, post a lightweight `NotificationCenter` signal
   (`.meetingLibraryDidChange`) from the points that already mutate recordings
   (`RecordingCoordinator` / the post-recording handlers); the view-model observes it and reloads.
3. **A slow timer (~2 s) while the window is visible** as a backstop, so externally-driven
   changes (a CLI tool run, a manual file delete) still surface.

FSEvents (watch the recordings directory) is the "nicer" version and would replace the timer —
**deferred**; the timer backstop is enough for the minimum and far less code.

Reloads are cheap: `scan()` is a directory listing + small JSON reads, already resilient to a bad
folder.

---

## Architecture / new pieces

- **`LibraryItem`** (value type, `Identifiable`): the row's data, derived from a `MeetingSnapshot`
  so the view never touches raw snapshots. Roughly:
  `{ id: URL (folder), name, startedAt, durationSeconds?, status: LibraryStatus, hasTranscript,
  transcriptMarkdownURL? }`.
- **`RecordingsLibraryViewModel`** (`@MainActor`, `ObservableObject`):
  - `@Published items`, `@Published searchText`, `@Published filter`;
  - `visibleSections` (computed: filter → search → group-by-day);
  - `reload() async`, `rename(_:to:)`, `delete(_:)`, `reTranscribe(_:)`, `openTranscript(_:)`,
    `openFolder(_:)`.
  - Loads via the **shared** coordinator's `store.scan()`, then **overlays the coordinator's
    `currentFolder`** so the live recording reads `recording` (not the file-derived
    `.interrupted`). Mutates via the store/coordinator methods above.
- **SwiftUI views:** `RecordingsWindowView` (toolbar + list), `RecordingRow`.
- **`RecordingsWindowController`** (`@MainActor`): creates/reuses the `NSWindow`, hosts the
  SwiftUI root via `NSHostingController`, and performs the `.regular`⇄`.accessory` activation
  flip on show/close.
- **Shared service + wiring:** `AppDelegate` creates the **one** `RecordingCoordinator` and
  injects it into `RecorderMenuController` (its `init` changes to take a coordinator instead of
  making its own) and into the library (view-model + window controller). `RecorderMenuController`
  gains an `openRecordings()` command; `StatusItemController` adds the `Recordings…` item.

The menu controller and the library view-model share that one coordinator/store and both reload
on the same `.meetingLibraryDidChange` signal — no second pipeline, no shared mutable UI state
between them.

---

## Sequencing

| Step | Piece | Notes |
|------|-------|-------|
| 0 | Hoist the one `RecordingCoordinator` into `AppDelegate`, inject into `RecorderMenuController` | prerequisite refactor; no behaviour change, keeps tests green |
| 1 | Window shell + activation flip + `Recordings…` menu item | empty window first, prove the lifecycle |
| 2 | `LibraryItem` + `RecordingsLibraryViewModel.reload()` + the list with date sections + status dots | read-only browse |
| 3 | Search + status filter | view state only |
| 4 | Operations: open transcript, open folder, delete (+confirm), re-transcribe | the new store/coordinator methods |
| 5 | Inline rename (`setDisplayName`) | JSON-only |
| 6 | Live updates (notification + timer backstop) | last, since 1–5 work on reload-on-open |

Land 1–2 first (you can *see* your recordings), then layer the rest.

## Out of scope (later / deliberately not now)

- **Master-detail / transcript preview / search-within-transcript** — open-in-default-app covers
  reading for now.
- **Calendar sync + attendees** — separate track; rename is designed to coexist with it.
- **FSEvents** live watching — timer backstop suffices initially.
- **Bulk select / multi-delete**, sort options, column views.
- **A second "live recording" control surface** — start/stop stays in the menu; the window only
  *reflects* the live row (and a Stop action on it, at most).

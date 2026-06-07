# Meeting2 — Implementation Plan (INIT)

**Date:** 2026-06-04
**Status:** Detailed build plan. Supersedes nothing in [PROJECT.md](../PROJECT.md) — it *implements* it. PROJECT.md is the "what & why"; this is the "how," down to APIs, schemas, and acceptance criteria.
**Audience:** the person writing the Swift.

> Read [PROJECT.md](../PROJECT.md) first for the rationale behind every decision. This document does not re-argue them; it turns them into concrete work. Where this plan adds a decision PROJECT.md didn't make, it's marked **[NEW]**. Where the reference apps (`anarlog`, `meetily`) give us code to translate — or fail to — it's called out inline so we know what is cribbable vs. net-new.

---

## 0. Ground truth from the references (so we go in eyes-open)

We verified the two reference codebases at the source level. The findings that shape this plan:

| Thing | anarlog | meetily | Consequence for us |
|---|---|---|---|
| System-audio API | Core Audio tap (`cidre`), aggregate device `hypr-audio-tap`; **no SCK** | Core Audio tap **and** ScreenCaptureKit, `default()` → CoreAudio on macOS | Tap-primary is confirmed by both. **Cribbable as a recipe, not as code** — both are Rust+`cidre`; we write Swift+AudioToolbox. |
| Mic | `cpal` | `cpal` | No Swift reference. We use AVAudioEngine (easy, well-trodden). |
| Real-time DSP | **AEC (~200 lines)**, no mixing (keeps **separate L/R tracks**) | mixing + Silero VAD + RNNoise + soft-limit | anarlog already validates separate tracks. We skip all DSP. |
| On-disk audio | `audio.mp3` (16 kHz, in-process encoder) | `audio.mp4` (AAC, **external ffmpeg**) | We use CAF→M4A via AVFoundation — **no ffmpeg dependency** (a win over meetily). |
| Storage | SQLite (+ TinyBase in UI), `sessions/{uuid}/` | SQLite, `~/Movies/meetily-recordings/<name>/` | We use files only (PROJECT.md decision #1). |
| Mic-in-use detect | `kAudioDevicePropertyDeviceIsRunningSomewhere` + property listener; **per-process input ownership** (process objects → `is_running_input()`); 1 s poll fallback | none | **Cribbable recipe** — gives us both "mic active" *and which process holds it*. |
| System-**output**-active detect | **not present** | not present | Not needed for the core trigger — **per-process mic ownership** (above) already distinguishes a call from media playback. Output-active stays an *optional* later add (listen-only webinars). |
| Meeting-app detect | bundle-ID list `us.zoom.xos`, `Cisco-Systems.Spark`, `com.microsoft.teams`; callback is **commented out** | none | App detection is weak and **misses browser Google Meet entirely**. We lean on audio-activity, not app identity. |
| Route/device-change handling | polls sample rate; **no listeners** | polls in IO proc | **Net-new. [NEW]** We add real property listeners for robustness (this is a top reliability risk). |
| Gemini / working transcript quality | absent / pyannote | absent / broken | No reference. Our two-track→Gemini approach is net-new and is gate #3. |

**Net:** the riskiest *technical* piece (the tap) is a recipe we can translate; the riskiest *product* piece (two-track Gemini transcription quality) and the top *reliability* gap (route-change robustness) have **no working precedent in either repo** and must be proven by spike. Detection, by contrast, is fully cribbable once we trigger on *which process holds the mic* rather than on output activity.

---

## 1. Target environment & toolchain

- **OS:** macOS 14.2+ (Apple Silicon). 14.2 is the floor because `CATapDescription` / `AudioHardwareCreateProcessTap` ship in 14.2. Set `MACOSX_DEPLOYMENT_TARGET = 14.2`.
- **Language/UI:** Swift 5.10+, SwiftUI. One app target, one process.
- **Dependencies:** **Apple frameworks only, with one deliberate exception.** No SPM packages, no ffmpeg, no servers. Frameworks: `CoreAudio` / `AudioToolbox`, `AVFoundation`, `EventKit`, `ServiceManagement`, `AppKit` (`NSWorkspace`), `Security` (Keychain), `SwiftUI`, `os` (logging/signposts). The one exception: **vendor `TPCircularBuffer`** (a single public-domain C header) for the IOProc→writer handoff. Hand-rolling a correct lock-free SPSC ring is the riskiest small code in the project; one audited file used by virtually every serious macOS audio app is more minimal-in-spirit than getting memory barriers wrong ourselves.
- **Signing:** local "Personal Team" (free Apple ID) so the code signature is stable and TCC permissions persist across rebuilds. No paid Developer Program needed for personal use.
- **Repo layout:**
  ```
  Meeting2/
    Meeting2.xcodeproj
    Sources/
      App/            AppController, MenuBarExtra, windows
      Capture/        SystemTap, MicCapture, TrackWriter, AudioClock
      Detect/         MicActivity, MicOwners, MeetingTrigger, Denylist
      Store/          Meeting, MeetingStore, AtomicJSON, FolderLayout
      Reconcile/      Reconciler, CompressionJob, TranscriptionJob
      Transcribe/     Transcriber (protocol), GeminiTranscriber, TranscriptSchema
      Calendar/       CalendarNamer
      Util/           TPCircularBuffer (vendored), RMS, Log, Keychain
    Tests/
    plans/
  ```

---

## 2. Architecture & threading model

Object graph (matches PROJECT.md; concrete Swift types):

```
AppController                         // root; owns lifecycle, wires everything
├── MeetingTrigger                    // emits .start / .stop
│   ├── MicActivity                   // CoreAudio listener: is input running?
│   └── MicOwners                     // which process holds the mic (bundle id)
├── Recorder                          // owns the single RecordingSession (one at a time)
│   └── RecordingSession
│       ├── SystemTap                 // process tap → TPCircularBuffer → system.caf
│       ├── MicCapture                // AVAudioEngine tap → writes mic.caf directly
│       └── TrackWriter               // drains the tap buffer; RMS + fixed-format normalize
├── CalendarNamer                     // EventKit lookup
├── MeetingStore                      // scans folders; CRUD on meeting.json
├── Reconciler                        // periodic + event-driven job runner
│   ├── CompressionJob                // caf → m4a
│   └── TranscriptionJob
│       └── Transcriber               // protocol; GeminiTranscriber first
└── UI                                // MenuBarExtra + main window
```

**Threading — the one rule that protects recording.** The two capture sources have *different* thread constraints, and the plan treats them differently rather than forcing one model on both:

- **The CoreAudio tap IOProc is a hard real-time callback.** It MUST NOT allocate, lock, log, or touch the filesystem. It copies float samples into a pre-allocated lock-free ring (`TPCircularBuffer`) and returns. A serial `DispatchQueue` (`TrackWriter`) drains the ring to `system.caf` via `AVAudioFile.write(from:)`; disk I/O, format normalization, and RMS all happen there — never in the IOProc.
- **The mic via `AVAudioEngine.installTap` is NOT a hard real-time thread** — its callback is delivered on an ordinary internal thread, and Apple's own samples write `AVAudioFile` directly inside it. So `MicCapture` writes `mic.caf` straight from the tap block (no ring buffer, no extra queue). Offload to a serial queue *only* if glitches ever appear. Don't impose the IOProc's constraints on the mic for symmetry's sake.
- **Only one recording exists at a time.** `Recorder` owns a single `RecordingSession`; the trigger can't start a second while one is live (a new meeting signal during recording just extends/keeps the current session per the grace logic). No concurrent-session bookkeeping.
- **Detection, calendar, reconcilers, UI** run on the main actor / their own queues. They never call into the recording path except `start()` / `stop()`.
- The recording session holds no reference to the network, calendar, store-writes-other-than-its-own-folder, or UI. (PROJECT.md "recording is sacred and isolated.")

---

## 3. On-disk contract (the real source of truth)

### 3.1 Folder layout

```
~/Recordings/Meetings/
  2026-06-04 14-30-00 — Weekly Sync/        ← "<startID> — <cosmetic slug>"
    meeting.json
    mic.caf      (during; merged + deleted after compression)
    system.caf   (during; merged + deleted after compression)
    audio.m4a    (after compression: one stereo file — mic left, system right)
    transcript.json
    transcript.md
```

- **Folder identity = `startID`** = recording start timestamp `yyyy-MM-dd HH-mm-ss` (local, colons→dashes). Created once, never renamed. The app parses only this prefix; everything after ` — ` is cosmetic and disposable.
- Root path configurable; default `~/Recordings/Meetings/`. Resolve once at launch; create if missing.

### 3.2 `meeting.json` schema (v1)

```jsonc
{
  "schemaVersion": 1,
  "id": "2026-06-04 14-30-00",          // == folder startID; stable key
  "displayName": "Weekly Sync",          // editable; the ONLY name the app reads
  "startedAt": "2026-06-04T14:30:00Z",   // ISO-8601 UTC, wall clock at capture start
  "endedAt":   "2026-06-04T15:02:11Z",   // null while recording
  "tracks": {                            // .caf vs .m4a is derived by globbing; not stored.
    "mic":    { "startOffsetSeconds": 0.00 },   // first-sample time relative to startedAt;
    "system": { "startOffsetSeconds": 0.12 }    // the delta aligns the two transcripts (§5.4)
  },                                     // rate is the fixed 48 kHz mono constant — not stored
  "calendar": {
    "chosenEventId": "EK-...-id",        // null until matched/confirmed
    "candidates": [                       // a few overlapping events, best-first
      { "eventId": "EK-...", "title": "Weekly Sync", "start": "...", "end": "...",
        "hasVideoLink": true, "accepted": true, "allDay": false }
    ]
  },
  "source": { "micOwnerBundleId": "us.zoom.xos" },   // the process that held the mic
  "audioHealth": { "systemSilent": false, "micSilent": false },  // set by writer's RMS
  "jobs": {
    // Only transcription is tracked. We store status + lastError because the failure
    // *reason* ("rate limited") can't be re-derived from which files exist — unlike
    // compression, whose state IS pure file presence (.caf gone, .m4a present) and is not stored.
    "transcription": { "status": "failed", "lastError": "rate limited (429)" }
  }
}
```

**Status is derived from files, then cached.** The authoritative recording lifecycle state is computed by `MeetingStore` from what exists on disk, and only mirrored into `jobs` for display. So a crash can never leave the status field lying:

| Observed on disk | Derived state |
|---|---|
| `*.caf` present, `endedAt` null | `recording` (or **interrupted** if no live session owns it → finalize) |
| `*.caf` present, no live owner | `interrupted` → finalize to `recorded` |
| `*.m4a` present, no `*.caf` | `recorded` (compression done) |
| `transcript.json` present | `transcribed` |

`jobs.*.status` ∈ `{pending, running, done, failed}` is advisory; the reconciler re-derives "what's missing" from files each pass and retries failures. **No retry counter, no queue persistence** (PROJECT.md decision #2).

### 3.3 `transcript.json` schema (provider-neutral)

```jsonc
{
  "schemaVersion": 1,
  "provider": "gemini",
  "model": "gemini-3-flash-preview",
  "language": "en",
  "text": "Hey, can you hear me?",
  "createdAt": "2026-06-05T17:29:44Z"
}
```

`transcript.md` is rendered from this — never the reverse. **Keep this schema Gemini-agnostic**: the provider returns text, possibly with model-produced speaker labels, and we store that text verbatim. We do not derive speaker turns in app code. Storage must never become Gemini-shaped.

### 3.4 Atomic writes

Single helper `AtomicJSON.write(_:to:)`:
1. encode to `Data`; write to `meeting.json.tmp` in the same dir;
2. `FileHandle.synchronize()` (fsync);
3. `FileManager.replaceItemAt` (atomic rename over the real file).

A crash leaves either the old file or the new — never a half-written one. All `meeting.json` mutations go through this; concurrent writers serialized by `MeetingStore`'s actor.

---

## 4. Core types & protocols (Swift signatures)

```swift
// The single extension point (PROJECT.md decision #5).
protocol Transcriber {
    var id: String { get }                          // "gemini", "openai"
    func transcribe(mic: URL, system: URL,
                    hints: TranscriptionHints) async throws -> Transcript
}

enum TranscriberKind: String { case gemini, openai }   // the "switch"
func makeTranscriber(_ kind: TranscriberKind, config: Config) -> Transcriber

// A reconciler: "find meetings missing output X, produce X." Idempotent, retry-safe.
protocol Reconciler {
    var name: String { get }
    func needsWork(_ m: Meeting) -> Bool             // pure, file-derived
    func perform(_ m: Meeting) async throws          // produces X; updates jobs.*
}

struct Meeting {                                     // value type; mirror of meeting.json
    let id: String
    var displayName: String
    let folder: URL
    /* …decoded fields… */
    func file(_ name: String) -> URL { folder.appendingPathComponent(name) }
}

actor MeetingStore {                                 // owns the folder tree
    func scan() -> [Meeting]                          // list = directory scan
    func load(_ id: String) -> Meeting?
    func mutate(_ id: String, _ body: (inout Meeting) -> Void) throws  // atomic save
    func rename(_ id: String, to: String) throws     // touches one JSON field
    func delete(_ id: String) throws
}
```

`Config` is one plain Codable struct persisted to a single JSON file (`~/Library/Application Support/Meeting2/config.json`); secrets (API keys) go to **Keychain**, never config.

---

## 5. Capture engine — Milestone 1 spike (the crux)

This is the only real technical risk. Build it first, standalone, with a manual Start/Stop button, before any UI/store work.

### 5.1 System audio — Core Audio process tap (Swift recipe)

Translated from anarlog/meetily's `cidre` calls to AudioToolbox. Sequence:

```swift
// 1. Describe a mono, global tap that excludes nothing (capture everything the Mac plays).
let desc = CATapDescription(monoGlobalTapButExcludeProcesses: [])   // [] = exclude none = global mono
desc.isPrivate = true
desc.muteBehavior = .unmuted                                // we listen, don't mute
var tapID = AudioObjectID(kAudioObjectUnknown)
AudioHardwareCreateProcessTap(desc, &tapID)                 // macOS 14.2+

// 2. Read the tap's stream format (sample rate, channels, float32).
//    Property: kAudioTapPropertyFormat → AudioStreamBasicDescription.

// 3. Wrap the tap in a private aggregate device.
let aggUID = UUID().uuidString
let aggDict: [String: Any] = [
  kAudioAggregateDeviceUIDKey as String:          aggUID,
  kAudioAggregateDeviceNameKey as String:         "meetingrec-tap",
  kAudioAggregateDeviceIsPrivateKey as String:    true,
  kAudioAggregateDeviceIsStackedKey as String:    false,
  kAudioAggregateDeviceTapAutoStartKey as String: false,
  kAudioAggregateDeviceTapListKey as String: [
    [ kAudioSubTapUIDKey as String: tapUID ]               // tapUID from kAudioTapPropertyUID
  ],
]
var aggID = AudioObjectID(kAudioObjectUnknown)
AudioHardwareCreateAggregateDevice(aggDict as CFDictionary, &aggID)

// 4. Install an IO block and start.
var procID: AudioDeviceIOProcID?
AudioDeviceCreateIOProcIDWithBlock(&procID, aggID, ioQueue) { _, inData, _, _, _ in
    // REAL-TIME: copy float32 from inData.pointee into systemRing. Nothing else.
}
AudioDeviceStart(aggID, procID)
```

Mapping table (so each reference symbol has a Swift target):

| `cidre` (anarlog/meetily) | Swift / AudioToolbox |
|---|---|
| `TapDesc::with_mono_global_tap_excluding_processes(&[])` | `CATapDescription(monoGlobalTapButExcludeProcesses: [])` (verified to compile on the installed 14.x SDK) |
| `tap.uid()`, `tap.asbd()` | `kAudioTapPropertyUID`, `kAudioTapPropertyFormat` |
| `aggregate_device_keys::{uid,name,is_private,tap_auto_start,tap_list}` | `kAudioAggregateDevice{UID,Name,IsPrivate,TapAutoStart,TapList}Key` |
| `sub_device_keys::uid()` (sub-tap) | `kAudioSubTapUIDKey` |
| `AggregateDevice::with_desc()` | `AudioHardwareCreateAggregateDevice` |
| `device.create_io_proc_id(cb,ctx)` | `AudioDeviceCreateIOProcIDWithBlock` |
| `ca::device_start()` | `AudioDeviceStart` |

Teardown (RAII in Rust; explicit for us, in this order): `AudioDeviceStop` → `AudioDeviceDestroyIOProcID` → `AudioHardwareDestroyAggregateDevice` → `AudioHardwareDestroyProcessTap`. Wrap in a class `deinit` and also call on stop; idempotent guards.

### 5.2 Microphone — AVAudioEngine

```swift
let engine = AVAudioEngine()
let input = engine.inputNode
let srcFmt = input.outputFormat(forBus: 0)         // device-native, float32
let dstFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                           sampleRate: 48000, channels: 1, interleaved: false)!
let conv = AVAudioConverter(from: srcFmt, to: dstFmt)!     // absorbs rate/channel diffs
let micFile = try AVAudioFile(forWriting: micCAF, settings: cafSettings,
                              commonFormat: .pcmFormatFloat32, interleaved: false)
input.installTap(onBus: 0, bufferSize: 4096, format: srcFmt) { buf, when in
    let out = AVAudioPCMBuffer(...)                 // convert srcFmt → dstFmt, then:
    try? micFile.write(from: out)
    // capture `when.hostTime` once for the start offset; update mic RMS
}
try engine.start()
```

The mic tap block is **not** a hard real-time thread, so it writes `mic.caf` straight from the block — **no ring buffer, no extra queue** (§2; only the system tap's IOProc needs the lock-free handoff). It does run one `AVAudioConverter` inline to land samples in the same **fixed 48 kHz mono** format as the system track. "Direct" means *in the block*, not *raw*: both tracks share one output format so alignment math and route-change handling (§5.5) are identical, and there are never per-track rate mismatches. On `.AVAudioEngineConfigurationChange` the converter is rebuilt for the new input format — the file stays open.

### 5.3 Dual-track writer & format

- **Hot path file:** mono **CAF**, float32 PCM, at one **fixed** sample rate (the `cafSettings` used by both tracks):
  ```swift
  let cafSettings: [String: Any] = [
    AVFormatIDKey: kAudioFormatLinearPCM,
    AVSampleRateKey: 48000,                 // fixed; converter normalizes sources to this
    AVNumberOfChannelsKey: 1,
    AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
  ]
  ```
  CAF is chosen for crash tolerance + unlimited size (PROJECT.md decision #4); we never hold a whole meeting in memory.
- **System track:** `TrackWriter`'s serial queue drains the `TPCircularBuffer`, runs samples through its `AVAudioConverter` (source rate/channels → fixed mono 48 kHz; see §5.5), and calls `file.write(from:)`.
- **Mic track:** written directly from the AVAudioEngine tap block (§5.2), through its own converter to the same fixed format.
- **Mono downmix** if a source delivers >1 channel happens in the converter — never on the RT thread.
- **Compression to M4A is a separate reconciler** (§7), not in the hot path.

### 5.4 Clock alignment (for merged transcript)

Stamp each track's first sample with `mach_absolute_time()` (host time) at first write; convert the delta vs. the meeting's `startedAt` to seconds and persist it as `tracks.<t>.startOffsetSeconds` (§3.2). The merged `audio.m4a` lines the two tracks up by that delta — alignment is baked in once, at compression. The initial offset is small (tap spin-up vs. engine start, tens of ms); the real concern over a long meeting is **clock drift** between the two independent capture clocks — they can diverge by a second or more over an hour. For transcript text that is acceptable, so we do **not** add resampler-sync in the hot path; record the offset and accept drift. Revisit only if a real transcript shows quality problems from it.

### 5.5 Route/device changes — **[NEW]**, references don't do this

Both references only *poll* sample rate; neither survives a mid-meeting output-device switch (AirPods connect, monitor unplug). We add real listeners — and we keep the *file* stable across changes rather than rolling segments:

- Register `AudioObjectAddPropertyListenerBlock` for `kAudioHardwarePropertyDefaultOutputDevice` and the aggregate's `kAudioDevicePropertyDeviceIsAlive`.
- **The `TrackWriter` normalizes to one fixed output format** (e.g. 48 kHz mono float32) via a single `AVAudioConverter`, off the RT thread. So when the source rate changes, the converter absorbs it and we **keep writing one continuous `system.caf`** — no `system.2.caf` segments, no concat step, no segment fields in the schema. On a default-output change we stop the IOProc, rebuild tap+aggregate against the new device, and restart feeding the same converter+file. Log a `routeChange` event.
- The mic side: AVAudioEngine posts `.AVAudioEngineConfigurationChange`; on it, reinstall the tap (and re-point its converter if the new input rate differs).

This is the single most important robustness gap vs. the references; treat it as part of the M1 gate.

### 5.6 Silent-recording guard (RMS)

On the writer queue, maintain a rolling RMS per track. If the **system** track is flat-zero for > N seconds while we believe a call is active → set `audioHealth.systemSilent = true`, turn the menu bar icon red, log. After finalize, any track that was silent throughout is flagged in the list. This is "a couple of RMS checks," not a subsystem.

### 5.7 M1 exit criteria (gate #1)

A throwaway harness that:
1. Records `mic.caf` + `system.caf` from a real Zoom + Meet call, both **verifiably non-silent** (RMS > floor).
2. **Survives an output-route change** mid-recording (plug/unplug headphones) without dying or going silent.
3. **Finalizes after a simulated crash** (`kill -9` mid-record): on next launch the interrupted CAF opens and plays to the last written frame.
4. Mic and system line up within ~50 ms on a clap test.

If (2) proves painful, the documented fallback is ScreenCaptureKit audio (needs Screen Recording permission) — but only after genuinely trying the tap.

---

## 6. Detection engine — Milestone 4

**The core signal is "which process holds the mic," not "is output playing."** This is a correction from an earlier draft that required mic-AND-output activity. Output-activity detection turned out to be both *redundant* and *unbuildable as specified*: redundant because per-process mic ownership already separates a call from media playback, and unbuildable because the proposed RMS-of-output fallback needed the tap running — but the tap only exists *after* recording starts, so there's nothing to measure during detection. Dropping it removes a net-new subsystem and a dependency cycle.

### 6.1 Signals (one subsystem, fully cribbable)

- **Mic active** — listen to `kAudioDevicePropertyDeviceIsRunningSomewhere` (scope `kAudioObjectPropertyScopeGlobal`, element main) on the **default input device**; also listen to `kAudioHardwarePropertyDefaultInputDevice` to re-bind on device switch. Property read returns `UInt32 != 0`. (anarlog recipe.)
- **Mic owner** — when the mic goes active, enumerate audio **process objects** (`kAudioHardwarePropertyProcessObjectList`, macOS 14.2+) and find the one whose input is running → resolve to a bundle id via its PID + `NSRunningApplication`. anarlog does exactly this (`processes()` → `is_running_input()`); cribbable.
- **No output-active subsystem in the core trigger.** It stays an *optional later add* (§0) only for the rare listen-only webinar where you never hold the mic.

### 6.2 Trigger logic (eager start, prune later)

```
state: idle → recording → (grace) → idle
- enter recording: mic active AND owner ∉ mic-denylist  → start IMMEDIATELY (no 30s wait)
- stay recording while mic stays active
- mic inactive for graceMinutes (~2)  → stop
- on stop: if duration < 30s OR both tracks silent → prune (move folder to Trash)
```

- **Start eagerly** — do not wait to "be sure" (that loses every meeting's opening, by design). Over-capture, prune junk afterward.
- **Prune = `FileManager.trashItem`, never `removeItem`.** For a "never miss" recorder, automatic *permanent* deletion is exactly the wrong default: a real call that ran short, or a recording mis-flagged as silent, would be unrecoverable. Moving to Trash is one API call, OS-native, and reversible for ~30 days — recoverable without us building a separate "pending review" state (that would be over-engineering; the Trash already *is* that state). User-initiated delete in the UI still hard-removes.
- **No multi-state confidence machine** — eager-start + prune-short/silent reaches the same goal with far less code.
- **Optional short pre-roll** (≤ a few seconds, ring-buffered) — kept short on purpose: continuous capture lights the macOS recording indicator, a real privacy cost. Default off.

### 6.3 The mic-denylist (the real filter) — honest limitation

The trigger fires on *any* mic owner except a small **denylist of non-meeting mic users**:

- **Denylisted owners:** `com.apple.VoiceMemos`, Siri / `com.apple.assistantd`, `dictationd`, and similar. These hold the mic but aren't calls. This is what the old "require output" rule was really trying to exclude — done precisely by *who* holds the mic instead of by a coarse output flag.
- **Meeting owners (no special-casing needed):** Zoom (`us.zoom.xos`), Teams (`com.microsoft.teams2`/`com.microsoft.teams`), Webex (`Cisco-Systems.Spark`), Slack, **and any browser** (Chrome/Safari/Arc/etc.) — because a browser only holds the mic when a tab is in a call. **This is the key win over app-bundle detection:** a YouTube tab and a Google Meet tab share one bundle id and look identical at the device level, but only the Meet tab *grabs the mic* — so mic-ownership distinguishes them where anarlog's bundle-id detector (which doesn't even recognize Meet) cannot.
- Record the owner bundle id into `source.micOwnerBundleId` for naming/debugging.

### 6.4 M4 exit criteria (gate #2)

Run real Zoom + Google Meet sessions; log true/false positives and start/stop latency. Tune `graceMinutes` and the denylist **from this data, not guesses**. Confirm: YouTube-in-browser does **not** trigger (no mic owner); a Meet call **does**; Voice Memos / Siri do **not**.

---

## 7. Reconcilers — Milestones 3 & 7

Generic loop (`Reconcile/Reconciler`): on a timer (e.g. every 30 s) and on events (recording finished, app launch, manual button), for each reconciler, for each meeting where `needsWork` is true, run `perform`. Serialize per-meeting; cap concurrency (e.g. 1–2 transcriptions at once). Each job sets `jobs.<name>.status` and `lastError` via `MeetingStore.mutate`. Failures are just retried next pass.

### 7.1 CompressionJob (M3)

- `needsWork`: a `*.caf` exists and `audio.m4a` is missing.
- `perform`: merge both CAFs → one stereo **`audio.m4a` (AAC)** (`left = mic`, `right = system`), aligned by the per-track offsets so transcription needs none. **No ffmpeg.** ~60 MB/hr (vs ~1.2 GB/hr raw). Metadata is written to point at `audio.m4a` *first*, then the CAFs are deleted — so a crash before cleanup leaves the CAFs and `needsWork` re-triggers. A missing/empty track is tolerated (that channel is left silent). One CAF per track (route changes are absorbed by the writer's converter, §5.5 — no segments to concat).
- Idempotent: re-running with `audio.m4a` already present just re-validates it and clears any leftover CAFs.

### 7.2 TranscriptionJob (M4)

- `needsWork`: finalized `audio.m4a` exists and `transcript.json` is missing. Do not trust stale `jobs.transcription.status == running`; if the process died during upload, file-derived reconciliation must retry it (a launch sweep also heals "transcript exists ⇒ job done").
- `perform`: send `audio.m4a` (already stereo: `left = mic`, `right = system`) to the configured `Transcriber`, render `transcript.md`, then write `transcript.json` atomically. Network failure → `failed` + `lastError`; audio untouched; retried later. A missing API key can't build the transcriber at all — that's a global config problem, so it's surfaced without marking any recording `failed`.

Adding summaries/export later = a new reconciler, never a change to the recorder (PROJECT.md decision #2).

---

## 8. Calendar naming — Milestone 6

Native EventKit (in Swift this is *easier* than anarlog's Rust→ObjC bridge — a point in favor of native):

- Permission: `EKEventStore.requestFullAccessToEvents()` (macOS 14+).
- On a finished recording, query `events(matching:)` for a window around `startedAt` (± a few minutes).
- **Pick the event** whose time window overlaps the start, that has a video link (zoom/meet/teams URL in `notes`/`url`/location), is not all-day, and that the user accepted (`EKParticipant.participantStatus == .accepted`). Store the **chosen** event plus a couple of **candidates** in `meeting.json.calendar` so a wrong guess is corrected by a pick, not a re-lookup.
- Set `displayName` from the chosen event title; fall back to `"Recording <startID>"` if no match. User can always rename (one JSON field).
- Google Calendar is read for free via macOS Calendar.app subscriptions — **no OAuth, no Nango relay** (the path anarlog routes through a hosted relay; we avoid it entirely).

---

## 9. Transcription provider — Milestones 4 and 8

### 9.1 GeminiTranscriber (M4)

Gemini has **no real-time mode**; use file upload + `generateContent`:

1. Upload `audio.m4a` (already stereo: mic → left, system → right) via the **Files API** (`POST /upload/v1beta/files`, resumable) → file URI.
2. `POST /v1beta/models/gemini-3-flash-preview:generateContent` with the uploaded file and the current prompt: "transcribe this dialog ... by speaker". Gemini owns that formatting; the app stores the returned text verbatim and does not parse speaker turns. Note: Google currently documents that audio channels may be combined for audio understanding, so channel identity is context for the model, not an API contract.
3. **Chunking** for long meetings happens *inside* this class if the single-file path hits practical limits — an internal detail that never touches the architecture.
4. Map Gemini's response into the provider-neutral `Transcript`. API key comes from environment/`.env` in the dev build; Keychain/settings replaces that once settings UI exists.

### 9.2 Two-track transcription gate (gate #3) — **proved early, before auto-detect/calendar**

The keystone product assumption — that Gemini can produce useful transcript text from our combined two-track input — has **no precedent in either repo** (anarlog uses pyannote; meetily's diarization is broken). We pulled this forward before auto-detect/calendar, first as a fixture script and then as M4 product plumbing. If real meetings show transcript quality is inadequate, the provider-neutral transcript schema keeps pivot options cheap (a second cloud provider, a different prompt, or a different input shape).


---

## 10. App shell, permissions & signing — Milestone 2.5 (brought forward)

- **MenuBarExtra** app, `LSUIElement`/Accessory activation policy (no Dock icon). First slice: menu-bar label shows recording vs idle, menu has manual Start/Stop, Open Recordings Folder, Recover Interrupted, Quit.
- **Launch at login:** defer until after manual capture works; `SMAppService.mainApp.register()` needs a settings toggle and should not block this manual-control milestone.
- **Permissions / TCC** — request lazily, with rationale UI:
  - Microphone — `NSMicrophoneUsageDescription`.
  - Audio capture (process tap) — triggers the system audio-capture consent on first tap; ensure entitlement/usage string present.
  - Calendar — `NSCalendarsFullAccessUsageDescription`.
  - (Only if SCK fallback is ever used: Screen Recording — avoided by default.)
- **Signing:** Personal Team; hardened runtime as needed for the entitlements. Document that unsigned/ad-hoc rebuilds re-prompt TCC — hence stable signing.
- **M2.5 exit:** app launches to menu bar with no Dock icon, Start/Stop writes store-backed folders, the menu-bar label visibly changes idle ↔ recording, and permissions persist across a rebuild.

---

## 11. Build order & milestones (each independently testable)

| M | Deliverable | Exit criteria / gate |
|---|---|---|
| **0** | Signed dev shell / package plumbing | Stable signed app bundle exists for permissioned local testing |
| **1** | **Capture spike** + dual-track CAF (manual Start/Stop) | **Gate #1** (§5.7): non-silent, route-change-survivable, crash-finalizable, aligned |
| **1.5** | **Gemini transcription/input-shape spike** on M1 output | **Gate #3** (§9.2): transcript quality judged adequate (or pivot decided) |
| **2** | Crash-safe finalize on launch | Interrupted CAF finalized → `recorded`, flows onward |
| **2.5** | Manual menu-bar recorder | No Dock icon; menu-bar status idle/recording; manual Start/Stop produces store-backed recording folders |
| **3** | Compression reconciler (CAF→M4A, no ffmpeg) | m4a ≈ target size; CAF deleted; idempotent |
| **4** | Gemini transcription reconciler + on-demand button | transcript.json/.md produced; retry-safe on forced failure; short smoke fixture transcribes through Gemini |
| **5** | Auto-detect (eager start, grace stop, prune, denylist) | **Gate #2** (§6.4): real Zoom/Meet TP/FP + latency tuned from data; YouTube doesn't trigger |
| **6** | Calendar naming (EventKit) | Correct event chosen on real meetings; candidates stored; manual rename works |
| **7** | Store + UI (list, rename, delete, transcript viewer) | Folder scan = list; rename touches one field; delete removes folder |

Estimate: a few thousand lines of Swift, one process, no backend — lean toward the high end once detection + 2 reconcilers + crash recovery + calendar + UI + 2 transcribers are counted.

---

## 12. Risk register (ranked)

| # | Risk | Why it's real | Mitigation |
|---|---|---|---|
| 1 | Tap reimplementation harder in Swift than the Rust+`cidre` references | No Swift reference; `cidre` hides aggregate-device/IOProc fiddliness | M1 first; recipe in §5.1; SCK documented fallback |
| 2 | Route/device-change mid-meeting kills or silences capture | **Neither reference handles it** (they poll) | §5.5 property listeners; part of gate #1 |
| 3 | Listen-only meeting (you never hold the mic) isn't detected | mic-ownership trigger needs a mic owner | Accepted under over-capture ethos (rare); optional output-active trigger as a later add (§6.1) |
| 4 | Gemini transcription quality not good enough | **No working precedent** for this exact two-track input shape | Keep schema provider-neutral and store model text verbatim; pivot prompt/provider/input shape without changing the recorder |
| 5 | Browser Meet vs. YouTube indistinguishable | Same bundle ID, same device usage | **Resolved** by mic-*ownership* (§6.3): only the call tab grabs the mic |
| 6 | Silent recording looks fine but is empty | dead/zeroed tap, revoked permission | §5.6 RMS guard + red icon + post-hoc flag |
| 7 | Gemini long-audio limits / cost | file size + token limits | in-class chunking (§9.1); retry-safe reconciler |

---

## 13. Testing strategy

- **Unit:** schema round-trips (`meeting.json`, `transcript.json`), status-from-files derivation table, atomic-write crash simulation, calendar-matching heuristic on fixture events, ring-buffer SPSC under load.
- **Capture harness (M1):** scriptable record N seconds → assert RMS floors, route-change injection, `kill -9` + relaunch finalize.
- **Detection log (M4):** structured log of trigger transitions with timestamps; replay against recorded real sessions to tune thresholds.
- **Manual matrix:** {headphones, speakers} × {Zoom, Meet, Teams} × {1:1, group} — record, transcribe, eyeball transcript quality.

---

## 14. Open decisions (resolve as we hit them)

1. ~~`CATapDescription` exact initializer~~ — **resolved:** `CATapDescription(monoGlobalTapButExcludeProcesses: [])` compiles on the installed SDK and is the intended "global mono, exclude none."
2. **Mic-denylist contents** — the exact set of non-meeting mic owners (Voice Memos, Siri, dictation, …); seed from §6.3 and extend from gate #2 data. (Output-active as an optional listen-only trigger is deferred, not in scope for v1.)
3. **Pre-roll** — ship off; revisit only if we observe clipped openings in gate #2.
4. **Gemini model + chunk size** — pick during gate #3 from quality/cost.
5. **Where compression runs** — immediately on stop vs. next reconciler tick (default: reconciler, to keep the stop path trivial).

---

*This plan is implementation-ready for Milestones 0–1. Re-confirm §5.1 against the live 14.2 SDK on first build; everything downstream depends on the capture gate passing.*

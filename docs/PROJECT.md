# Meeting2 — Project Plan

**Date:** 2026-06-04
**Platform:** macOS, Apple Silicon only
**Status:** Architecture settled. One technical spike open — the system-audio capture API (Core Audio process tap vs. ScreenCaptureKit) — to confirm in Milestone 1. Audio format and folder layout decided below.

This document explains what we're building, why, and — importantly — **every place where we deliberately do something different from the two open-source apps we studied** (`anarlog` and `meetily`) and the reason for each choice.

It's written to be readable by someone who isn't deep in the code. If you read only one section, read ["The big idea"](#the-big-idea).

---

## What we're building

A small, reliable macOS app that:

- Starts itself when you log in and lives quietly in the menu bar.
- Notices when you're in a meeting (Zoom, Google Meet, Teams, or any call) and records it automatically — **without joining the call as a bot or participant**. It captures the sound your Mac plays plus your microphone, locally.
- Saves every recording into a tidy, human-readable folder on your disk.
- Names each recording from your calendar (e.g. "Weekly Sync") by reading the macOS Calendar.
- Transcribes recordings after the meeting (and on demand), with speaker labels, using Google Gemini — and is built so other transcription services can be added easily.
- Shows you a list of meetings you can rename, browse, and delete.

It does **not** try to clean up audio, doesn't need a virtual microphone (no BlackHole), doesn't run a separate server, and doesn't need an account or the cloud (except the transcription API you choose).

### What it explicitly does NOT do (on purpose)

- No noise cancellation / audio "enhancement" (you don't care about crisp audio).
- No live, word-by-word transcript during the meeting (we transcribe afterward).
- No Windows or Linux support.
- No plugin system, no accounts, no billing, no cloud sync, no background databases.

Keeping this list short is a feature. Most of the complexity in the apps we studied comes from things on this list.

---

## Why build our own instead of forking?

We seriously evaluated two mature open-source projects (see `ANALYSIS.md` for the full review):

- **anarlog** (formerly "Hyprnote") — a large, powerful, MIT-licensed monorepo. It has the right low-level pieces (native audio capture, calendar, transcription provider plumbing, menu-bar app, autostart) but it's a **200+ module ex-commercial product**. Most of it exists to serve a *business* (accounts, billing, cloud sync, a hosted OAuth relay, plugins), not the *task*. Adapting it means mostly *deleting* things.
- **meetily** — smaller and easier to read, but it's missing almost everything you care about (calendar, auto-detect, cloud/Gemini transcription, working diarization), and "fully working" means juggling a Tauri desktop app **plus** a Python server **plus** a separate Whisper server.

The core realization: **both apps are complicated mainly because they are cross-platform, multi-user products.** Your needs are a small, strict subset that maps almost one-to-one onto macOS's own built-in frameworks. Once you drop "cross-platform" and "commercial," the task is small — a few thousand lines, one process, no backend.

So: we reuse their *ideas and lessons*, but write a focused app.

---

## The big idea

Everything in this project follows from one observation:

> **The app is really two things glued together:**
> 1. **A recorder** that turns "a meeting is happening" into audio files. This part runs in real time and must never fail.
> 2. **A pile of after-the-fact work** on those files — naming, transcribing, browsing. None of this is real-time; all of it can fail and be retried without losing anything.

That split drives every decision. The single most important rule is:

> **Recording is sacred and isolated. Nothing else — not the network, not the calendar, not transcription, not the UI — is allowed to put a recording at risk.**

Your #1 problem with Krisp-style tools is "does it *reliably* record every meeting?" Reliability isn't a feature you bolt on. You get it by making the part that runs during a meeting do **almost nothing**: take audio samples, write them to a file. No mixing, no network calls, no database writes, no fancy processing. If the only thing happening during a meeting is "samples → disk," then **disk failure becomes the *dominant remaining* way to lose a meeting** — but not the only one. The real residual risks are revoked permissions, a silent/zeroed tap, an audio-device route change, system sleep, the process being killed, and no free space. Designing against *those* is what the detection, audio-health, and crash-recovery sections below are for.

---

## The five decisions that remove the complexity

These are the heart of the design. Each one is contrasted with what the two apps do.

### 1. The filesystem is the database

**What we do:** Each meeting is a folder. Inside it, a small `meeting.json` file is the single source of truth (name, times, calendar info, status). The app's "list of meetings" is just the result of scanning a directory. There is no database.

**What the apps do:** anarlog uses TinyBase + SQLite; meetily uses SQLite via a Python backend.

**Why we diverge:** A database is the wrong tool for a few hundred personal recordings. Plain files give us, for free:
- **Crash safety** — the audio is already on disk; there's nothing to "commit."
- **Inspectability** — you can open the folder in Finder and see everything.
- **Sync** — point iCloud / Dropbox / git at the folder and you're done.
- **No migrations, no corruption, no server.**

anarlog half-believes this (it stores notes as Markdown files) but still keeps databases around. We go all the way: files only.

### 2. Everything after recording is a "reconciler"

**What we do:** After a recording exists, all further work is done by simple, repeatable loops of the form *"find meetings that are missing output X, and produce X."* Transcription is the first one: *"audio exists but transcript doesn't → transcribe it."* These loops are safe to re-run anytime; if one fails or the app restarts, it just tries again next time.

**What the apps do:** Both wire features together more tightly, with state spread across UI, backend, and database.

**Why we diverge:** This pattern is what makes the app both **reliable** and **extensible without a plugin framework**. Want summaries later? That's a new reconciler ("transcript exists, summary doesn't → summarize"). Want a different export format? Another reconciler. You add features by adding a small self-contained loop, **never by touching the recorder or the core.** This gives us the "easily extensible" goal without the "plug-everything / dependency-injection" machinery you wanted to avoid.

### 3. Record two separate audio tracks; never mix them in real time

**What we do:** While recording we write the microphone and the system output as **two separate files** (`mic.caf` / `system.caf`). After the meeting we merge them into one stereo `audio.m4a` — **you on the left channel, everyone else on the right** — and delete the raw CAFs. The channels stay separate (no summing, no real-time mixing); we just collapse the two files into one easy-to-play artifact that doubles as the transcriber's input.

**What the apps do:** Both spend large amounts of code on real-time mixing — balancing levels, "ducking" (lowering system audio when you speak), echo cancellation, and voice-activity detection. anarlog and meetily each have hundreds of lines just for this.

**Why we diverge — this is the highest-value simplification in the whole project:**
- The recording path becomes trivially simple and therefore robust. (Remember: simple hot path = reliability.)
- The transcript path can stay simple too: we give the model the audio context and store its response text directly. We do **not** derive speaker turns in app code.

**The important caveat (this is exactly why both apps carry echo cancellation):** the mic track is only *clean* if you wear **headphones**. On **speakers**, your microphone physically picks up the remote audio coming out of them (acoustic echo), so `mic` ends up containing your voice *plus* a bleed-through copy of everyone else. We deliberately do **not** build real-time echo cancellation — it's the most complex subsystem both apps have, and you don't care about audio quality. Instead we accept an explicit trade-off:
- **Headphones → cleaner source tracks**, which helps the model hear local and remote speech.
- **Speakers → the mic track may include bleed-through**, but the system track still carries the remote speech. We accept that without adding echo cancellation or code-side speaker attribution.

So the honest framing is: separate tracks are for reliable capture and better model input, not a promise that the app will perform diarization. Skipping real-time DSP is still the right call — it removes the single most complex subsystem both apps have, in exchange for a "wear headphones for best results" recommendation.

### 4. macOS-only means no "abstraction tax"

**What we do:** Use Apple's own frameworks directly, in one language (Swift), in one process.

**What the apps do:** Both use **Tauri** — a framework for building cross-platform desktop apps with a Rust backend and a web (JavaScript/HTML) front end, bridged together. meetily adds a Python backend on top. That's 2–3 languages and a bridge between them.

**Why we diverge:** Cross-platform frameworks exist to paper over the differences between macOS, Windows, and Linux. You only have macOS. So that entire layer is pure overhead for us. Apple already ships native, well-documented tools for every hard thing we need:

| What we need | Apple framework we'll use |
|---|---|
| Capture system audio | Core Audio process tap (primary) — ScreenCaptureKit as fallback; see the spike below |
| Capture microphone | AVAudioEngine |
| Detect a meeting (mic in use) | Core Audio (device-in-use listener) |
| Know which app is running | NSWorkspace |
| Read your calendar | EventKit (local, no login) |
| Launch at login | ServiceManagement (SMAppService) |
| Menu-bar app with no dock icon | SwiftUI MenuBarExtra |
| Call Gemini/OpenAI | URLSession (plain HTTPS) |
| Store API keys safely | Keychain |

One language (Swift), one app, no web bridge, no Python, no network ports between parts.

### 5. Extensibility via tiny "protocols" + a switch — not dependency injection

**What we do:** The only thing that genuinely needs to vary is *which transcription service we use*. So there's exactly **one** extension point: a one-method `Transcriber` interface. Adding Gemini, OpenAI, or a local model is "write a small new type and add one line to a switch." Settings live in one plain config file; secrets live in the Keychain.

**What the apps do:** anarlog has a large plugin system and many layers of indirection (it needs them — it's a platform). meetily spreads provider logic across frontend, backend, and database.

**Why we diverge:** You asked specifically for "easily extensible, but **without** plug-everywhere / dependency-injection / over-engineering." A single small interface plus a switch statement is the simplest thing that is still genuinely extensible. If you can read the whole list of "how parts connect" on one screen, it isn't over-engineered. We hold to that.

---

## How the app is structured

Six concrete pieces. They're connected by plain, ordinary code — one top-level object creates them and hooks them together. There is no framework doing magic behind the scenes.

```
AppController            ← the root; creates the others and wires them together
├── MeetingDetector      watches the mic; says "a meeting started / ended"
├── Recorder             on start: writes mic.caf + system.caf into a new folder
├── CalendarNamer        looks up the calendar event happening now → a name
├── MeetingStore         owns the folders; scan / save / rename / delete; feeds the UI
├── Reconciler           a queue: any meeting missing a transcript gets transcribed
│   └── Transcriber      the one interface: audio in → transcript text out
│       └── GeminiTranscriber   (first implementation)
└── UI                   menu-bar controls + a window (list, rename, transcript, settings)
```

"Wiring them together" literally means a few lines like *"when the detector says a meeting started, tell the recorder to start."* That's the entire dependency graph — written out plainly, not hidden inside a framework.

### Folder layout on disk (the real contract)

```
~/Recordings/Meetings/
  2026-06-04 14-30-00 — Weekly Sync/
    meeting.json      ← THE source of truth: display name, start, end, calendar event id, attendees, source app, status
    audio.m4a         ← the whole meeting in one stereo file: mic on the left, system on the right (built after the meeting; see format note)
    transcript.json   ← list of { start, end, speaker, text }
    transcript.md     ← the same transcript, human-readable
```

**Folder identity vs. display name — a decision we revised.** An earlier draft said "the folder name *is* the meeting name" (copying meetily). On a cold re-read that's a bug waiting to happen: it contradicts "meeting.json is the source of truth," and it means renaming a meeting must rename a folder that may have open file handles during recording — plus calendar titles contain `/`, `:`, emoji, and 200-character strings that are painful as filenames. So:

- **The folder name starts with a stable, sortable ID** — the recording's start timestamp (e.g. `2026-06-04 14-30-00`). It never changes once created, so renaming a meeting is always safe, even mid-recording.
- **The display name lives only in `meeting.json`.** Renaming touches one JSON field; the folder is untouched. One source of truth, no drift.
- For Finder-friendliness we append a **cosmetic** sanitized slug after the ID (`… — Weekly Sync`). It's purely decorative and disposable — the app never reads it, so if it's stale or stripped, nothing breaks.
- **`meeting.json` is authoritative for what the files can't tell us** (name, calendar link, attendees). **Status is derived from which files exist** and only cached in JSON — so a crash can never leave the status field lying.
- **Writes are atomic:** write `meeting.json.tmp`, flush, then rename over the real file — a crash never leaves a half-written JSON.
- **`meeting.json` carries a `schemaVersion`** from day one (cheap insurance for future format changes), plus a per-job status and last-error string (e.g. `transcription: failed — "rate limited"`). We keep it to *status + error*, **not** a retry-counter job-queue; the reconciler simply retries failed jobs on its next pass.
- **Calendar match stores a couple of candidate events**, not just the one chosen title — so if the guess is wrong, correcting it is a pick, not a re-lookup.

---

## Reliability: how we make sure meetings are never lost

This is the whole point of the app, so it gets its own section.

1. **The recording path does almost nothing** — just samples → file (see decision #3). Less code running during a meeting = fewer ways to fail.
2. **Audio is written continuously to disk** as the meeting happens, to a **CAF** file (Apple's Core Audio Format), uncompressed. We never hold a whole meeting in memory. CAF is chosen over WAV on purpose: WAV has a ~4 GB size limit and stores its length in the header (a crash mid-write leaves a broken file), whereas CAF has no practical size limit and tolerates an abrupt cut-off — exactly what an always-on, long-meeting recorder needs.
3. **`meeting.json` is marked `recording` at the start.** If the app crashes mid-meeting, then on next launch the app scans the folders, finds anything still marked `recording`, finalizes the CAF, and marks it `recorded`. It then automatically flows into compression and transcription. **A crash costs you, at most, the last few seconds of audio.**
4. **All after-the-fact work is retry-safe.** A failed transcription never harms the audio; it just gets retried.
5. **It auto-starts at login and re-arms after every meeting**, so it's always watching.
6. **It's visibly trustworthy.** The menu bar clearly shows "● Recording" vs idle, and the meeting list fills up as you go — so you can *trust* it and forget about it, which is the entire value of a tool like this.
7. **It over-captures by default** (records whenever the mic becomes active), with an easy denylist and one-click delete. For the goal "never miss a meeting," it's far safer to record a few things you didn't need and delete them than to be clever and miss a real meeting.
8. **It guards against *silent* recordings** — the nastiest failure, because the file looks fine but contains nothing (a dead/zeroed tap, an audio-route change, or a revoked permission). A lightweight check watches incoming audio levels while recording; if the system track is flat-zero for too long, the menu bar turns red and it's logged, and any finished recording that's silent is flagged in the list. This is a couple of RMS checks, **not** a separate monitoring subsystem.

---

## The decisions you locked in

We discussed three product forks and chose:

1. **Stack: native Swift + SwiftUI.** One language, one process, Apple frameworks do the hard parts. (Rejected: Rust+native-shim and Tauri — both reintroduce cross-platform overhead we don't need.)
2. **Transcription timing: after the meeting, automatically, plus an on-demand button.** (Rejected: live word-by-word transcription — it complicates the reliable recording path, needs a streaming-capable service, and Gemini has no real-time transcription mode anyway.)
3. **Detection: over-capture, prune later** — refined to "record when mic-input **and** system-output are both active for at least ~30 s," with a denylist and easy deletion. (Rejected: conservative calendar/allowlist-only — risks missing ad-hoc calls. Rejected: naive mic-only — too many false positives from Siri / dictation / voice memos.)

Then, after a cold-eyed re-read of an earlier draft, we revised four **technical** decisions (full rationale in the sections above):

4. **Audio format: record two mono CAFs, store one stereo M4A (AAC).** *Why:* CAF survives crashes and has no size limit during capture; after the meeting the two tracks are merged into a single stereo `audio.m4a` (mic left, system right) at ~60 MB/hour instead of ~1.2 GB/hour raw, so an always-on recorder won't eat ~100 GB/month. (Rejected: WAV — 4 GB limit and a fragile header on crash; raw/uncompressed storage — far too large to keep.)
5. **Folder identity: stable timestamp-ID folder; display name in `meeting.json` only** (cosmetic readable slug appended for Finder). *Why:* one source of truth, no drift, and renames are safe even while a file is open. (Rejected: folder-name-as-the-name — it contradicts the JSON source of truth and forces filename sanitization of calendar titles.)
6. **System-audio capture: default to the Core Audio process tap**, with ScreenCaptureKit as fallback — confirmed by a Milestone 1 spike. *Why:* the tap is a purpose-built audio API; SCK is a screen-capture API doing an audio job. Both references back this: anarlog uses the tap, and **meetily implements *both* backends and defaults to Core Audio on macOS** — i.e. meetily already ships exactly "tap primary, SCK fallback." (Rejected: the earlier "ScreenCaptureKit because it's newer" — it needs the more invasive Screen Recording permission and has no audio-only mode.)

---

## Key technical decisions & hard parts (so we go in with eyes open)

### System-audio capture — an open spike, leaning toward the Core Audio tap
This is the one genuinely tricky piece, and it's **not fully settled**. There are two ways to capture what the Mac is playing:

- **Core Audio process tap** (`CATapDescription`, macOS 14.2+) — a purpose-built *audio* API. anarlog uses it; **meetily implements both backends and defaults to this one on macOS** (its code has an explicit `CoreAudio` vs `ScreenCaptureKit` switch, with `default()` returning `CoreAudio`). Two reference codebases landing on the tap for audio-only capture is strong evidence it's the right default.
- **ScreenCaptureKit** (macOS 13+) — newer and higher-level, but it's a *screen-capture* API: there's no audio-only mode (you build a content filter around a display), and it requires the more invasive **Screen Recording** permission.

An earlier draft recommended ScreenCaptureKit as "simpler"; on review that's doubtful — the references point at the tap (meetily keeps SCK around only as the alternate backend). **Decision: default to the Core Audio process tap and prototype it first, in Milestone 1.** If the tap proves painful, ScreenCaptureKit is the documented fallback. (Trade-off: the tap needs macOS 14.2+ rather than 13+ — fine for a personal tool on a current Mac.) Both projects' tap implementations are the thing to *study* here — crib the aggregate-device + tap-description setup, don't copy wholesale.

### Audio format — record two mono CAFs, store one stereo M4A
- **During the meeting:** write **two mono CAFs** (uncompressed), one per source. Mono because speech doesn't need stereo; CAF because it's crash-tolerant and unlimited in size (see Reliability). Uncompressed keeps the hot path dead simple and maximally recoverable.
- **After the meeting:** a reconciler merges both tracks into a single **stereo `audio.m4a` (AAC)** — mic on the left channel, system on the right, time-aligned — then deletes the CAFs. One file is easier to play back and is exactly the input the transcriber wants; the left/right split preserves you-vs-them separation without any real-time mixing.
- **Why it matters:** raw 48 kHz audio is ~1.2 GB/hour across two tracks → ~100 GB/month for an always-on recorder. Stereo AAC lands around **~60 MB/hour** — a ~20× reduction. The CAF→M4A split gives crash-safety *and* small files instead of trading one for the other.

### Detection — both signals, and start eagerly (don't gate the start)
Recording on "the mic is active" alone fires on Siri, dictation, and voice memos. The fix is a better *signal*, not a slow confidence machine:
- **Trigger on mic-input AND system-output active at the same time.** A real call has both (the other side is talking); a voice memo only has input. A denylist (YouTube, music, games, media players) handles the obvious non-meetings.
- **Start recording the instant the trigger fires — do NOT wait ~30 s "to be sure."** Waiting would lose the opening of every meeting *by design*. Instead record eagerly and **prune afterward:** delete recordings shorter than ~30 s or that turn out silent. This is just "over-capture, prune later" applied to the *start* of the recording.
- **Optional short pre-roll** (a few seconds, ring-buffered) to catch the instant just before the trigger latches. Caveat the reviewer didn't flag: a pre-roll means capturing audio *continuously*, which keeps macOS's recording indicator lit the whole time — a real privacy/UX cost. So pre-roll stays *short* or off; it is **not** a 30–60 s always-on buffer.
- **Stop after an inactivity grace** (~2 min of no call audio) so a quiet stretch mid-meeting doesn't chop one meeting into several files.
- We **over-capture by default** and make deletion one click — stated honestly: the app *will* sometimes record private/personal audio, and recording calls carries consent rules in some places. An accepted, user-controlled trade-off for "never miss a meeting," with the denylist as the escape valve.

We deliberately **do not** build a multi-state "candidate → confidence-threshold → recording" machine. Eager-start + prune-short/silent reaches the same goal (never miss the start, don't keep junk) with far less code — and less code in the detect/record path is the whole point.

### Smaller hard parts
- **Permissions stick to the app's code signature.** Unsigned builds get re-prompted every rebuild. Fix: sign with a **free** Apple ID "Personal Team" (no paid membership). See below.
- **Aligning the two tracks** for a merged transcript: stamp each file with its wall-clock start time and line them up by time. Sample-perfect sync isn't needed for text.
- **Picking the right calendar event** to name a recording: choose the event whose time window overlaps the recording start, has a video link, isn't all-day, and that you've accepted — then let the user rename if it guesses wrong.
- **Long meetings + Gemini:** Gemini transcribes via its file-upload + `generateContent` API; it has **no real-time transcription mode** (its Live API exists but isn't built for passively transcribing a call). For long recordings we chunk the audio inside the Gemini code — an internal detail that doesn't touch the architecture.

### Do I need a paid Apple license?

No. Building and running this on your own Mac is free. You need: an Apple Silicon Mac on macOS 13+ (14.2+ recommended), free Xcode, and a free Apple ID for stable signing so permissions persist. The paid $99/year Apple Developer Program is only needed to *distribute a signed app to other people* — not for personal use. Transcription API keys (Gemini/OpenAI) are the only paid thing, and even those are optional if you later add a local model.

---

## Build order (each step is testable on its own)

0. **Signed dev shell** — a menu-bar app with no dock icon and stable signing so permissions stick.
1. **Capture spike + dual-track capture** — prove the **Core Audio process tap** for system audio (fall back to ScreenCaptureKit only if needed), plus mic via AVAudioEngine; manual Start/Stop writes `mic.caf` + `system.caf`. *(Build this first — it's the only real risk and it settles the one open decision.)*
1.5. **Gemini transcription/input-shape spike** — feed a real captured stereo fixture to Gemini and judge the input shape before building provider plumbing.
2. **Crash-safe finalize** — on launch, finalize any interrupted CAF and mark it recorded.
2.5. **Manual menu-bar recorder** — run in the menu bar, show idle/recording status in the menu-bar label, and manually Start/Stop into the same store-backed recording folders. This comes before auto-detect because we need a trustworthy manual control surface anyway.
3. **Compression reconciler** — after a meeting, compress CAF → mono `.m4a` and delete the CAF.
4. **Gemini transcription** — the reconciler runs it automatically after compression, plus an on-demand "Transcribe" button.
5. **Auto-detect** — start *eagerly* on simultaneous mic-input + system-output; stop after an inactivity grace; prune recordings under ~30 s or silent; add a denylist.
6. **Calendar naming** — fill in the meeting name from EventKit when a recording finishes.
7. **Store + UI** — the meeting list, rename, delete, and a transcript viewer.
8. **A second provider (e.g. OpenAI)** — added purely to prove the one extension point stays clean.

Roughly a few thousand lines of Swift, one process, no backend.

### Three gates before serious UI/transcription work

Three things are *gates*, not givens — prove each with a throwaway spike before building on it:

1. **Capture (Milestone 1).** Dual-track CAF that is verifiably non-silent, survives a device/route change, and finalizes after a crash.
2. **Detection.** Run real Zoom + Google Meet sessions; log true/false positives and start/stop timing. Tune the trigger and grace from real data, not guesses.
3. **Gemini transcription.** Feed real mic/system tracks to Gemini and judge whether the single-audio-file input shape produces useful text. Keep the transcript schema **provider-neutral** so storage never becomes Gemini-shaped — Gemini is one `Transcriber`, not the architecture.

If the capture gate is shaky, don't build the whole app around it yet — try the ScreenCaptureKit fallback or a tiny capture helper (cribbed from the reference projects' tap code) first.

---

## Quick summary: what we kept, changed, and dropped vs. the two apps

| Topic | anarlog | meetily | **Our app** | Why |
|---|---|---|---|---|
| Platform scope | Cross-platform | Cross-platform | **macOS only** | Removes the abstraction layer entirely |
| Stack | Tauri (Rust+web) | Tauri + Python + Whisper server | **Native Swift, one process** | Apple frameworks do the hard parts; no bridges/servers |
| Storage | TinyBase + SQLite | SQLite via backend | **Plain files (folder per meeting)** | Crash-safe, inspectable, syncable, no DB |
| Audio | Real-time mix + ducking + AEC + VAD | Same | **Two separate tracks (mic + system), no mixing, no AEC** | Simpler + reliable; better model input without app-side diarization |
| Audio format | WAV/MP3/OGG | MP4/AAC | **Record two mono CAFs → store one stereo M4A (AAC)** | Crash-safe capture + small files (~60 MB/hr vs ~1.2 GB/hr) |
| System-audio API | Core Audio tap | Core Audio tap (default) + SCK backend | **Core Audio tap (primary), SCK fallback** | Purpose-built audio API; anarlog uses it, meetily defaults to it |
| Recording folders | Random-ID folders | Human-readable folders | **Timestamp-ID folder + name in `meeting.json`** (cosmetic readable slug appended) | Safe rename, single source of truth, no filename-sanitization pain |
| Auto-record | Calendar countdown / notifications (needs a session open or a click) | None (manual; auto-detect is paid) | **Auto-record on mic activity (over-capture)** | "Never miss a meeting" |
| Calendar | EventKit (local) + Google via hosted relay | None (paid) | **EventKit only (local)** | No OAuth, no servers; reads your Google cal via macOS Calendar |
| Transcription | ~10 cloud providers, pluggable; Gemini absent | Local Whisper only | **Gemini first, simple provider interface** | Matches your preference; easy to extend |
| Diarization | Cloud works; local is low-level plumbing | Not working | **Free 2-way from separate tracks; finer split via Gemini** | Sidesteps the hardest ML part for the common case |
| Extensibility | Plugin platform (heavy) | Spread across layers | **One interface + a switch** | Extensible without DI/over-engineering |
| Live transcript | Yes | Yes | **No (post-meeting + on-demand)** | Keeps the recording path simple and reliable |
| Accounts/cloud/billing | Present (commercial) | Backend + PRO tier | **None** | Personal, local tool |

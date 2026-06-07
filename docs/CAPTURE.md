# Capture subsystem — how it works and why

Read this before changing anything in `Capture/`. It explains **what** this code
does, the macOS concepts it rests on, and **why each decision was made**. Every "why"
here is about *this app's goal*, not about how anyone else built theirs.

---

## The one job, and the one rule

The job: while a meeting is happening, save what you say (the microphone) and what the
other people say (the sound your Mac plays) to files on disk.

The rule everything else bends to:

> **A meeting must never be lost.** The code that runs *during* a meeting is allowed to
> do almost nothing — just take audio samples and write them to a file. No network, no
> compression, no clever processing. The less that happens while recording, the fewer
> ways there are to fail.

If you remember only one thing: **the recording path is sacred. Keep it boring.**

---

## Background: the two sound sources on a Mac

A meeting has two audio sources, and macOS gives them to you in two very different ways.

1. **The microphone** — your voice. This is easy. `AVAudioEngine` (Apple's standard
   audio framework) hands you microphone samples in a callback. See `MicCapture.swift`.

2. **System audio** — the sound the Mac is *playing*, i.e. everyone else on the call.
   This is the hard part. macOS has no simple "give me what the speakers are playing"
   call, because that would be a privacy risk. Historically people installed a fake
   audio device (like BlackHole) to capture it. We don't want that. Instead we use a
   feature added in macOS 14.2 called a **process tap**.

### What a "process tap" is (and the aggregate device it needs)

- A **process tap** is an OS object that says "let me listen to the audio output of
  these processes." We create a *global* tap (all processes), in mono. The API call is
  `AudioHardwareCreateProcessTap`.
- A tap by itself produces nothing. To get a stream of samples, the tap has to be
  wrapped in an **aggregate device** — a virtual audio device that exists only in our
  process (`isPrivate = true`). Think of it as a fake input device whose "microphone"
  is actually the system's output. We create it with `AudioHardwareCreateAggregateDevice`
  and attach the tap to it.
- Once the aggregate device exists, we install an **IOProc** on it and start it. See
  the next section — the IOProc is the single most delicate piece of the whole app.

All of this lives in `SystemTapCapture.swift`. It is the fragile part, so it is kept in
one type and nothing else is allowed to depend on its internals.

---

## The IOProc: why it can do *almost nothing*

An **IOProc** is the callback Core Audio calls to hand you a buffer of audio. It runs on
a **real-time thread**: the audio system promises to call it on a strict schedule (every
few milliseconds) and expects it to return *immediately*. If the IOProc is slow — if it
allocates memory, takes a lock, logs, or touches the disk — the audio system misses its
deadline and **drops audio**. Dropped audio is lost meeting. So:

> The IOProc is allowed to do three things and nothing else: read a pointer, `memcpy`
> the samples into a queue, and bump a couple of plain counters.

Two consequences you'll see in the code:

- **The IOProc is a plain C function pointer, not a Swift closure.** A Swift closure that
  captures `self` would do reference-counting work (ARC) every time it runs — atomic
  operations and occasionally a lock, on the real-time thread. That's exactly the kind of
  "small" thing that drops audio. So we hand Core Audio a raw C function
  (`systemTapIOProc`) and a raw pointer to a plain struct (`SystemTapIOProcContext`) that
  holds only what the callback needs. No Swift objects are touched on the audio thread.

- **The counters are C atomics, not Swift properties** (`MeetingAtomic.*`). Swift has no
  built-in atomic integer, and we must not lock on the audio thread, so two small C
  helpers (`__atomic_*`, relaxed ordering) let the callback record "first sample time"
  and "bytes dropped" safely. Relaxed ordering is fine because these are diagnostics, not
  synchronization.

### The hand-off: a lock-free ring buffer

Since the IOProc can't write to disk, it copies samples into a **ring buffer** — a
fixed-size queue shared between two threads. One thread writes (the IOProc), one thread
reads (the writer, below). We use `TPCircularBuffer`, a well-known, audited, public-domain
ring buffer, rather than writing our own: getting lock-free memory ordering wrong is a
classic source of rare, impossible-to-reproduce audio glitches, and "rare bug that loses
meetings" is the worst outcome for this app. `CircularAudioBuffer.swift` is a thin Swift
wrapper that owns it.

### The writer: where the slow work is allowed to happen

`TrackWriter.swift` runs on an ordinary background queue (a 20 ms timer). It drains the
ring buffer and does everything the IOProc couldn't: format conversion, measuring the
audio level, and writing to the file. This split — *cheap copy on the audio thread, slow
work on a normal thread* — is the main reliability boundary of the whole subsystem.

(The microphone is simpler. `AVAudioEngine`'s tap callback is **not** a hard real-time
thread, so `MicCapture` is allowed to convert and write to the file directly inside it.
We deliberately do not force the system path's machinery onto the mic.)

---

## The file decisions

### Two separate files, never mixed: `mic.caf` and `system.caf`

We record your microphone and the system audio into **two separate files** and never
combine them while recording. Why:

- **It makes recording trivial, therefore reliable.** Combining two live audio streams
  ("mixing") — balancing their volumes, cancelling echo, etc. — is a large amount of code
  running on the recording path. We don't do any of it. Two streams, two files.
- **It gives speaker separation almost for free.** The mic file is *you*; the system file
  is *everyone else*. For a one-on-one call that's already a clean two-speaker split with
  no machine learning. (The known trade-off: if you use speakers instead of headphones,
  the mic also picks up the other people coming out of the speakers. We accept that — the
  system file still has the clean copy of their audio.)

### Record uncompressed CAF now, compress to a small file later

During the meeting we write **CAF** files — uncompressed audio in Apple's Core Audio
Format. We do *not* compress while recording. Why:

- **Compressing is work on the sacred path.** An encoder running during the meeting is
  more code that can fail or fall behind. Writing raw samples is the simplest possible
  thing.
- **CAF survives a crash.** If the app is killed mid-recording, an uncompressed CAF is
  still readable up to the last samples written — you lose a few seconds, not the file.
  (Compressed formats often need a "footer" written at the end to be readable at all; a
  crash there can lose the whole recording.) CAF also has no practical size limit.

The downside — CAF files are large — is temporary. A later step (not part of this
subsystem) compresses each finished CAF into a small `.m4a` and deletes the CAF. The
recording path never pays for that.

### One fixed format: mono, 48 kHz, 32-bit float

Both files are always written in the same format, defined once in `AudioFormat.swift`.
Why pin it instead of using whatever the hardware gives us:

- **The hardware's native format can change mid-recording.** Plug in headphones or a USB
  interface and the sample rate can switch (e.g. 44.1 kHz → 48 kHz). A file's format is
  fixed when you open it, so a mid-stream change would corrupt it.
- We solve this by converting every incoming buffer to one fixed format
  (`AVAudioConverter`) before writing. The file stays consistent no matter what the
  hardware does, and the two files always share a format, which keeps them easy to line
  up later. Mono because speech doesn't need stereo; 48 kHz/float because that's the
  tap's natural format and avoids needless resampling.

---

## Surviving the real world

### Route changes (plugging in headphones mid-meeting)

A **route change** is when the system's default output device changes — you connect
AirPods, unplug a monitor, switch outputs in Control Center. This can invalidate the
aggregate device our tap is riding on and silently kill system-audio capture. Both the
output-device-changed and the "aggregate device is no longer alive" events are things we
must react to.

So `SystemTapCapture` registers **property listeners** for those events and, when one
fires, **rebuilds the whole tap graph** (new tap, new aggregate device, new IOProc) while
keeping the same output file. A short debounce (500 ms) coalesces bursts of events. We
preserve the original "first sample" timestamp across the rebuild so the two files still
line up. The cost is a fraction of a second of system audio missed during the switch,
which is an acceptable price for not going silent for the rest of the meeting.

> Open question the spike is meant to answer: a *global* tap might keep working across an
> output change without a rebuild. If hardware testing shows the rebuild is unnecessary,
> it can be limited to the "aggregate died" case to avoid the small audio gap. Until we
> know, rebuilding is the safe default.

### Silent recordings (the file looks fine but contains nothing)

The nastiest failure is a recording that *looks* complete but is silent — a dead tap, a
revoked permission, a wrong route. A file with the right size and duration but no sound is
worse than an obvious error, because you only discover it when you go looking for the
meeting. To catch it, the writer keeps a running **RMS** (loudness) measurement per track
(`RMSMeter.swift`). If a track is flat-zero, it can be flagged. This is two cheap
arithmetic checks, deliberately *not* a signal-processing subsystem.

### Core Audio calls that hang

Some Core Audio calls (`AudioDeviceStart`, creating the IOProc) have been observed to
**block forever** instead of returning an error when system-audio permission hasn't been
granted. So those calls are wrapped with a timeout: if they don't return quickly we fail
with a clear message ("permission probably not granted") instead of hanging the app.

### Permissions, in the right order

`MicCapture` asks for microphone permission *before* it installs anything. That way, if
permission is denied, we fail cleanly with no half-opened files to unwind. System-audio
capture is permissioned at the *app* level, not the binary level — see the packaging
note below.

---

## Map of the files

| File | Responsibility |
|---|---|
| `SystemTapCapture.swift` | The hard part: create the process tap + private aggregate device, run the real-time IOProc, handle route changes. Owns the system-audio lifecycle. |
| `TrackWriter.swift` | Drains the ring buffer on a normal thread; converts format, measures RMS, writes `system.caf`. The reliability boundary. |
| `MicCapture.swift` | Microphone via `AVAudioEngine`; converts and writes `mic.caf` directly (its callback is not real-time). |
| `DualTrackRecorder.swift` | Owns one recording session: starts the system tap first, then the mic; stops them in reverse; returns final stats. Enforces "one recording at a time." |
| `AudioObjectReader.swift` | Small, careful wrappers over Core Audio's property API (easy to misuse, so kept narrow). |
| `../Util/CircularAudioBuffer.swift` | Swift owner of the `TPCircularBuffer` lock-free ring used for the IOProc→writer hand-off. |
| `../Util/AudioFormat.swift` | The one fixed capture format (mono/48 kHz/float) and CAF file settings. |
| `../Util/RMSMeter.swift` | Loudness measurement, to detect silent tracks. |
| `../Util/HostClock.swift` | Converts the audio system's timestamps into milliseconds, for lining up the two files. |
| `../Util/CaptureError.swift` | Plain string errors (no logging framework on the recording path). |
| `../../TPCircularBuffer/` | The vendored public-domain ring buffer + the tiny C atomic counters used by the IOProc. |

### Data flow

```
System audio:  process tap → IOProc (real-time: copy only) → ring buffer
                                                                  ↓
                              TrackWriter (background: convert, RMS) → system.caf

Microphone:    AVAudioEngine tap (background) → convert + RMS → mic.caf
```

---

## Why there are extra command-line tools

`CaptureHarness`, `AudioDeviceTool`, and `AudioAlignmentTool` are **test tools**, not part
of the product. They exist so the riskiest work — capturing real audio, surviving a forced
output-device switch, proving the two files line up — can be exercised from the `Makefile`
before any user-facing app exists. `AudioDeviceTool` switches the default output device on
purpose; keeping it as a *separate* program means the recording code itself never contains
any path that changes the user's audio settings. `make dev-smoke-system`,
`make dev-smoke-route-auto`, and `make dev-smoke-align` run these.

### Why the harness is wrapped in a signed `.app`

macOS grants system-audio recording permission to a *signed application*, not to a bare
command-line binary. So `scripts/package_capture_harness.sh` wraps the harness in the
smallest possible `.app` with the right usage-description strings and signs it. Without
that, the Core Audio tap can hang or fail with no useful error. Permissions stick to the
signature, which is why we sign (ideally with a stable identity) rather than rebuild-and-reprompt.

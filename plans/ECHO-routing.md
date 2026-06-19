# Echo: route-aware track selection

## The problem

A recording made on the **built-in speakers** (no headphones) plays back with an audible
echo on the conversation. The combined `audio.m4a` is mic-L / system-R, and the same words
land on both channels at slightly different times, which is what the ear hears as echo.

## What the measurements actually showed

Analysis of a real 41-minute recording (`2026-06-09 14-10-28`, raw CAFs) found **two**
distinct mechanisms, not the one we assumed:

1. **Far-end round-trip (dominant).** GCC-PHAT finds a razor-sharp, rock-stable coherent
   path at **lag −739 ms** (peak-to-sidelobe ratio ~1000–1600 across the whole call). The
   shared signal appears in the **mic first**, then in the **system track 739 ms later** —
   i.e. the system/call track contains a delayed copy of *your own voice*, echoed back by
   the far end (their AEC failed / they were on speakers). When you talk and the remote is
   silent, the system channel is **up to 94 % your echoed voice**.
2. **Local speaker bleed (weak).** The remote's voice does bleed from the speakers into the
   mic, but only at **~−17 dB** and with **near-zero waveform coherence** (it's reverberant
   room sound, not a clean copy).

Crucially, the mic track itself is **echo-free**: it has your voice (direct) plus the
remote (faint bleed), each once. The duplicate that causes the echo lives entirely in the
**system** track.

Cancellation is a dead end at low effort: the best linear canceller (multi-tap FIR) only
reaches **~3 dB ERLE** (residual ~52 %), and envelope-domain suppression only drops
coherence 0.87 → 0.75 while gutting the remote. Same wall the offline-AEC spike hit.

## The decision variable

Everything hinges on: **can the mic hear the call?**

- **On built-in speakers — yes.** The mic already contains the whole conversation (you +
  remote bleed), and the system track only adds the delayed duplicate. So **drop the system
  track**: build the combined file from the mic alone. This removes *both* echo mechanisms
  at once (the round-trip dies with the system track; there's no second copy of the remote).
- **On headphones / external / Bluetooth / unknown — no.** The mic only has you, so the
  system track is the only source of the remote — **keep both** tracks (the current
  mic-L / system-R behavior). There's no local bleed echo in this case, and the far-end
  round-trip is rare (most far ends have working AEC).

This matches the ear test: mic-only on a speaker recording sounds clean and is enough for
transcription; the remote is intelligible via bleed.

## What we built

1. **Route probe at capture start** (`OutputRoute` / `OutputRouteProbe`). Reads the default
   output device's transport type and data source from Core Audio and classifies
   `isLoudspeaker` — **conservatively**: only the Mac's own built-in speakers count
   (built-in transport, not the headphone jack). The route is stored in `meeting.json`
   (`outputRoute`) before the tap is created, so it survives clean stop and crash recovery.
2. **Route-aware combined audio** (`CombinedAudioBuilder.build(includeSystemTrack:)`,
   `CompressionJob`). `isLoudspeaker == true` ⇒ `audio.m4a` is the **mic on both channels**
   (centered mono, no system, no drift correction). Otherwise unchanged (mic-L / system-R +
   drift + limiter).
3. **Per-track retention (the safety net).** Compression now re-encodes each raw CAF to a
   kept `mic.m4a` / `system.m4a` before deleting the CAFs. So the individual tracks are
   **always recoverable**, which is what makes the aggressive "drop the system track" choice
   safe: a misclassification only degrades the convenience file, never loses audio.

### Why conservative classification is safe

The cost of a wrong **"loudspeaker"** is dropping the system track; the cost of a wrong
**"headphones"** is a harmless leftover echo. So the bias is toward "headphones" (keep
both), and the retained `system.m4a` backstops even a wrong "loudspeaker". Net: the worst
case is a suboptimal `audio.m4a` with both raw tracks still on disk.

## Rejected / deferred

- **Capture-time AEC (VPIO + ScreenCaptureKit).** Abandoned earlier — VPIO takes over the
  shared input device and breaks the meeting app's mic on a live call.
- **Offline AEC / echo cancellation of the system track.** ~3 dB ceiling, residual echo,
  high effort. Not worth it.
- **Acoustic (content-based) speaker/headphone detection.** Local bleed is incoherent
  (~−17 dB, MSC ~0), so "is the remote in the mic?" can't be measured reliably. Route
  detection is the dependable signal.

## Notes

- Only **new** recordings carry `outputRoute`; pre-existing recordings have no stored route
  and re-compress as "keep both" (unknown ⇒ safe). A loudspeaker recording made before this
  change won't auto-convert to mic-only.
- Verify the probe: `make dev-package && make dev-smoke` (while on speakers) writes
  `outputRoute` into the smoke folder's `meeting.json`; `make dev-compress` then produces the
  mic-only `audio.m4a` plus the retained `mic.m4a` / `system.m4a`.

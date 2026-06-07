# Meeting2 — Menu-bar status & menu UX

**Date:** 2026-06-06
**Status:** Design spec for how the app shows state and offers actions. Implementable as a refinement of `RecorderMenuController` (`menuBarSystemImage`, `menuBarTitle`, the menu body) plus a small `attention` model and a global hotkey.
**Audience:** whoever wires the menu-bar UI.

---

## The principle

> **Icon + title = ambient status** — always visible, passive, glanceable, no click.
> **Menu = status (in full) + actions** — shown on click; the detailed status sentence, then the things you can do.

Two rules govern everything below:
1. **The icon title is the *minimal* ambient signal; the menu header is the *full* status.** They're not redundant — the title shows a timer/`⚠`; the menu header is the whole sentence ("Recording · 24:13 · Weekly Sync"). Don't put detail in the title that belongs in the menu, and don't hide status the icon can carry.
2. **The icon shows the single most important thing.** When several are true, a fixed precedence picks the winner (see [Precedence](#precedence)).

---

## The state model (three independent axes)

State is not one enum. Three axes combine:

1. **Capture** — `idle` · `arming` · `recording` · `finalizing`
2. **Live audio health** (only while recording) — both tracks heard · **a track is missing** (mic, system, or both)
3. **Attention** (mostly *after* a recording; outlives capture) — transcription failed · permission missing · (optional) no API key

| Condition | Axis | Urgency | Auto-clears? | Menu action |
|---|---|---|---|---|
| Idle, all good | capture | — | — | — |
| Recording, healthy | capture | low | on stop | — |
| Recording, **a track is missing** | health | **high** — may be capturing junk *now* | **yes** (audio returns) | none — informational |
| Start failed (permission / Krisp contention) | attention | high | retries auto; else manual | "Try Again" / "Open Settings…" |
| Transcription failed | attention | medium (audio is safe) | no | "Retry" + "Dismiss" |
| Track was silent the whole meeting | attention | medium | no | "Dismiss" (info: check mic/output next time) |
| No API key set | attention | low | n/a | "Set up transcription…" (no nag) |
| Interrupted recording recovered | attention | low (good news) | self | none — transient |
| Compressing / transcribing | activity | none | self | none — **menu only**, never the icon |

Two facts that shape the design:
- **A live "missing audio" warning is the highest urgency** — it's happening now and silently — so it can win the icon even over the red recording state.
- **Most problems happen when idle, after the meeting** — so the attention badge must **persist across capture states**, not be tied only to a live recording flag.

---

## Audio health: monitor *both* tracks (not just system)

An earlier draft warned only when the **system** track went silent. That was a mistake — a dead **microphone** loses your whole side of the call, which is just as bad. Both tracks are monitored. They differ only in **threshold and tone**, because their false-positive profiles differ — *not* because the mic matters less:

- **System audio** in a real call is almost always continuously present (someone's talking, hold music, ambient). A few seconds of flat-zero almost certainly means capture broke → **warn quickly** (~6–8 s): *"Can't hear the call."*
- **The microphone legitimately goes silent** for long stretches — you're listening, or muted in the meeting app. A quiet mic usually isn't a fault. So **only warn if the mic has produced no audio for the entire session past a longer window** (~30 s), and **never re-warn once it has had real audio** (later quiet = you're just not talking): *"Not hearing your mic — are you muted?"* (gentle).
- **Both silent at once** is unambiguous — nothing useful is being captured → the **loudest** live warning: *"Not capturing any audio."*

Separately, **at stop**, a track that was silent for essentially the whole meeting becomes a **post-recording attention item** (the schema already carries `audioHealth.micSilent` / `systemSilent`). So a mic that was dead the whole call — and that we were too cautious to nag about live — still surfaces afterward, where the user can check the device/permission. This is the symmetric, honest answer: both tracks are watched live (with different sensitivity) and both are flagged after the fact.

---

## The icon

A single glyph, monochrome by default, color only as an opt-in signal. The through-line is **always a circle**: hollow = idle, filled = active, exclamation-circle = needs you.

**Template, not hardcoded white.** The status image is a *template* — macOS tints it to the menu bar (white on dark, black on light, respects accent / reduce-transparency). "White when ready" = "default template, no color." Red and amber are the only deliberate colors.

| State | SF Symbol | Color |
|---|---|---|
| Idle, ready | `circle` | template (adaptive) |
| Arming / finalizing | `circle.fill` | secondary/grey — "filling up to red"; only if it outlasts the 350 ms busy debounce |
| Recording, healthy | `circle.fill` | **red** |
| Recording, a track is missing | `exclamationmark.circle.fill` | **amber** |
| Idle, unresolved problem | `exclamationmark.circle.fill` | **amber** |

Why this set:
- **It's all circles.** Consistent silhouette, low cognitive load.
- **Shape *and* color both carry meaning**, so it survives colour-blindness and a glance from the periphery: recording (filled dot) vs. problem (`!` mark) differ by shape, not just red vs. amber.
- **Red = recording only. Amber = attention only.** They never fight for the same meaning.
- **No animation / no pulsing.** macOS already shows its own privacy dot when capturing; a *steady* red dot reads as "calmly, reliably recording," which is the whole brand.

### Title text (the minimal ambient signal)
- **Recording:** elapsed timer next to the dot — `●  12:34`. The best trust signal a "never miss a meeting" tool can give. **Monospaced digits** so neighbours don't shift.
- **Recording + warning:** `⚠ 12:34` (amber).
- **Idle (clean or problem):** **no title text.** The icon already says it; the *menu header* carries any detail.

### Precedence
The icon shows the first that matches:
1. Recording **and** a track is missing → amber `exclamationmark.circle.fill`, title `⚠ mm:ss`.
2. Recording, healthy → red `circle.fill`, title `mm:ss`.
3. Idle **and** unresolved problem → amber `exclamationmark.circle.fill`, no title.
4. Arming / finalizing → grey `circle.fill`, no title.
5. Idle, clean → template `circle`, no title.

Background work (compress/transcribe) never changes the icon — it's activity, not status.

---

## The menu (status first, then only the available actions)

Native `.menu` style. **Line 1 is the status** (the full sentence); a divider; then **only the actions that apply right now**. The global hotkey ([below](#global-hotkey)) is the fast path for start/stop, so the menu optimizes for clarity, not for putting the action under the cursor.

**Recording (healthy):**
```
Recording · 24:13 · Weekly Sync             ← status header (dimmed, non-interactive)
───────────
■  Stop Recording                    ⌃⌘R
───────────
Reveal Current Recording
Open Recordings Folder
───────────
Quit Meeting2                        ⌘Q
```

**Recording (a track is missing):**
```
⚠  Can't hear the call · 24:13              ← header carries the specific warning
───────────
■  Stop Recording                    ⌃⌘R
───────────
Reveal Current Recording
Open Recordings Folder
───────────
Quit Meeting2                        ⌘Q
```

**Idle, all good:**
```
Ready                                        ← status header
───────────
●  Start Recording                   ⌃⌘R
───────────
Reveal Last Recording                        ← only if a previous recording exists
Open Recordings Folder
Transcribe Pending (2)                       ← only when there ARE pending; show the count
───────────
Quit Meeting2                        ⌘Q
```

**Idle, with a problem (the "clear the problem" case):**
```
⚠  Transcription failed · Weekly Sync        ← header IS the problem
───────────
●  Start Recording                   ⌃⌘R
───────────
Retry Transcription                          ← the fix, as a first-class action
Dismiss                                      ← clears the badge without fixing
───────────
Reveal Last Recording
Open Recordings Folder
───────────
Quit Meeting2                        ⌘Q
```

Menu principles:
- **Status first.** Line 1 is always the full status sentence (dimmed, non-interactive). It's the one place the detailed state lives.
- **Show only applicable actions.** **Start XOR Stop — never both.** "Reveal," "Transcribe Pending (n)," "Retry / Dismiss" appear only when they apply. A short menu that mirrors the moment beats a long one full of greyed-out rows.
- **A problem promotes its fix.** When there's an attention item, the header states it and `Retry` / `Dismiss` become normal action items right below the primary action.
- **Group with dividers; Quit always last** (`⌘Q`).

### Is rebuilding the menu every time expensive? No.
With SwiftUI `MenuBarExtra`, the menu body is a declarative view that **recomputes automatically** whenever the controller's `@Published` state changes — so `if controller.canStop { Stop } else { Start }` and `if hasPending { Transcribe Pending }` just work, and the menu always reflects the current moment for free. (The AppKit equivalent — rebuild in `menuNeedsUpdate` — is equally cheap.) So contextual, only-available items are the recommended default, not a cost to avoid.

---

## Attention model & clearing the problem

Derive one flag — **`hasUnresolvedAttention`** — and let it drive the amber badge. A problem leaves that state three ways:

1. **Auto-clear (fixed itself):** a live "missing audio" warning clears when audio returns; a missing permission clears when granted (re-check on menu-open and on next start). The live warning is **recording-scoped** and must **not** carry into the idle badge.
2. **Fix (act on it):** "Retry Transcription" success clears it; "Open Settings…" → grant → clears.
3. **Dismiss (acknowledge):** for non-blocking problems (failed transcription/compression, a silent track), **Dismiss** clears the badge *without* fixing — the meeting just stays untranscribed and is still reachable via "Transcribe Pending." This is the explicit "way to clear the problem": the user saw it, chose to defer, and the icon goes calm.

Two restraints:
- **Don't badge routine background work.** Compressing/transcribing is activity, not a problem — surface at most a dimmed menu line.
- **Don't nag about the optional API key.** Missing key = a "Set up transcription…" menu item, never a persistent amber `!`.

---

## Global hotkey

The biggest "less mouse movement" win is starting/stopping **without opening the menu at all** — the title timer confirms it worked. (This is also why the menu can afford to be status-first: the hotkey, not the menu, is the fast action path.)

- **Default:** `⌃⌘R` (Control-Command-R). One key toggles: idle → start, recording → stop.
- **Registration:** use a real system hotkey (`RegisterEventHotKey`, Carbon) rather than an `NSEvent` global monitor — it works system-wide **without requiring Accessibility permission** and without consuming the key from other apps unexpectedly.
- **Make it configurable later** (a Settings field); ship the fixed default first.
- Show the same `⌃⌘R` next to Start/Stop so the menu shortcut and the global one read as one shortcut.

---

## Master mapping (state → icon · title · menu header · first action)

| App state | Icon | Color | Title | Menu header | First action |
|---|---|---|---|---|---|
| Idle, clean | `circle` | template | — | Ready | ● Start Recording |
| Arming | `circle.fill` | grey | — | Starting… | (none yet) |
| Recording, healthy | `circle.fill` | red | `12:34` | Recording · 12:34 · «name» | ■ Stop Recording |
| Recording, can't hear call | `exclamationmark.circle.fill` | amber | `⚠ 12:34` | ⚠ Can't hear the call · 12:34 | ■ Stop Recording |
| Recording, mic silent | `exclamationmark.circle.fill` | amber | `⚠ 12:34` | ⚠ Not hearing your mic · 12:34 | ■ Stop Recording |
| Recording, both silent | `exclamationmark.circle.fill` | amber | `⚠ 12:34` | ⚠ Not capturing any audio · 12:34 | ■ Stop Recording |
| Finalizing | `circle.fill` | grey | — | Stopping… | (none yet) |
| Idle, transcription failed | `exclamationmark.circle.fill` | amber | — | ⚠ Transcription failed · «name» | ● Start Recording (then Retry / Dismiss) |
| Idle, permission missing | `exclamationmark.circle.fill` | amber | — | ⚠ Microphone access needed | Open Settings… |
| Background transcribing | `circle` | template | — | Transcribing «name»… | ● Start Recording |

---

## Guardrails (what not to do)

- No hardcoded white — template adapts.
- No animation / pulsing.
- No status text in the **icon title** when idle (the menu header carries it; the title is for the live timer only).
- No walls of greyed-out always-present items — make items contextual; never show Start and Stop together.
- No icon badge for routine background work.
- No nagging about the optional API key.
- Red = recording only; amber = attention only — never overload one colour with two meanings.

---

## Implementation notes (maps to current code)

- **`menuBarSystemImage` / `menuBarTitle`** (`RecorderMenuController`): compute from the precedence list. Today: `circle` / `record.circle.fill` / `hourglass` / `exclamationmark.triangle.fill`. Change to: `circle` (idle), `circle.fill` (record/arming, tinted red/grey), `exclamationmark.circle.fill` (attention/warning, amber). Drop `hourglass`. Keep the 350 ms busy-presentation debounce so arming/finalizing rarely flash.
- **Menu body**: invert to status-header-first; gate `Start`/`Stop` and the contextual items on `canStart`/`canStop`/`hasPending`/attention — the SwiftUI view recomputes on `@Published` changes, so no manual menu rebuilding.
- **Audio health (both tracks)**: extend the live health check (it already reads `currentStats`) to evaluate **mic and system** with the thresholds above: system short (~6–8 s), mic long + only-if-never-had-audio (~30 s), both-silent loudest. Keep this recording-scoped (`isSystemAudioSilentWarning` → generalize to an enum like `liveAudioWarning: .none/.system/.mic/.both`).
- **Post-recording silence → attention**: at finalize, if a track's `audioHealth.*Silent` is true for the whole meeting, add an attention item.
- **`attention` set**: a small enum for unresolved items (`.transcriptionFailed(folder:)`, `.silentTrack(folder:)`, `.permissionMissing`, `.startFailed`), separate from `RecorderMenuState`. `dismissAttention(_:)` removes one; the icon recomputes. "Retry" calls the existing pipeline and self-clears on success.
- **Wire post-record failures into attention**: today a failed transcription only updates `statusMessage`/`lastError` — route it into the attention set so the icon actually badges it.
- **Global hotkey**: a small `HotKey` wrapper around `RegisterEventHotKey` calling `controller.toggleRecording()`; register at launch, default `⌃⌘R`.
- **Elapsed timer**: already derived from `startedAt`; render with monospaced digits in the title.

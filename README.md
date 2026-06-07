# Meeting2

A quiet macOS menu-bar app that records your meetings **locally** and transcribes them — without joining the call as a bot, without a virtual microphone, without an account, and without sending anything to the cloud unless you choose to turn on transcription.

It captures two things while you're in a call: **your microphone** (you) and **the sound your Mac is playing** (everyone else). Both are saved straight to a folder on your disk that you can open in Finder. After the meeting, it can transcribe the recording with Google Gemini, labelled by speaker.

---

## What it does

- **Lives in the menu bar.** No Dock icon, no window in your way. A small icon shows whether it's recording.
- **Records the whole call locally** — your voice and the other participants — as two separate audio tracks. Nothing is uploaded just to record.
- **Keeps recordings as plain folders** under `~/Recordings/Meetings/`. Open them in Finder, play them in QuickTime, back them up with iCloud/Dropbox — they're just files.
- **Survives the things that lose recordings.** If the app crashes or your Mac sleeps, the audio already on disk is safe; the app finishes the file the next time it launches. If you plug in headphones mid-call, it keeps recording.
- **Transcribes after the meeting** (optional) with Google Gemini, producing a readable `transcript.md` with each side labelled.
- **Tells you the truth about audio.** If it ever can't hear the call, the menu icon turns into a warning instead of silently saving an empty file.

## What it doesn't do (on purpose)

- It does **not** join your meeting as a participant or bot.
- It does **not** install a virtual microphone or speaker.
- It does **not** require an account, a subscription, or a background server.
- It does **not** send your audio anywhere — *unless* you set up transcription, in which case the recording is uploaded to Google only to be transcribed (see [Privacy](#privacy)).

---

## Requirements

- A **Mac with Apple Silicon** (M1 or newer).
- **macOS 14.2 (Sonoma) or later** — system-audio capture uses an API that arrived in 14.2.
- **Xcode 15.4+** (or the Xcode Command Line Tools) to build the app the first time.
- *Optional, for transcription:* a **Google Gemini API key** (free to create — see [Transcription](#turn-on-transcription-optional)).

---

## Get it on your Mac

There's no pre-built download yet — you build it once, then run it like any other app.

1. Open **Terminal** and go to the project folder.
2. Build, sign, and launch it:

   ```sh
   make dev-open-app
   ```

   This produces `Meeting2.app` (under `.build/debug/`) and opens it. A small icon appears in your menu bar — that's the app.

To launch it again later, either run `make dev-open-app` again or double-click `Meeting2.app` in Finder. (Copy it to your `/Applications` folder if you'd like it somewhere permanent.)

> **Tip:** If you have a free Apple Developer account, the app is signed with your "Apple Development" identity automatically, and macOS will remember the permissions you grant. Without one it's signed ad-hoc, which works fine — but macOS may ask for permissions again each time you rebuild.

---

## First run: permissions

The first time you start a recording, macOS will ask for permission to use:

- **the microphone** — to record your side of the call, and
- **system audio recording** — to record the sound the call is playing.

Both are required. If you decline, recording can't work — open **System Settings → Privacy & Security** and enable Meeting2 under **Microphone** and **Screen & System Audio Recording**, then try again.

---

## Recording a meeting

Click the menu-bar icon and choose **Start Recording** when your call begins. The icon turns into a red dot and the menu shows a running timer (e.g. `Recording 02:14`). When the meeting ends, choose **Stop Recording**.

The menu also gives you:

- **Reveal Current Recording** / **Open Recordings Folder** — jump to your files in Finder.
- **Recover Interrupted Recordings** — finish any recording that was cut off by a crash or shutdown (this also runs automatically when the app starts).
- **Transcribe Pending Recordings** — transcribe anything that hasn't been transcribed yet (useful if you set up your API key after recording, or to retry a failed one).
- **Quit** — if a recording is in progress, it stops and saves it first, so quitting never loses a meeting.

If the icon shows a **warning symbol** and the menu says *"system audio silent"* while recording, the app isn't hearing the call — check that the meeting audio is actually playing through your Mac (not, say, a separate headset on a different connection).

---

## Which microphone and speakers does it use?

It records whatever your **Mac** is set to use — **not** whatever Zoom (or Teams, Meet, Slack…) is set to internally:

- **Your voice** comes from your Mac's current **input device** (System Settings → Sound → Input).
- **Everyone else** comes from your Mac's current **output device** — whatever you're listening through. Switch outputs mid-call (e.g. plug in headphones) and it follows along, no interruption.

So you don't need to configure your meeting app specially — just make sure the mic and speakers/headphones **selected on your Mac** are the ones you're actually using. The one thing to avoid is pointing your meeting app at a *different* device than your Mac's: if you send call audio to a headset that isn't your Mac's chosen output, it's no longer part of what your Mac plays, and you'll get the *"system audio silent"* warning.

---

## Where your recordings live

Everything goes into `~/Recordings/Meetings/`, one folder per meeting, named by date and time:

```
~/Recordings/Meetings/
  2026-06-05 14-30-00/
    audio.m4a        ← the whole meeting in one file (you on the left, everyone else on the right)
    transcript.md    ← readable transcript (after transcription)
    transcript.json  ← the same transcript as data
    meeting.json     ← small details file (times, status)
```

You can rename the folder, move it, delete it, or play `audio.m4a` in any audio app. The app never locks your files.

---

## Turn on transcription (optional)

Transcription uses **Google Gemini**. To enable it:

1. Create a free API key at **[Google AI Studio](https://aistudio.google.com/)**.
2. Create a file called `.meeting2.env` in your home folder containing your key:

   ```sh
   echo 'GOOGLE_API_KEY=YOUR_KEY_HERE' > ~/.meeting2.env
   ```

That's it. From now on, **each time you stop a recording it's transcribed automatically** in the background, and a `transcript.md` appears in the meeting's folder. You can also run **Transcribe Pending Recordings** from the menu at any time.

The transcript marks who's speaking (your mic vs. the call), in the language spoken, without timestamps. If you don't set a key, recording and saving still work perfectly — transcription is simply skipped.

*Advanced (optional):* you can override the model or prompt in the same file with `GEMINI_MODEL=...` and `GEMINI_PROMPT=...`.

---

## Privacy

- **Recording and storage are 100% local.** Audio is captured on your Mac and written straight to your disk. Nothing is sent anywhere to record or to save.
- **Transcription is the only thing that uses the internet**, and only if you set up an API key. When it runs, the meeting's audio is uploaded to Google's Gemini service, transcribed, and the uploaded copy is then **deleted from Google**. The transcript is saved back into your local folder.
- **No account, no telemetry, no cloud sync.** If you never set an API key, your audio never leaves your Mac.

A note on consent: this app records both sides of a call. Recording conversations has legal and courtesy implications in some places — make sure the people you're meeting with are okay with being recorded.

---

## Tips for the best results

- **Wear headphones.** With headphones, your microphone records only you and the `system` track records only the others — a clean split that makes "who said what" accurate. On speakers, your mic also picks up the other people coming out of the speakers, which can blur speaker labels (the words are still captured correctly).
- **Make sure the call plays through your Mac.** The app records what your Mac outputs; if call audio is routed to a separate device it can't capture, you'll see the "system audio silent" warning.
- **Let transcription finish in the background.** Long meetings take a little while to upload and transcribe; the menu shows when it's done.

---

## Troubleshooting

- **"Start failed" right after clicking Start, or it hangs for a few seconds.** Usually a permissions issue — grant Microphone and System Audio Recording in System Settings (see [First run](#first-run-permissions)). The app retries a few times automatically before giving up.
- **It struggles to start while Zoom + Krisp (or another audio tool) is active.** Apps like Krisp insert their own virtual audio devices, which can briefly block capture while a call is connecting. The app retries automatically and should latch on within a few seconds.
- **A recording got cut off (crash, sleep, force-quit).** Nothing is lost — relaunch the app, and it finishes the interrupted recording on launch. You can also choose **Recover Interrupted Recordings** from the menu.
- **No transcript appeared.** Check that `~/.meeting2.env` exists and contains a valid `GOOGLE_API_KEY`, then choose **Transcribe Pending Recordings**.
- **macOS keeps re-asking for permissions after every rebuild.** Sign the app with a free Apple Developer identity (see the tip under [Get it on your Mac](#get-it-on-your-mac)) so the permissions stick.

---

## Status

This is an early, personal-use build. 

**Working today:** manual start/stop recording, crash-safe saving, automatic compression, and automatic post-meeting transcription. 

**Planned:** automatically detecting when a meeting starts (so you don't have to press Start), and naming recordings from your calendar.

# Per-app automatic recording

Status: implemented. Per-app controls and detector fixes were built together, extending [AUTODETECT.md](AUTODETECT.md). Automated tests cover policy, preferences, delayed controller reads, and window behavior. Real app identities can be checked during normal use through debug logs; a separate survey phase is not required.

## Goal

Let the user turn automatic recording off or on for individual apps, such as dictation tools. Settings shows apps previously seen using the microphone, including ignored apps, with search and a checkbox for each app.

**These settings control when recording starts and stops, not which sounds are captured.** A recording started by Zoom can still contain sounds from a disabled app through the microphone or system audio. Manual recording remains available.

## Settings and defaults

Use one compact Settings view:

- The global automatic-recording toggle.
- Search by app name or bundle ID.
- An alphabetical list with each app's icon, name, and `Auto-record` checkbox.
- Bundle IDs as secondary information where names are ambiguous, especially for background services.

Newly observed apps default **on**, so an unfamiliar meeting app can still trigger recording. Known non-meeting speech services default **off**. The user's choice overrides either default. Meeting2 itself is always excluded and has no configurable row.

App preferences remain editable while the global toggle is off. Closing or uninstalling an app does not remove its saved name or preference. An empty list means no apps have been observed yet. This version needs no installed-app scan or manual bundle-ID editor.

Provide `Stop and disable auto-record for [app]` only during the automatic recording started when that app is first discovered, and only when the target is unambiguous. Keep it available for that recording; later recordings and app relaunches must not show it again. Use the saved discovered-app list to identify known apps, including apps first observed through Settings or a manual recording. Known apps can be changed in Settings. The shortcut saves the preference and follows the existing user-stop rules, which move recordings under 30 seconds to Trash rather than keeping every recording in the library.

## How app preferences affect recording

An enabled app using the microphone can start or keep an automatic recording running. A disabled app cannot do either. Apply that same filter to the call-ended notification, so an ignored speech service does not make a finished Zoom call appear active.

| Situation | Result |
| --- | --- |
| Only disabled dictation is using the mic | Do not start automatically. |
| Disabled dictation and enabled Zoom both use the mic | Zoom can trigger recording. |
| Zoom releases the mic but disabled dictation remains | Stop the automatic recording after the usual grace period. |
| The user disables the last enabled app using the mic during an automatic recording | Check again; stop after the usual grace period if no enabled app remains. |
| The user enables an app already using the mic while Meeting2 is idle | Check promptly; start if the global toggle is on and a previous Stop is not blocking that app. |
| The user changes app preferences during a manual recording | The preference change does not stop the recording. |

Preference changes request an immediate owner check through the existing coalesced polling path; no separate start/stop mechanism is needed for the checkbox. Reset the call-ended notification's owner baseline first so changing a setting does not announce that the call ended.

Check all apps using the microphone, not just the one saved as the recording's source. That source field describes the recording; it does not decide whether recording should continue. Keep the existing capture, finalization, short/silent recording cleanup, and transcription paths.

## Identifying apps

`MicOwnerMonitor` already asks Core Audio which processes are using audio input, excludes Meeting2 by process ID (PID), and returns their bundle IDs. Here, a "mic owner" means one of those processes. Keep the PID long enough for the app layer to look up a name and icon. Also exclude the exact Meeting2 bundle ID (`com.mirable.Meeting2`), so another running copy during development cannot trigger recording.

- **Save preferences by bundle ID.** PIDs change on relaunch, and names can change or be shared by different apps.
- **Look up names and icons with `NSRunningApplication(processIdentifier:)`.** It also provides the app's bundle location. An installed app can be looked up by bundle ID after it exits.
- **Use one preference per reported bundle ID.** Do not group helpers under parent apps in this implementation. Parent processes, bundle paths, name similarities, and bundle-ID prefixes do not provide a consistent mapping across apps. Keeping the reported identity avoids applying a preference to the wrong process.
- **Use reported identities without guessing.** Show the reported service when its app is unclear. A successful empty ID means an unbundled process and is ignored for automatic detection; it must not invalidate other owners in the same read. Such processes cannot trigger or sustain automatic recording on their own, but manual recording remains available. Nonempty reported IDs, including bare executable names, remain valid keys. Actual property-read failures still mean unknown.

There are limits to what this can identify:

- Standalone dictation apps can usually have individual preferences.
- Apple dictation and Siri may appear as a shared speech service, rather than the app receiving the text. Its preference applies to the whole service, not one text field or app.
- A browser may appear as the browser itself or an audio helper. This detector cannot tell a Meet call from dictation in another tab. One app can expose several helper identities, and a shared service can serve several apps, so a row is not guaranteed to represent exactly one whole browser or app.

Several Apple speech services are already ignored by default. If dictation still starts a recording, inspect all reported owners before adding exclusions: another app or helper may be responsible. Choosing the alphabetically first owner does not prove it caused the activity. Add helper grouping only if actual use reveals a specific problem and a reliable mapping.

Debug-only logs include the full observed owner set and the filtered result, including while idle. They are written when those sets or read-error states change, rather than on every poll. This lets ordinary use reveal app identities, including ignored-only activity, without a separate diagnostic tool or noisy logs.

## Remembering apps

Keep one small preferences model in the app layer, saved in `UserDefaults` alongside the global auto-record preference. Each entry needs only a bundle ID, last-known display name, and auto-record preference. Keep the name after the app exits. Cache icon lookups, including misses, in memory until Settings is next opened; do not save image data. A missing icon must not affect recording decisions.

Remember owners **before filtering out disabled apps**, so ignored apps appear in Settings and can be turned back on. Apply built-in exclusions as defaults, not permanent rules that override the user's choices. Exclude Meeting2 by PID and exact bundle ID before adding any entries.

Discover apps while automatic recording is enabled. Opening Settings can also refresh current owners with the global toggle off, without allowing automatic starts. Keep entries across restarts and write only when an app is discovered or its saved details change, not on every check.

## Reliable detection and Stop behavior

### Check while idle too

The original detector watched only the default input device. A call using another input, such as a webcam microphone, could start without changing the watched device's state. Its recording-only poll could not help because recording had not started yet.

There is a second gap: an ignored app may already hold the watched microphone when Zoom starts using it. The device can stay running throughout, so there is no new device change. This applies to apps that actually keep that device open; a service reporting input activity does not prove it holds the default physical mic. Do not assume CoreSpeech always does so.

Keep the device listener for quick starts and check owners every five seconds whenever automatic recording is enabled, including while idle. This adds a fallback when there is no device change. Recording can start several seconds late in that case; audio before detection cannot be recovered. The owner check covers all input devices, so it also finds apps using a non-default microphone. Checking ownership does not open or record the mic.

Use one polling loop for idle and recording checks, with Core Audio reads on the existing serial queue. Handle overlapping timer and device events without starting two recordings, and reject results from cancelled or outdated monitoring tasks.

### Keep each check tied to its recording

The original poll only checked the automatic-recording state and whether stopping was possible. If an automatic recording stopped and a manual one started before the next tick, the old poll could treat the manual recording as its own and stop or discard it.

Capture the controller's current folder when automatic start succeeds. Before and after each asynchronous owner read, check that the folder still matches, monitoring is still enabled, and the task has not been cancelled. Before applying a stop decision, repeat that check. A different folder ends the old poll's authority over recording. The existing folder identity is enough; no new session-ID system is needed.

### Treat failed reads as unknown

The original monitor returned an empty set when listing processes failed, and skipped processes whose relevant properties could not be read. Either could make a live call look finished. The monitor now returns an optional owner result: a complete, successful empty set means no identifiable external owners were found; `nil` means the answer is unknown. Relevant per-process read failures also make the result unknown. A successfully read empty ID is filtered out, rather than treated as a failed read. A failed name or icon lookup alone does not invalidate a known owner.

Do not use an unknown owner result to start or stop recording. Reset pending absence timers, including timers for releasing temporary Stop restrictions, but keep the restrictions themselves. Do not merely skip the tick while keeping an old absence timestamp: that would count the unknown interval toward the timeout. After reads recover, require a fresh grace period of successful checks showing absence. Apply this rule to the call-ended notification too. Independent silence and duration limits still apply.

### Respect manual and protective stops

While automatic recording is enabled, idle polling must not restart a recording just because its app still holds the mic. This applies to user Stop, short-recording discard, the 15-minute silence stop, and the three-hour cap, whether the ended recording was started manually or automatically. Without it, Zoom holding the mic after a silence stop would trigger another recording within five seconds and repeat indefinitely.

Record the restart restriction as part of the stop operation, using the enabled owners observed for the ending session. Do not rely on a poll noticing a transition to idle; a quick stop/start can happen between ticks. Do not let a delayed result from the old stop restrict a new app that appeared afterward. A failed read is not an empty owner snapshot.

If Stop happens before this recording's first owner observation, or while the latest read is failed or still pending, there is no complete owner set to restrict safely. An older recording's snapshot or a partially known set must not be treated as current. In that case, automatic starts wait until successful checks show no enabled owners for the usual grace period. This can delay a later call during that uncertainty, but avoids undoing Stop or assigning the old stop to a newly observed app. Manual Start remains available. A later manual recording stopped with a complete owner snapshot replaces that broad wait with restrictions for the identified owners.

Temporarily prevent those owners from triggering another automatic recording. Clear the restriction for each owner only after successful checks show it absent for the usual grace period. Track this per owner, so an always-on disabled service cannot prevent future recordings. A newly active enabled app that was not stopped can still trigger recording. These restrictions are not saved preferences, and manual Start remains available. A normal automatic stop after all enabled owners have left needs no restriction on unrelated future owners.

**The three-hour cap remains a real stop.** Its purpose is to catch forgotten recordings when noise prevents the silence rule from firing. Automatically restarting would defeat that protection. Consecutive files for a longer meeting would be an intentional recording-splitting feature, outside this change.

This approach only observes mic use. If an app holds the mic continuously between two calls, it cannot tell those calls apart and will keep the temporary restriction.

Restrictions prevent triggering, not sustaining a later recording: if stopped Zoom still holds the mic and Meet starts a new recording, Zoom can keep that recording running after Meet releases the mic, even if Zoom is only keeping a preview or background input open.

A failed automatic start also temporarily restricts its triggering owners, so polling does not retry indefinitely and create failed folders every five seconds. The existing Try Again action remains available; another unrestricted app can still trigger recording.

## Implementation

These are parts of one implementation, with tests alongside the changes:

- Extend `MicOwnerMonitor` with honest read-failure handling and enough information for app lookup. Keep user preferences and AppKit presentation in the app layer. Observe actual dictation and browser identities during normal validation.
- Add the shared preferences model and use its filter for automatic starts, automatic stops, and call-ended notifications.
- Extract a small value type for recording decisions, timers, and temporary restrictions. It takes owner observations, preferences, stop information, and a supplied time, and returns decisions and updated state. Keep Core Audio reads in the monitor and recording commands and UI work in the controller; no general rules engine or broad set of recorder protocols is needed.
- Add idle polling, folder checks, and stop restrictions through the existing recording commands. Keep a narrow way to test the controller's handling of delayed results; policy tests alone cannot verify that an old callback leaves a replacement recording alone.
- Add Settings and the contextual stop/disable action through the app delegate, using the current AppKit window with SwiftUI content pattern.

The app delegate creates one shared `MicOwnerMonitor`. Only auto-detect manages its listeners; Settings and recording supervision request fresh reads on its serial queue without owning its lifecycle.

Give the app delegate sole ownership of switching between normal app mode and menu-bar-only mode. Window controllers report opening and closing; they do not need to know about each other. Keep normal app mode while either user window is open, including when minimized. Exclude the window currently closing from that decision. A bare visible-window check is insufficient, and closing Settings must not hide an open Recordings window or vice versa.

Keep this focused: no database, general rules engine, browser extension, Accessibility-based guessing, audio-content classification, or capture rewrite. Editable timing thresholds, calendar work, and a general settings framework are outside this change.

## Verification

Automated tests should cover:

- Defaults, user overrides, and saved preferences.
- Ignored apps appearing in the list, and recording decisions with both enabled and disabled owners present.
- Restart restrictions after user Stop, short-recording discard, the silence limit, and the three-hour cap, including for manually started recordings. Use supplied time rather than waiting through real limits.
- Restrictions clearing after confirmed owner departure, and a new unrestricted app being allowed to trigger recording.
- An unknown read partway through an absence period restarting the grace timer without clearing restrictions. Cover both process-list and relevant per-process failures; missing names or icons must not change recording decisions.
- A controller-level regression test that stops an automatic recording and starts a manual one between polls, including a read completing afterward. The old poll must not stop or discard the new recording.
- Preference changes resetting the call-ended notification's baseline instead of announcing a false call end.
- Meeting2 excluded by both PID and exact bundle ID.
- Successful empty IDs ignored without discarding identified owners in the same read; nonempty bare names retained as keys.

Ordinary layout tests keep their windows offscreen. Set `MEETING2_UI_SNAPSHOT_DIR` only for visual verification that needs visible rendering and saved screenshots.

Manually check standalone dictation, Apple speech services, a browser call, and Zoom. Verify:

- Zoom is detected on a non-default input, such as a webcam mic.
- Zoom is detected while an ignored app actually holds the watched mic, and recording stops when Zoom leaves even if the ignored app remains.
- Manual Stop does not immediately restart recording.
- Turning an active app off or on follows the behavior table.
- Names and fallback identities are understandable for browser helpers and shared speech services. The contextual stop/disable action targets only an unambiguous owner and follows existing short-recording rules.
- The list and preferences survive a relaunch.
- Settings and Recordings behave correctly when both are open, including closing one while the other is minimized.

## References

- [Existing auto-detection plan](AUTODETECT.md).
- [Apple: NSRunningApplication](https://developer.apple.com/documentation/appkit/nsrunningapplication), for PID-based lookup, bundle ID, name, icon, and bundle location.
- [Apple: urlForApplication(withBundleIdentifier:)](https://developer.apple.com/documentation/appkit/nsworkspace/urlforapplication(withbundleidentifier:)), for finding an installed app by bundle ID.
- [Apple: kAudioProcessPropertyBundleID](https://developer.apple.com/documentation/coreaudio/kaudioprocesspropertybundleid). The local Core Audio `AudioHardware.h` also documents process input activity and bundle IDs.

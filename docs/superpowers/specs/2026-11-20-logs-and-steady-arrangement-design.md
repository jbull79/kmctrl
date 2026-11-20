# KMctrl — log request from both Macs, and an arrangement that stays put (design)

Date: 2026-11-20. Status: built, not yet released (0.8.24).

## 1. The arrangement keeps resetting

**Report (Joe):** once set, the edge hand-off arrangement on the controlling Mac keeps going back
to a different place. It should only change when it's changed by hand.

**Cause (most likely; not yet confirmed on hardware).** The arrangement was saved as a
`CGDirectDisplayID`. macOS renumbers displays after sleep, a dock or hub reconnect, or a restart.
When the saved number no longer matched a monitor, the controller fell back to the main display
and Settings fell back to the first screen. Nothing wrote the setting back, so it looked reset
until it was re-dragged. The next renumbering then broke it again.

**Fix.**
- `DisplayIdentity` records the monitor itself: ColorSync's display UUID (from the EDID), plus
  vendor, model and serial, and its name for messages.
- It is saved next to the display number (`kmctrl.handoffDisplayIdentity`). Only a drag in the
  arrangement changes it.
- `HandoffAnchor.resolve` finds that monitor among the ones connected now, trying in turn:
  1. the UUID;
  2. vendor, model and serial;
  3. vendor and model.

  Twins that nothing else tells apart prefer the saved number.
- While the monitor isn't connected, the other Mac sits beside the main display. Settings says
  so, and the saved arrangement is left alone.
- An arrangement saved by 0.8.23 or earlier adopts the identity of the monitor its number points
  at, once, at launch.
- The controller logs when the monitor turns up under a new number, or is missing. That confirms
  the cause from the logs below.

## 2. Pull diagnostics logs from either Mac

Either Mac can ask the other for its KMctrl Diagnostics log over the open control link, so both
logs can be collected from one Mac. The link is always dialled controller → controlled; the
controlled Mac answers over the same link.

**Protocol v6.**
- Controller asks: a `.logRequest` event. The controlled Mac answers with `ControlReturn.log`.
- Controlled Mac asks: `ControlReturn.logRequest`. The controller answers with a `.log` event,
  which is JSON only.
- Both new kinds are appended to the binary wire order.
- `isReturnSignal` excludes `log` and `logRequest`.
- Neither request is sent to a v5 peer. A v5 peer would drop the session on the unknown event
  kind, or read the reply as a return of control.

**Content.** `LogBundle`: the device name, KMctrl version, macOS version, a timestamp, whether
diagnostics logging was on, and the transcript. Before it is saved:
- it is cut to its newest 1 MB;
- control characters other than newline and tab are stripped;
- names are cleaned.

It is KMctrl's own log only; keystrokes and clipboard contents are never logged. Nothing is
collected from macOS's system log.

**Limits.**
- A log is taken only within 30 s of asking.
- Answers are rate-limited to one every 2 s.
- Only an authenticated, trusted session can ask.

**Saving.**
- Files go to `~/Library/Logs/KMctrl/`: `<this Mac>.log` and `<other Mac> (received).log`, each
  replaced each time.
- The sandbox gets a single home-relative read-write exception for that folder.

**Triggers.**
- Settings → Diagnostics → Save Logs, with Show in Finder.
- `kmctrl://logs`, using `open -g -b com.kmctrl.KMctrl kmctrl://logs`. It takes no parameters,
  only writes those files and asks the peer, and calls less than 3 s apart are ignored.

## Not in scope

- Turning diagnostics logging on remotely. It stays a choice made on each Mac.
- Keeping the log on disk all the time.

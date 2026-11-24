# KMctrl 1.0 — cleanup (design)

Date: 2026-11-24. Status: built, not yet released.

Joe's brief for 1.0: no support for old versions, and any code that isn't used goes. Edge mode
(the event tap) stays; it is the better option on Macs without MDM.

## One version gate

- `SessionHello.minimumControlVersion` is 7 and `minimumAppVersion` is "1.0".
- Each side checks the other's version once, when the session is set up:
  - the controlled Mac checks the hello, before any approval prompt;
  - the controller checks the ack.
- A Mac below the minimum is refused with a message naming the version to update to.
- A hello without a version (0.7.x) decodes as v1, so it gets that message instead of a
  dropped connection.
- Every per-feature check (`peerVersion >= n`, `hostVersion >= n`, `sendsProbes`,
  `sendsEdgeSetup`, `sendsLogRequest`) is gone.
- Old-version fallbacks are gone too:
  - `ControlSetup.returnSpan` and the single-edge return from it;
  - `ReturnWatch.reportsZone`;
  - the 0.8.23 arrangement-identity migration;
  - the UserDefaults → Keychain identity-key migration.
- One safety net stays. A setup with no usable return zone still returns across the whole side
  opposite `hostEdge`, so the pointer can't get stuck on the other Mac.

## Protocol v7

- The experimental binary control codec is removed: frames are JSON only.
- 0.8.24 could send binary frames, so 1.0 doesn't accept 0.8.x.
- Removing the codec also removes its pieces: the wire-order table, the codec flag on the
  link, and the "Binary control protocol" setting.

## Settings

- **"Switch to the other Mac at the screen edge"** is no longer experimental. Joe uses it every
  day on the MDM work Mac. The Swift property is now `pointerEdgeSwitch`; its stored key is
  unchanged, so the setting carries over.
- **"Mouse flush interval"** is removed. It is fixed at 8 ms, the default everyone ran.
- **"Connection methods"** is removed. Its toggles only fed the status query, and control
  always used the raw socket.

## Unused code removed

- **Network.framework transports:**
  - the outbound strategies `nwProhibitOther` and `nwDefault`;
  - `NWByteStream` and the `NWConnection` ready helper;
  - the winner cache;
  - the `NWListener` fallback. It couldn't carry a control session, because control replies
    are written synchronously to the raw socket. A bind failure is now reported instead.
  - Bonjour resolution still uses `NWConnection`.
- **The status session:** `SessionKind.status`, `StatusReport`, `queryStatus` and
  `localStatusReport`. Nothing ever queried it.
- **Models and views left from NetCatch:**
  - `SessionKind.transfer/sync/clipboard`, `SyncAck`, `TransferHeader`, `TransferItem` and
    friends; `Handshake` moves to its own file;
  - `ClipboardSyncState`;
  - `EmptyPlaceholder` (`WindowAccessor` moves to its own file);
  - the `Format` helpers, `LocalNetwork.lanInterface`/`lanInterfaceName` and `Atomic`;
  - `ControlManager.setDiscoverable` and `Theme.s5`.

## Also in 1.0

The saved and copied log lines carry the date, a 24-hour time and the time zone.

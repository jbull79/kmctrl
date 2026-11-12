# KMctrl — hand off at any edge that touches the other Mac (design)

Date: 2026-11-11. Status: building.

## Goal

Today one edge of one monitor hands off: on Joe's desk, the top of the work Mac's 49"
ultrawide, under the home 24". Joe wants every edge that sits next to the home screen to work.
The home 24" sits above the ultrawide's left half and beside the work Mac's own 24" (which is
above the ultrawide's right half), so the work 24"'s left edge should switch as well.

He also wants the work Mac's monitor arrangement passed to the Mac being controlled, so that
Mac knows (and shows) where it sits among the work Mac's monitors.

## Model

The other Mac's screen is placed once in Settings, exactly as now: next to an **anchor**
monitor, on one of its edges, slid along it (millimetres). From that, `HandoffLayout`:

- places the other screen as a **tile** in this Mac's global points, flush against the anchor
  edge and sized at the anchor's physical density;
- finds every **portal**, meaning a stretch of one of this Mac's monitor edges that leads to
  the tile.

The mapping along every portal goes through the tile's extent, so the anchor portal maps
exactly as `HandoffGeometry` did.

### Which edges become portals

1. **Facing the tile.** Any monitor whose edge faces a side of the tile across a gap of no
   more than 150 mm (physical, at the anchor's density) is a portal. The anchor itself has a
   gap of 0. The gap allows for bezels and desk space, because macOS display positions are
   not physical.
2. **Stretches that lead into another monitor are cut out.** On those stretches the pointer
   just moves on to the next monitor, as it does today.
3. **Between two monitors.** If the tile is dropped on a seam (the anchor edge has another
   monitor directly beyond it, overlapping at least half the tile's length), the other Mac
   counts as sitting *between* them:
   - crossing the seam goes to the other Mac;
   - both monitors' seam edges are portals;
   - leaving the other Mac through its far side lands on the far monitor.

### Detecting a switch (controlling Mac, no permissions)

`PortalWatch` replaces `EdgeDwell`. It polls the pointer as now:

- **Outer edge:** the pointer rests 0.2 s on the last row or column inside a portal stretch,
  the same as today.
- **Seam:** the pointer crosses from a monitor across a portal stretch into the neighbouring
  monitor. This fires immediately, at the interpolated crossing point.
- **Never while a mouse button is held**, so dragging a window between monitors doesn't hand
  off.

Edge mode (event tap) uses the same watch with no dwell.

## Protocol v5 (backward compatible)

- `ControlSetup.returnZones`: one zone per portal (the side of the controlled Mac's screen
  and the stretch along it). A v4 controlled Mac ignores it and keeps the legacy
  `hostEdge`/`returnSpan`, which are still filled from the anchor portal.
- `ControlSetup.arrangement`: an `ArrangementSnapshot` containing the controller's monitors
  (geometry and name), where the tile sits, and the portal stretches. The controlled Mac
  sanitises it, saves it and shows it read-only in Settings.
- `ControlReturn.zone`: which zone the pointer pushed through, so the controller lands on the
  matching monitor. When it is absent, the controller uses the anchor portal.
- `currentControlVersion` goes from 4 to 5. All new fields are optional JSON, and older
  peers ignore them.

## Controlled Mac

`ReturnWatch` holds one `EdgeReturnTrigger` per zone and returns the zone that fired. A
deliberate 40 pt push is still needed, and a return never happens while a button is held.

## UI

- **Controller, Settings → Control:** the arrangement canvas draws the tile flush and
  highlights every portal stretch. The caption lists the monitors and edges that hand off.
- **Controlled Mac, Settings → Control:** a new read-only "Arrangement on ⟨controller⟩"
  canvas, from the last snapshot received.

## Not in scope

- The controlled Mac's own extra monitors. Its main display is still the one the pointer
  arrives on.
- Snapping in the arrangement editor.
- Editing the arrangement from the controlled Mac.

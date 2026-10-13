# KMctrl

A tiny native macOS app to **control another Mac's keyboard and mouse over the local
network** — one Mac drives another, no cloud, no accounts. Split out from
[NetCatch](https://github.com/jbull79/netcatch)'s KVM feature into a focused standalone app.

Built for the case NetCatch was: bridging a **locked-down / MDM work Mac** to a personal
one. **Window mode needs no permissions** (works on a managed Mac), so you can drive the
other machine without admin rights.

## Download

**[⬇ KMctrl 0.8.8 — download the app](https://github.com/jbull79/kmctrl/releases/download/v0.8.8/KMctrl-0.8.8.zip)** · [all releases](https://github.com/jbull79/kmctrl/releases)

Unsigned, ad-hoc, **Apple Silicon only** (won't run on Intel). macOS quarantines
downloaded unsigned apps — clear it (no admin needed on your own files):

```bash
xattr -dr com.apple.quarantine ~/Applications/KMctrl.app && open ~/Applications/KMctrl.app
```

If it still won't open, your MDM enforces Gatekeeper — build locally in Xcode instead.

## How it works

- **Discovery** — Bonjour (`_kmctrl._tcp`); peers appear automatically.
- **Security** — signed Curve25519 ECDH handshake → AES-GCM session, trust-on-first-use
  fingerprints (same core as NetCatch).
- **Control** — the controlling Mac captures input and streams relative mouse/keyboard
  events; the controlled Mac injects them with `CGEvent`.
  - **Window mode** (default) — click the capture area to start; press **⌃⌥⌘** to release.
    No Accessibility/Input Monitoring needed → works on a locked-down MDM Mac.
  - **Edge mode** — bump a screen edge to hand off. Needs Accessibility + Input Monitoring
    (admin-grantable), so it's for non-MDM Macs.

## Features (0.8)

- **Clipboard sync** — text and images copied on either Mac appear on the other during a
  session (trusted Macs only; toggle per Mac).
- **Layout-independent typing** — the controlled Mac types what *your* keyboard layout
  produced, even if its own layout differs. ⌘/⌃ shortcuts stay keycode-based.
- **Media keys** — volume, brightness, play/pause, next/previous are forwarded. (macOS also
  applies volume/brightness locally on the controlling Mac; only an event tap could stop
  that, and MDM blocks those.)
- **Mouse speed** slider (0.25×–3×) on the controlling Mac.
- **⌃⌥⌘K re-grab** — start controlling again from any app while a session is open. ⌃⌥⌘
  alone still releases. Carbon hotkey: no permissions, works on MDM Macs.
- **Wake screen** — the remote display is woken when you start controlling, or on demand.
- **Update check** — once a day against GitHub releases (toggle in Settings → General).
- **Swipe-safe capture** — a Magic Mouse / trackpad system swipe no longer drops control.

## Use

Install KMctrl on **both** Macs.

1. On the Mac you want to **be controlled**: toggle **Allow this Mac to be controlled** on.
2. On the **controlling** Mac: pick the other Mac under *Control a device* → **Control** →
   **Start controlling**. Drive it with your keyboard/mouse; **⌃⌥⌘** releases.

## Build

```sh
xcodebuild -scheme KMctrl -configuration Release build
xcodebuild -scheme KMctrl test          # unit tests (KMctrlTests)
```

Requires macOS 13+. The app is ad-hoc/self-signed (not notarized) — a downloaded copy is
quarantined, so clear it once: `xattr -dr com.apple.quarantine /Applications/KMctrl.app`,
or **System Settings → Privacy & Security → Open Anyway**.

`scripts/sign-local.sh` signs with a stable self-signed cert so TCC permissions persist
across rebuilds (no Apple Developer account needed).

## Status

0.8 — daily-usable window-mode KVM. The networking/crypto core is shared (vendored) from
NetCatch and covered by tests there; KMctrl's own logic (control codec, key/media-key
mapping, versioning, clipboard state) is covered by `KMctrlTests`. Design notes live in
`docs/superpowers/specs`.

**Protocol note:** the experimental binary control codec in 0.8 carries typed characters, so
both Macs must run 0.8+ when that flag is on. The default JSON path interoperates with 0.7.x
(new features are simply not sent to an older peer).

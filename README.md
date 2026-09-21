# KMctrl

A tiny native macOS app to **control another Mac's keyboard and mouse over the local
network** — one Mac drives another, no cloud, no accounts. Split out from
[NetCatch](https://github.com/jbull79/netcatch)'s KVM feature into a focused standalone app.

Built for the case NetCatch was: bridging a **locked-down / MDM work Mac** to a personal
one. **Window mode needs no permissions** (works on a managed Mac), so you can drive the
other machine without admin rights.

## Download

**[⬇ KMctrl 0.6.0 (Debug) — download the app](https://github.com/jbull79/kmctrl/releases/download/v0.6.0-debug/KMctrl-0.6.0-debug.zip)** · [all releases](https://github.com/jbull79/kmctrl/releases)

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

## Use

Install KMctrl on **both** Macs.

1. On the Mac you want to **be controlled**: toggle **Allow this Mac to be controlled** on.
2. On the **controlling** Mac: pick the other Mac under *Control a device* → **Control** →
   **Start controlling**. Drive it with your keyboard/mouse; **⌃⌥⌘** releases.

## Build

```sh
xcodebuild -scheme KMctrl -configuration Release build
```

Requires macOS 13+. The app is ad-hoc/self-signed (not notarized) — a downloaded copy is
quarantined, so clear it once: `xattr -dr com.apple.quarantine /Applications/KMctrl.app`,
or **System Settings → Privacy & Security → Open Anyway**.

`scripts/sign-local.sh` signs with a stable self-signed cert so TCC permissions persist
across rebuilds (no Apple Developer account needed).

## Status

Early standalone split (v0.1). The networking/crypto core is shared (vendored) from NetCatch
and is covered by tests in that repo.

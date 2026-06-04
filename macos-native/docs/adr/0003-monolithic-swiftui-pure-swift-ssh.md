# Monolithic SwiftUI client with a pure-Swift SSH engine (no Qt, no libssh)

## Context

The macOS client was a Qt app that spawned a separate Metal viewer process per
session ([[0001-per-session-xvfb-and-viewer]], [[0002-remove-xquartz-path]]). The
goal became a single, modern macOS app that manages multiple connections
in-process, embeds the remote desktop as SwiftUI/Metal views (no external
viewer), and keeps only the NX tooling that is genuinely needed — with **no C++
and no Qt** surviving.

## Decision

Rebuild the macOS client as one SwiftUI app (`X2GoApp`) over a Swift package:
`CX11` (the only C — Xlib/XTEST to the local Xvfb), `X2GoDisplay`, `X2GoProtocol`,
`X2GoSSH`, `X2GoEngine`, `X2GoApp`, and an `x2go-probe` verification CLI. **SSH is
pure Swift** via Apple's `swift-nio-ssh` (connect/auth, exec, and a directTCPIP
local port-forward for the NX tunnel). Qt and libssh are gone from the macOS
product; `nxproxy`/`Xvfb` remain as bundled helper binaries.

## Considered Options

- **Citadel** (higher-level Swift SSH) — rejected: it pins an ancient
  `swift-nio-ssh` (0.3.x) that no longer resolves; using `swift-nio-ssh` directly
  is current, conflict-free, and gives us the raw directTCPIP channel we need.
- **Bridge the existing C++ engine** (sshmasterconnection + onmainwindow) — rejected
  per the "no C++" goal; it would drag Qt-Core coupling in.

## Consequences

- The NX tunnel is implemented ourselves (NIO listener ↔ SSH directTCPIP child
  channel) — proven against the live server before any UI (the gate).
- `X2GoSSH` builds in Swift 5 language mode (SwiftNIO `Channel`/handlers aren't
  Sendable); the rest of the app is Swift 6. The actor exposes only Sendable
  results across its boundary.
- v1 scope is core remote desktop (key/password auth, new/resume/suspend/terminate,
  N sessions, display+input+clipboard). Deferred: sound, printing, folder-sharing,
  broker/LDAP, RDP, Kerberos, keyboard-interactive auth (not in swift-nio-ssh).
- The Qt tree remains only as the Linux/Windows client; the shipped `X2Go.app`
  asserts at build time that it contains zero Qt and zero `/opt/X11` references.

# Native macOS X2Go client

The macOS client is now a single, modern **Swift/SwiftUI app** (`X2GoApp`) — no
Qt, no libssh, no separate viewer process, no XQuartz. It manages multiple
connections in-process, each forking its own headless Xvfb and rendering the
remote desktop in-app via Metal. The only native code is the bundled `nxproxy`
(NX codec) + `Xvfb` binaries and the small `CX11` Xlib/XTEST bridge.
See `docs/adr/` for decisions and `IMPLEMENTATION-viewer-lifecycle.md` history.

## Language

**X2GoApp**:
The native SwiftUI macOS client (the whole app). Replaces the Qt `x2goclient`
*and* the old standalone Metal viewer on macOS.
_Avoid_: x2goclient (that's the retired Qt app), the viewer, x2goapp

**Connection**:
One live X2Go session the user has opened — its own window, Xvfb, NX tunnel,
nxproxy, and X11Session. Modelled by a `ConnectionViewModel` + an engine
`X2GoSession`. Multiple may run at once.
_Avoid_: session (when the local stack is meant), tab, window

**Engine** (`X2GoSession`):
The per-connection orchestration actor: SSH connect/auth, start/resume the remote
agent, fork Xvfb, open the NX tunnel, launch nxproxy, run the desktop, and
suspend/terminate. Lives in the `X2GoEngine` module.
_Avoid_: backend, controller

**Session display**:
The private, headless `Xvfb` one connection renders into via nxproxy. Its root
size equals the resolved session geometry. One per connection.
_Avoid_: X server, Xvfb (in prose), display

**Session Manager**:
The app's home window: a grid of profile cards to create/edit/delete and connect.
_Avoid_: session list, dashboard

**Profile** (`SessionProfile`):
Saved connection settings (host, user, key, command, display size, …), stored as
Codable JSON in Application Support and one-time-imported from the old
`~/.x2goclient/sessions` INI.
_Avoid_: session config, bookmark

**NX tunnel**:
The SSH local port-forward (pure-Swift, directTCPIP over swift-nio-ssh) carrying
the NX stream between local nxproxy and the remote nxagent.
_Avoid_: graphics tunnel, port forward (in prose)

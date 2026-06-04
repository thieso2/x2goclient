import SwiftUI
import AppKit
import X2GoEngine
import X2GoProtocol
import X2GoSSH
import X2GoDisplay

// Native macOS X2Go client — one SwiftUI app, pure-Swift engine, in-app Metal
// display. Session Manager + window-per-connection, multi-session. No Qt, no
// external viewer, no XQuartz.

@MainActor
final class AppState {
    static let shared = AppState()
    weak var coordinator: SessionCoordinator?
    func focusedZoom() -> ZoomControl? {
        guard let c = coordinator, let id = c.focusedID else { return nil }
        return c.connection(for: id)?.zoom
    }
}

/// The View menu's zoom commands talk to the focused connection's scroll view.
@MainActor
final class ZoomControl {
    weak var scrollView: RemoteScrollView?
    func zoomIn()     { scrollView?.zoomIn() }
    func zoomOut()    { scrollView?.zoomOut() }
    func actualSize() { scrollView?.setManual(1) }
    func fit()        { scrollView?.fit() }
}

/// Hosts the live remote display (RemoteScrollView + RemoteMetalView) and wires
/// the window into the clipboard arbiter.
struct MetalHost: NSViewRepresentable {
    let vm: ConnectionViewModel
    func makeNSView(context: Context) -> NSView {
        guard let r = vm.renderer, let x = vm.x11 else { return NSView() }
        let mv = RemoteMetalView(renderer: r, session: x)
        mv.startRendering()
        let sv = RemoteScrollView(metalView: mv, sessionSize: vm.sessionSize)
        vm.zoom.scrollView = sv
        let wantFs = vm.wantFullscreen
        let cid = vm.id
        DispatchQueue.main.async {
            mv.window?.makeFirstResponder(mv)
            if let w = mv.window { ClipboardArbiter.shared.register(window: w, connection: cid) }
            if wantFs, let w = mv.window, !w.styleMask.contains(.fullScreen) {
                w.toggleFullScreen(nil)
            }
        }
        return sv
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

struct ConnectionView: View {
    @State var vm: ConnectionViewModel
    var body: some View {
        ZStack {
            Color.black
            switch vm.state {
            case .connecting(let msg):
                VStack(spacing: 12) {
                    ProgressView()
                    Text(msg).foregroundStyle(.secondary)
                }
            case .connected:
                MetalHost(vm: vm).frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay {
                        if !vm.desktopReady {
                            VStack(spacing: 10) {
                                ProgressView()
                                Text("Starting desktop…").foregroundStyle(.secondary)
                            }
                            .padding(20)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                        }
                    }
            case .failed(let msg):
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle").font(.largeTitle)
                    Text(msg).multilineTextAlignment(.center).foregroundStyle(.secondary)
                }.padding()
            }
        }
        .navigationTitle(vm.windowTitle)   // live: name + transfer stats
        .overlay {
            if let sessions = vm.pendingSessions {
                SessionChooserView(sessions: sessions, vm: vm)
            }
        }
    }
}

/// Offers existing server sessions to reconnect to (suspend/resume is X2Go's
/// signature feature), or start a new one.
struct SessionChooserView: View {
    let sessions: [X2GoProtocol.SessionInfo]
    let vm: ConnectionViewModel
    var body: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()
            VStack(spacing: 14) {
                Text("Reconnect to a session?").font(.headline)
                Text("This server already has sessions running:")
                    .font(.subheadline).foregroundStyle(.secondary)
                ForEach(sessions, id: \.sessionId) { s in
                    Button { vm.resolveChoice(.resume(s)) } label: {
                        HStack(spacing: 10) {
                            Image(systemName: s.isSuspended ? "pause.circle.fill" : "play.circle.fill")
                                .foregroundStyle(s.isSuspended ? .orange : .green)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(s.isSuspended ? "Suspended session" : "Running session")
                                Text("display :\(s.display) · started \(s.createTime)")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "arrow.right.circle")
                        }
                        .frame(width: 360)
                    }
                    .buttonStyle(.bordered)
                }
                HStack {
                    Button("New Session") { vm.resolveChoice(.new) }
                        .buttonStyle(.borderedProminent)
                    Button("Cancel") { vm.resolveChoice(.cancel) }
                }
                .padding(.top, 4)
            }
            .padding(24)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            .frame(maxWidth: 460)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    // Keep the app running when a connection window closes (the manager stays).
    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { false }

    /// Suspend every live session before quitting (kills nxproxy/Xvfb cleanly).
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let c = AppState.shared.coordinator, !c.connections.isEmpty else { return .terminateNow }
        Task {
            await c.closeAll()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

@main
struct X2GoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @State private var store = ProfileStore()
    @State private var coordinator = SessionCoordinator()

    var body: some Scene {
        Window("X2Go", id: "manager") {
            SessionManagerView(store: store, coordinator: coordinator)
                .onAppear {
                    AppState.shared.coordinator = coordinator
                    ClipboardArbiter.shared.configure(coordinator)
                }
        }
        .defaultSize(width: 900, height: 580)

        WindowGroup(id: "connection", for: UUID.self) { $cid in
            ConnectionWindowView(coordinator: coordinator, id: cid)
        }
        .defaultSize(width: 1280, height: 800)
        .commands {
            CommandGroup(after: .sidebar) {
                Button("Zoom In") { AppState.shared.focusedZoom()?.zoomIn() }
                    .keyboardShortcut("=", modifiers: .command)
                Button("Zoom Out") { AppState.shared.focusedZoom()?.zoomOut() }
                    .keyboardShortcut("-", modifiers: .command)
                Button("Actual Size") { AppState.shared.focusedZoom()?.actualSize() }
                    .keyboardShortcut("0", modifiers: .command)
                Button("Fit to Window") { AppState.shared.focusedZoom()?.fit() }
                    .keyboardShortcut("f", modifiers: [.command, .shift])
                Divider()
            }
        }
    }
}

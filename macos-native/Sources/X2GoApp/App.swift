import SwiftUI
import AppKit
import X2GoEngine
import X2GoProtocol
import X2GoSSH
import X2GoDisplay

// Native macOS X2Go client — one SwiftUI app, pure-Swift engine, in-app Metal
// display. P4: a single hard-coded connection window (Session Manager +
// multi-window arrive in P5/P6). No Qt, no external viewer.

@MainActor
final class AppState {
    static let shared = AppState()
    var vm: ConnectionViewModel?
}

/// The View menu's zoom commands talk to the live scroll view through this.
@MainActor
final class ZoomControl {
    weak var scrollView: RemoteScrollView?
    func zoomIn()     { scrollView?.zoomIn() }
    func zoomOut()    { scrollView?.zoomOut() }
    func actualSize() { scrollView?.setManual(1) }
    func fit()        { scrollView?.fit() }
}

/// Hosts the live remote display (RemoteScrollView + RemoteMetalView).
struct MetalHost: NSViewRepresentable {
    let vm: ConnectionViewModel
    func makeNSView(context: Context) -> NSView {
        guard let r = vm.renderer, let x = vm.x11 else { return NSView() }
        let mv = RemoteMetalView(renderer: r, session: x)
        mv.startRendering()
        let sv = RemoteScrollView(metalView: mv, sessionSize: vm.sessionSize)
        vm.zoom.scrollView = sv
        let wantFs = vm.wantFullscreen
        let title = vm.title
        DispatchQueue.main.async {
            mv.window?.makeFirstResponder(mv)
            if !title.isEmpty { mv.window?.title = title }
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
            case .failed(let msg):
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle").font(.largeTitle)
                    Text(msg).multilineTextAlignment(.center).foregroundStyle(.secondary)
                }.padding()
            }
        }
        .onAppear { vm.connect() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }

    /// Suspend the session before quitting (kills nxproxy/Xvfb cleanly).
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let vm = AppState.shared.vm else { return .terminateNow }
        Task {
            await vm.teardown()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

@main
struct X2GoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @State private var vm: ConnectionViewModel

    init() {
        let config = Self.devConfig()
        let model = ConnectionViewModel(config: config, title: "X2Go — \(config.endpoint.host)")
        _vm = State(initialValue: model)
        AppState.shared.vm = model
    }

    var body: some Scene {
        WindowGroup {
            ConnectionView(vm: vm)
        }
        .defaultSize(width: 1280, height: 800)
        .commands {
            CommandGroup(after: .sidebar) {
                Button("Zoom In") { AppState.shared.vm?.zoom.zoomIn() }
                    .keyboardShortcut("=", modifiers: .command)
                Button("Zoom Out") { AppState.shared.vm?.zoom.zoomOut() }
                    .keyboardShortcut("-", modifiers: .command)
                Button("Actual Size") { AppState.shared.vm?.zoom.actualSize() }
                    .keyboardShortcut("0", modifiers: .command)
                Button("Fit to Window") { AppState.shared.vm?.zoom.fit() }
                    .keyboardShortcut("f", modifiers: [.command, .shift])
                Divider()
            }
        }
    }

    /// P4 hard-coded connection (the test server). P5 replaces this with profiles.
    static func devConfig() -> X2GoSession.Config {
        let key = URL(fileURLWithPath: NSHomeDirectory() + "/.ssh/id_x2go_test")
        return X2GoSession.Config(
            endpoint: SSHEndpoint(host: "10.248.1.20", username: "thies"),
            credentials: [.privateKeyFile(key)],
            command: "startxfce4",
            kind: .desktop,
            displayMode: .custom(width: 1280, height: 800),
            screen: Geometry(width: 1280, height: 800),
            tools: AppTools.resolve(),
            preferResume: true)
    }
}

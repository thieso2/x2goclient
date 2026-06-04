import SwiftUI
import AppKit
import X2GoDisplay

// Native macOS X2Go display client — SwiftUI + Metal.
// Launched per-connection by x2goclient with:
//   --display :N  --geometry WxH  [--fullscreen]  [--title <name>]

@MainActor
@Observable
final class SessionModel {
    enum State { case connecting, connected, failed(String) }
    var state: State = .connecting

    let session = X11Session()
    let clipboard = ClipboardBridge()
    var renderer: MetalRenderer?
    let zoom = ZoomControl()

    let title: String
    let wantFullscreen: Bool
    let initialSize: CGSize

    private let display: String
    private let prefix: String

    init(display: String, prefix: String, geometry: CGSize,
         title: String, fullscreen: Bool) {
        self.display = display
        self.prefix = prefix
        self.title = title
        self.wantFullscreen = fullscreen
        // Open no larger than the visible screen; the viewer fits/scrolls beyond.
        let vis = NSScreen.main?.visibleFrame.size ?? CGSize(width: 1280, height: 800)
        self.initialSize = CGSize(width: min(geometry.width, vis.width),
                                  height: min(geometry.height, vis.height))
    }

    func connect() {
        guard let r = MetalRenderer() else {
            state = .failed("Metal device/pipeline unavailable")
            return
        }
        renderer = r
        let session = self.session
        let display = self.display, prefix = self.prefix
        Task.detached(priority: .userInitiated) {
            let ok = session.connect(displayName: display, windowPrefix: prefix)
            await MainActor.run {
                if ok {
                    session.start()
                    self.clipboard.start(display: display)   // copy/paste X ↔ macOS
                    self.state = .connected
                } else {
                    let what = prefix.isEmpty ? "display \(display) (is Xvfb running?)" : "'\(prefix)' window on \(display)"
                    self.state = .failed("Could not connect to \(what).\nStart Xvfb and the X2Go session first.")
                }
            }
        }
    }
}

/// Thin handle the View menu talks to; wired to the live scroll view.
@MainActor
final class ZoomControl {
    weak var scrollView: RemoteScrollView?
    func zoomIn()     { scrollView?.zoomIn() }
    func zoomOut()    { scrollView?.zoomOut() }
    func actualSize() { scrollView?.setManual(1) }
    func fit()        { scrollView?.fit() }
}

struct MetalHost: NSViewRepresentable {
    let model: SessionModel
    func makeNSView(context: Context) -> RemoteScrollView {
        guard let r = model.renderer else {
            return RemoteScrollView(metalView: RemoteMetalView(renderer: MetalRenderer()!, session: model.session),
                                    sessionSize: .init(width: 1, height: 1))
        }
        let mv = RemoteMetalView(renderer: r, session: model.session)
        mv.startRendering()
        let sv = RemoteScrollView(
            metalView: mv,
            sessionSize: NSSize(width: model.session.width, height: model.session.height))
        model.zoom.scrollView = sv
        let wantFs = model.wantFullscreen
        let title = model.title
        DispatchQueue.main.async {
            mv.window?.makeFirstResponder(mv)
            if !title.isEmpty { mv.window?.title = title }
            if wantFs, let w = mv.window,
               !w.styleMask.contains(.fullScreen) {
                w.toggleFullScreen(nil)
            }
        }
        return sv
    }
    func updateNSView(_ nsView: RemoteScrollView, context: Context) {}
}

struct ContentView: View {
    @State var model: SessionModel
    var body: some View {
        ZStack {
            Color.black
            switch model.state {
            case .connecting:
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Connecting to X2Go session…").foregroundStyle(.secondary)
                }
            case .connected:
                MetalHost(model: model)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let msg):
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle").font(.largeTitle)
                    Text(msg).multilineTextAlignment(.center).foregroundStyle(.secondary)
                }.padding()
            }
        }
        .onAppear { model.connect() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }
}

@main
struct X2GoNativeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @State private var model: SessionModel

    init() {
        // CLI: --display :N [--prefix P] [--geometry WxH] [--fullscreen] [--title T]
        var display = ProcessInfo.processInfo.environment["DISPLAY"] ?? ":99"
        var prefix = ""
        var title = "X2Go (native · Metal)"
        var fullscreen = false
        var geom = CGSize(width: 1280, height: 800)
        let args = CommandLine.arguments
        var i = 0
        while i < args.count {
            switch args[i] {
            case "--display"  where i + 1 < args.count: display = args[i + 1]; i += 1
            case "--prefix"   where i + 1 < args.count: prefix = args[i + 1]; i += 1
            case "--title"    where i + 1 < args.count: title = args[i + 1]; i += 1
            case "--fullscreen": fullscreen = true
            case "--geometry" where i + 1 < args.count:
                let parts = args[i + 1].lowercased().split(separator: "x")
                if parts.count == 2, let w = Double(parts[0]), let h = Double(parts[1]) {
                    geom = CGSize(width: w, height: h)
                }
                i += 1
            default: break
            }
            i += 1
        }
        _model = State(initialValue: SessionModel(display: display, prefix: prefix,
                                                  geometry: geom, title: title,
                                                  fullscreen: fullscreen))
    }

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
        }
        .defaultSize(width: model.initialSize.width, height: model.initialSize.height)
        .commands {
            // Merge into the existing (system) View menu rather than adding a
            // second one. .sidebar maps to the View menu region.
            CommandGroup(after: .sidebar) {
                Button("Zoom In")       { model.zoom.zoomIn() }
                    .keyboardShortcut("=", modifiers: .command)
                Button("Zoom Out")      { model.zoom.zoomOut() }
                    .keyboardShortcut("-", modifiers: .command)
                Button("Actual Size")   { model.zoom.actualSize() }
                    .keyboardShortcut("0", modifiers: .command)
                Button("Fit to Window") { model.zoom.fit() }
                    .keyboardShortcut("f", modifiers: [.command, .shift])
                Divider()
            }
        }
    }
}

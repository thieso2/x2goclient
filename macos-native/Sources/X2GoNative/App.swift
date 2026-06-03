import SwiftUI
import AppKit

// Native macOS X2Go display client — SwiftUI + Metal (Phase 3/4 prototype).

@MainActor
@Observable
final class SessionModel {
    enum State { case connecting, connected, failed(String) }
    var state: State = .connecting

    let session = X11Session()
    var renderer: MetalRenderer?

    private let display: String
    private let prefix: String

    init(display: String, prefix: String) {
        self.display = display
        self.prefix = prefix
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
                    self.state = .connected
                } else {
                    self.state = .failed("No '\(prefix)' window found on display \(display).\nStart an X2Go session first.")
                }
            }
        }
    }
}

struct MetalHost: NSViewRepresentable {
    let model: SessionModel
    func makeNSView(context: Context) -> NSView {
        guard let r = model.renderer else { return NSView() }
        let v = RemoteMetalView(renderer: r, session: model.session)
        v.startRendering()
        DispatchQueue.main.async { v.window?.makeFirstResponder(v) }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
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
                    .frame(width: CGFloat(model.session.width),
                           height: CGFloat(model.session.height))
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
        // CLI args: --display :0 --prefix X2GO-
        var display = ProcessInfo.processInfo.environment["DISPLAY"] ?? ":0"
        var prefix = "X2GO-"
        let args = CommandLine.arguments
        for i in 0..<args.count {
            if args[i] == "--display", i + 1 < args.count { display = args[i + 1] }
            if args[i] == "--prefix", i + 1 < args.count { prefix = args[i + 1] }
        }
        _model = State(initialValue: SessionModel(display: display, prefix: prefix))
    }

    var body: some Scene {
        WindowGroup("X2Go (native · Metal)") {
            ContentView(model: model)
        }
        .windowResizability(.contentSize)
    }
}

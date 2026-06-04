import SwiftUI
import X2GoEngine
import X2GoProtocol
import X2GoSSH
import X2GoDisplay

/// Owns one live connection: drives the engine to `connected`, then bridges the
/// engine's local Xvfb display into an X11Session for the Metal view + clipboard.
@MainActor
@Observable
final class ConnectionViewModel: Identifiable {
    enum UIState: Equatable {
        case connecting(String)
        case connected
        case failed(String)
    }

    let id = UUID()
    var state: UIState = .connecting("starting…")
    let renderer: MetalRenderer?
    private(set) var x11: X11Session?
    private(set) var sessionSize = CGSize(width: 1280, height: 800)
    let clipboard = ClipboardBridge()
    let zoom = ZoomControl()
    let wantFullscreen: Bool
    let title: String

    private let session: X2GoSession
    private var torn = false

    init(config: X2GoSession.Config, title: String) {
        self.renderer = MetalRenderer()
        self.session = X2GoSession(config: config)
        self.title = title
        self.wantFullscreen = (config.displayMode == .fullscreen)
    }

    func connect() {
        guard case .connecting = state else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                self.state = .connecting("connecting…")
                try await self.session.start()
                guard let disp = await self.session.localDisplay else {
                    throw NSError(domain: "X2Go", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: "no local display"])
                }
                let x = X11Session()
                let ok = await Task.detached { x.connect(displayName: disp, windowPrefix: "") }.value
                guard ok else {
                    x.close()
                    throw NSError(domain: "X2Go", code: 2,
                                  userInfo: [NSLocalizedDescriptionKey: "could not attach to \(disp)"])
                }
                x.start()
                self.x11 = x
                self.sessionSize = CGSize(width: x.width, height: x.height)
                self.clipboard.start(display: disp)
                self.state = .connected
            } catch {
                self.state = .failed("\(error.localizedDescription)")
            }
        }
    }

    /// Close the display BEFORE suspending (which kills Xvfb) to avoid an XIO abort.
    func teardown() async {
        if torn { return }
        torn = true
        x11?.close(); x11 = nil
        clipboard.stop()
        await session.suspend()
    }
}

import SwiftUI
import X2GoEngine
import X2GoProtocol
import X2GoSSH
import X2GoDisplay

/// Owns one live connection: drives the engine to `connected`, then bridges the
/// engine's local Xvfb display into an X11Session for the Metal view, and polls
/// tunnel byte stats for the title/dashboard.
@MainActor
@Observable
final class ConnectionViewModel: Identifiable {
    enum UIState: Equatable {
        case connecting(String)
        case connected
        case failed(String)

        var label: String {
            switch self {
            case .connecting(let m): return m
            case .connected: return "Connected"
            case .failed(let m): return "Failed: \(m)"
            }
        }
        var isConnected: Bool { if case .connected = self { return true }; return false }
        var isFailed: Bool { if case .failed = self { return true }; return false }
    }

    struct Stats: Equatable { var totalBytes = 0; var bytesPerSec = 0.0 }

    let id: UUID                 // == the profile id (one connection per profile)
    let title: String
    let qualityLabel: String     // e.g. "lan·q9" — the NX speed/quality in use
    var state: UIState = .connecting("starting…")
    var renderer: MetalRenderer?
    private(set) var x11: X11Session?
    private(set) var sessionSize = CGSize(width: 1280, height: 800)
    private(set) var displayName: String?
    var stats = Stats()
    let zoom = ZoomControl()
    let wantFullscreen: Bool

    private let session: X2GoSession
    private var torn = false
    private var statsTask: Task<Void, Never>?

    init(profileID: UUID, config: X2GoSession.Config, title: String, qualityLabel: String) {
        self.id = profileID
        self.session = X2GoSession(config: config)
        self.title = title
        self.qualityLabel = qualityLabel
        self.wantFullscreen = (config.displayMode == .fullscreen)
    }

    /// Title shown in the connection window: name + quality + live transfer stats.
    var windowTitle: String {
        guard state.isConnected else { return "\(title) — \(qualityLabel)" }
        return "\(title) — \(qualityLabel) — \(Self.fmtBytes(stats.totalBytes)) · \(Self.fmtRate(stats.bytesPerSec))"
    }

    /// Short status line for the dashboard card.
    var dashboardStatus: String {
        switch state {
        case .connecting: return "Connecting…"
        case .failed(let m): return "Failed: \(m)"
        case .connected:
            return "\(qualityLabel) · \(Self.fmtRate(stats.bytesPerSec)) · \(Self.fmtBytes(stats.totalBytes))"
        }
    }

    func connect() {
        guard case .connecting = state else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                self.state = .connecting("connecting…")
                self.renderer = MetalRenderer()    // off the click; behind the spinner
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
                self.displayName = disp
                self.sessionSize = CGSize(width: x.width, height: x.height)
                self.state = .connected
                self.startStatsLoop()
            } catch {
                self.state = .failed(error.localizedDescription)
            }
        }
    }

    private func startStatsLoop() {
        statsTask?.cancel()
        statsTask = Task { [weak self] in
            var last = 0
            var lastTime = DispatchTime.now()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self else { return }
                let total = await self.session.transferredBytes()
                let now = DispatchTime.now()
                let dt = Double(now.uptimeNanoseconds - lastTime.uptimeNanoseconds) / 1e9
                let rate = dt > 0 ? Double(total - last) / dt : 0
                self.stats = Stats(totalBytes: total, bytesPerSec: max(0, rate))
                last = total; lastTime = now
            }
        }
    }

    /// Close the display BEFORE suspending (which kills Xvfb) to avoid an XIO abort.
    func teardown() async {
        if torn { return }
        torn = true
        statsTask?.cancel(); statsTask = nil
        x11?.close(); x11 = nil
        await session.suspend()
    }

    // MARK: - Formatting

    static func fmtBytes(_ n: Int) -> String {
        let u = ["B", "KB", "MB", "GB"]; var v = Double(n); var i = 0
        while v >= 1024 && i < u.count - 1 { v /= 1024; i += 1 }
        return String(format: i == 0 ? "%.0f %@" : "%.1f %@", v, u[i])
    }
    static func fmtRate(_ bps: Double) -> String {
        let u = ["B/s", "KB/s", "MB/s"]; var v = bps; var i = 0
        while v >= 1024 && i < u.count - 1 { v /= 1024; i += 1 }
        return String(format: i == 0 ? "%.0f %@" : "%.1f %@", v, u[i])
    }
}

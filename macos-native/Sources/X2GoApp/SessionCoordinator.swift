import Foundation
import SwiftUI
import AppKit
import X2GoProtocol
import X2GoSSH
import X2GoEngine
import X2GoDisplay

/// Owns all live connections (one per window) and the single, focus-following
/// clipboard bridge. Building one ConnectionViewModel per profile is what makes
/// the app multi-session.
@MainActor
@Observable
final class SessionCoordinator {
    private(set) var connections: [UUID: ConnectionViewModel] = [:]
    var focusedID: UUID?

    private let tools = AppTools.resolve()
    private let clipboard = ClipboardBridge()
    private var clipboardOwner: UUID?

    /// Start a connection for a profile; returns its id (the window value).
    func connect(profile: SessionProfile, credentials: [SSHCredential]) -> UUID {
        let config = profile.makeConfig(screen: Self.screenGeometry(), tools: tools, credentials: credentials)
        let vm = ConnectionViewModel(config: config, title: profile.name)
        connections[vm.id] = vm
        vm.connect()
        return vm.id
    }

    func connection(for id: UUID) -> ConnectionViewModel? { connections[id] }

    func close(_ id: UUID) async {
        guard let vm = connections[id] else { return }
        if clipboardOwner == id { clipboard.stop(); clipboardOwner = nil }
        if focusedID == id { focusedID = nil }
        connections[id] = nil
        await vm.teardown()
    }

    func closeAll() async {
        clipboard.stop(); clipboardOwner = nil
        let vms = Array(connections.values)
        connections = [:]
        for vm in vms { await vm.teardown() }
    }

    /// Point the single clipboard bridge at whichever connection is focused.
    func focus(_ id: UUID) {
        focusedID = id
        guard let vm = connections[id], let disp = vm.displayName else { return }
        if clipboardOwner != id {
            clipboard.stop()
            clipboard.start(display: disp)
            clipboardOwner = id
        }
    }

    static func screenGeometry() -> Geometry {
        let size = NSScreen.main?.frame.size ?? CGSize(width: 1280, height: 800)
        return Geometry(width: Int(size.width), height: Int(size.height))
    }
}

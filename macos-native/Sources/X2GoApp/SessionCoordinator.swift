import Foundation
import SwiftUI
import AppKit
import X2GoProtocol
import X2GoSSH
import X2GoEngine
import X2GoDisplay

/// Owns all live connections — keyed by PROFILE id so there is at most one live
/// session per profile — plus the single, focus-following clipboard bridge.
@MainActor
@Observable
final class SessionCoordinator {
    private(set) var connections: [UUID: ConnectionViewModel] = [:]   // profileID -> vm
    var focusedID: UUID?
    /// Set when a connection is ready and its window should be opened/raised.
    var windowToOpen: UUID?

    private let tools = AppTools.resolve()
    private let clipboard = ClipboardBridge()
    private var clipboardOwner: UUID?

    func isActive(_ profileID: UUID) -> Bool { connections[profileID] != nil }
    func connection(for profileID: UUID) -> ConnectionViewModel? { connections[profileID] }
    func connection(forWindow windowID: UUID) -> ConnectionViewModel? {
        connections.values.first { $0.windowID == windowID }
    }

    /// Start a connection for a profile if one isn't already live. Idempotent:
    /// the window value is the profile id, so opening it again just brings the
    /// existing window to the front.
    func connectIfNeeded(profile: SessionProfile, credentials: [SSHCredential],
                         rememberedPassword: Bool = false) {
        guard connections[profile.id] == nil else { return }
        var config = profile.makeConfig(screen: Self.screenGeometry(), tools: tools, credentials: credentials)
        // The Xvfb keymap must match what the user types on, or ä/ö/ü/ß etc. have
        // no keycode and don't type. Always follow the live macOS layout.
        config.keyboardLayout = AppKeyboard.macLayout()
        let quality = "\(profile.speed.rawValue)·q\(profile.quality)"
        let vm = ConnectionViewModel(profileID: profile.id, config: config, title: profile.name,
                                     qualityLabel: quality)
        vm.onReady = { [weak self] id in self?.windowToOpen = id }
        if rememberedPassword {
            // If the remembered password is rejected, forget it so the next connect prompts.
            vm.onFailure = { msg in
                let m = msg.lowercased()
                if m.contains("denied") || m.contains("password") || m.contains("auth") {
                    KeychainStore.deletePassword(for: profile)
                }
            }
        }
        connections[profile.id] = vm
        vm.connect()
    }

    func close(_ profileID: UUID, mode: ConnectionViewModel.CloseMode = .suspend) async {
        guard let vm = connections[profileID] else { return }
        if clipboardOwner == profileID { clipboard.stop(); clipboardOwner = nil }
        if focusedID == profileID { focusedID = nil }
        connections[profileID] = nil
        await vm.teardown(mode)
    }

    func closeAll() async {
        clipboard.stop(); clipboardOwner = nil
        let vms = Array(connections.values)
        connections = [:]
        for vm in vms { await vm.teardown() }
    }

    /// Point the single clipboard bridge at whichever connection is focused.
    func focus(_ profileID: UUID) {
        focusedID = profileID
        guard let vm = connections[profileID], let disp = vm.displayName else { return }
        if clipboardOwner != profileID {
            clipboard.stop()
            clipboard.start(display: disp)
            clipboardOwner = profileID
        }
    }

    static func screenGeometry() -> Geometry {
        let size = NSScreen.main?.frame.size ?? CGSize(width: 1280, height: 800)
        return Geometry(width: Int(size.width), height: Int(size.height))
    }
}

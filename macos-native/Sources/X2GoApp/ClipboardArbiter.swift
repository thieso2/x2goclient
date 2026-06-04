import AppKit

/// Routes the single clipboard bridge to whichever connection window is key, so
/// copy/paste follows focus and multiple sessions never fight over the global
/// pasteboard.
@MainActor
final class ClipboardArbiter: NSObject {
    static let shared = ClipboardArbiter()
    private var windowToConnection: [ObjectIdentifier: UUID] = [:]
    private weak var coordinator: SessionCoordinator?
    private var observing = false

    func configure(_ coordinator: SessionCoordinator) {
        self.coordinator = coordinator
        if !observing {
            observing = true
            NotificationCenter.default.addObserver(
                self, selector: #selector(windowBecameKey(_:)),
                name: NSWindow.didBecomeKeyNotification, object: nil)
        }
    }

    func register(window: NSWindow, connection id: UUID) {
        windowToConnection[ObjectIdentifier(window)] = id
        if window.isKeyWindow { coordinator?.focus(id) }
    }

    @objc private func windowBecameKey(_ note: Notification) {
        guard let w = note.object as? NSWindow,
              let id = windowToConnection[ObjectIdentifier(w)] else { return }
        coordinator?.focus(id)
    }
}

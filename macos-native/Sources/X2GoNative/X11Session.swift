import Foundation
import CX11

/// Bridges to the X display that nxproxy renders the X2Go session onto.
/// Owns a background capture loop filling a BGRA buffer, and forwards input via
/// XTEST. This is the single seam to replace with a native NX decoder later.
final class X11Session: @unchecked Sendable {
    private var dpy: OpaquePointer?
    private(set) var window: UInt64 = 0
    private(set) var width = 0
    private(set) var height = 0

    private var buffer: UnsafeMutablePointer<UInt8>?
    private let lock = NSLock()
    private var running = false
    private var thread: Thread?

    /// Connect, locate the X2GO session window. `displayName` e.g. ":0".
    /// `windowPrefix` defaults to "X2GO-".
    func connect(displayName: String?, windowPrefix: String = "X2GO-") -> Bool {
        dpy = displayName?.withCString { cx11_open($0) } ?? cx11_open(nil)
        guard dpy != nil else { return false }

        // The session window may take a moment after launch; poll briefly.
        for _ in 0..<40 {
            let w = cx11_find_window(dpy, windowPrefix)
            if w != 0 {
                window = w
                var ww: Int32 = 0, hh: Int32 = 0
                if cx11_window_size(dpy, w, &ww, &hh) == 1, ww > 0, hh > 0 {
                    width = Int(ww); height = Int(hh)
                    buffer = .allocate(capacity: width * height * 4)
                    buffer?.initialize(repeating: 0, count: width * height * 4)
                    return true
                }
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return false
    }

    func start() {
        guard !running, dpy != nil, window != 0 else { return }
        running = true
        let t = Thread { [weak self] in self?.captureLoop() }
        t.name = "x2go.capture"
        t.stackSize = 1 << 20
        thread = t
        t.start()
    }

    func stop() { running = false }

    private func captureLoop() {
        guard let buf = buffer else { return }
        let interval: TimeInterval = 1.0 / 30.0
        while running {
            lock.lock()
            _ = cx11_capture_bgra(dpy, window, Int32(width), Int32(height), buf)
            lock.unlock()
            Thread.sleep(forTimeInterval: interval)
        }
    }

    /// Hand the latest frame to a consumer under lock (for Metal upload).
    func withFrame(_ body: (UnsafeRawPointer, Int, Int) -> Void) {
        guard let buf = buffer, width > 0, height > 0 else { return }
        lock.lock()
        body(UnsafeRawPointer(buf), width, height)
        lock.unlock()
    }

    // MARK: - Input (view coords are top-left, in *pixels* of the session)

    /// Map a session-pixel coordinate to root and inject pointer motion.
    func moveMouse(toSessionX x: Int, y: Int) {
        guard dpy != nil, window != 0 else { return }
        var rx: Int32 = 0, ry: Int32 = 0
        guard cx11_window_root_origin(dpy, window, &rx, &ry) == 1 else { return }
        cx11_motion(dpy, rx + Int32(x), ry + Int32(y))
    }

    func mouseButton(_ button: Int, press: Bool) {
        guard dpy != nil else { return }
        cx11_button(dpy, Int32(button), press ? 1 : 0)
    }

    func scroll(up: Bool, amount: Int) {
        guard dpy != nil else { return }
        cx11_scroll(dpy, up ? 1 : 0, Int32(max(1, amount)))
    }

    func key(keysym: UInt32, press: Bool) {
        guard dpy != nil else { return }
        cx11_key_sym(dpy, keysym, press ? 1 : 0)
    }

    func flush() { if dpy != nil { cx11_flush(dpy) } }

    deinit {
        stop()
        buffer?.deallocate()
        if dpy != nil { cx11_close(dpy) }
    }
}

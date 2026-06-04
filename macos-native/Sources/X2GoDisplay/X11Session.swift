import Foundation
import CX11

/// Bridges to the X display that nxproxy renders the X2Go session onto.
/// Owns a background capture loop filling a BGRA buffer, and forwards input via
/// XTEST. This is the single seam to replace with a native NX decoder later.
public final class X11Session: @unchecked Sendable {
    private var dpy: OpaquePointer?
    public private(set) var window: UInt64 = 0
    public private(set) var width = 0
    public private(set) var height = 0

    private var buffer: UnsafeMutablePointer<UInt8>?
    private let lock = NSLock()
    private var running = false
    private var thread: Thread?
    private let stopped = DispatchSemaphore(value: 0)
    /// A second X connection used only for XFIXES cursor polling (from the main
    /// thread), so it never races the capture thread's connection.
    private var cursorDpy: OpaquePointer?

    public init() {}

    /// The remote pointer cursor sprite (RGBA8, premultiplied) + hotspot, with a
    /// serial that changes when the shape changes. The framebuffer capture does
    /// not include the cursor, so the view uses this to set the native NSCursor.
    public struct CursorFrame: Sendable {
        public let rgba: [UInt8]
        public let width: Int
        public let height: Int
        public let xhot: Int
        public let yhot: Int
        public let serial: UInt
    }

    /// Fetch the current cursor sprite (call from the main thread).
    public func currentCursor() -> CursorFrame? {
        guard let cd = cursorDpy else { return nil }
        var w: Int32 = 0, h: Int32 = 0, xh: Int32 = 0, yh: Int32 = 0
        var serial: UInt = 0
        let cap = 256 * 256 * 4
        var buf = [UInt8](repeating: 0, count: cap)
        let ok = buf.withUnsafeMutableBufferPointer { p in
            cx11_cursor_fetch(cd, &w, &h, &xh, &yh, &serial, p.baseAddress, Int32(cap))
        }
        guard ok == 1, w > 0, h > 0 else { return nil }
        let n = Int(w) * Int(h) * 4
        return CursorFrame(rgba: Array(buf[0..<n]), width: Int(w), height: Int(h),
                           xhot: Int(xh), yhot: Int(yh), serial: serial)
    }

    /// Connect, locate the X2GO session window. `displayName` e.g. ":0".
    /// `windowPrefix` defaults to "X2GO-".
    public func connect(displayName: String?, windowPrefix: String = "") -> Bool {
        dpy = displayName?.withCString { cx11_open($0) } ?? cx11_open(nil)
        guard dpy != nil else { return false }
        // Separate connection for cursor polling (main thread).
        cursorDpy = displayName?.withCString { cx11_open($0) } ?? cx11_open(nil)

        // Empty prefix → capture the whole root: our private Xvfb display where
        // the entire X2Go session renders. Otherwise locate a named window.
        if windowPrefix.isEmpty {
            // Poll until the screen is up and has been drawn into.
            for _ in 0..<60 {
                let root = cx11_root_window(dpy)
                var ww: Int32 = 0, hh: Int32 = 0
                if root != 0, cx11_screen_size(dpy, &ww, &hh) == 1, ww > 0, hh > 0 {
                    window = root; width = Int(ww); height = Int(hh)
                    cx11_set_target(dpy, root)
                    buffer = .allocate(capacity: width * height * 4)
                    buffer?.initialize(repeating: 0, count: width * height * 4)
                    return true
                }
                Thread.sleep(forTimeInterval: 0.3)
            }
            return false
        }

        // The session window may take a moment after launch; poll briefly.
        for _ in 0..<40 {
            let w = cx11_find_window(dpy, windowPrefix)
            if w != 0 {
                window = w
                var ww: Int32 = 0, hh: Int32 = 0
                if cx11_window_size(dpy, w, &ww, &hh) == 1, ww > 0, hh > 0 {
                    width = Int(ww); height = Int(hh)
                    cx11_set_target(dpy, w)
                    buffer = .allocate(capacity: width * height * 4)
                    buffer?.initialize(repeating: 0, count: width * height * 4)
                    return true
                }
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return false
    }

    public func start() {
        guard !running, dpy != nil, window != 0 else { return }
        running = true
        let t = Thread { [weak self] in self?.captureLoop() }
        t.name = "x2go.capture"
        t.stackSize = 1 << 20
        thread = t
        t.start()
    }

    /// Stop the capture loop and wait until it has actually exited, so no Xlib
    /// call races a torn-down Xvfb (which would trigger an XIO fatal abort).
    public func stop() {
        guard running else { return }
        running = false
        _ = stopped.wait(timeout: .now() + 1.0)
    }

    private func captureLoop() {
        defer { stopped.signal() }
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
    public func withFrame(_ body: (UnsafeRawPointer, Int, Int) -> Void) {
        guard let buf = buffer, width > 0, height > 0 else { return }
        lock.lock()
        body(UnsafeRawPointer(buf), width, height)
        lock.unlock()
    }

    // MARK: - Input (view coords are top-left, in *pixels* of the session)

    /// Inject pointer motion to a session-pixel (window-relative) coordinate.
    public func moveMouse(toSessionX x: Int, y: Int) {
        guard dpy != nil, window != 0 else { return }
        cx11_motion(dpy, Int32(x), Int32(y))
    }

    public func mouseButton(_ button: Int, press: Bool) {
        guard dpy != nil else { return }
        cx11_button(dpy, Int32(button), press ? 1 : 0)
    }

    public func scroll(up: Bool, amount: Int) {
        guard dpy != nil else { return }
        cx11_scroll(dpy, up ? 1 : 0, Int32(max(1, amount)))
    }

    public func key(keysym: UInt32, press: Bool) {
        guard dpy != nil else { return }
        cx11_key_sym(dpy, keysym, press ? 1 : 0)
    }

    public func flush() { if dpy != nil { cx11_flush(dpy) } }

    /// Stop capturing and close the X connection. Call this BEFORE the Xvfb it
    /// talks to is killed, otherwise Xlib raises an XIO fatal error. Idempotent.
    public func close() {
        stop()
        lock.lock()
        if dpy != nil { cx11_close(dpy); dpy = nil }
        if cursorDpy != nil { cx11_close(cursorDpy); cursorDpy = nil }
        buffer?.deallocate(); buffer = nil
        window = 0
        lock.unlock()
    }

    deinit { close() }
}

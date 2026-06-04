import Foundation
import AppKit
import CX11

/// Bidirectional clipboard sync between the macOS pasteboard and the X CLIPBOARD
/// selection on the (Xvfb) display. Runs ONE background thread that:
///  - serves X paste requests with the latest macOS text (mac → X), and
///  - mirrors X copies onto the macOS pasteboard (X → mac).
/// A single `lastText` guards against ping-pong loops.
///
/// Concurrency: NSPasteboard is NOT thread-safe. Two loop threads (or a loop
/// thread racing a main-thread write) corrupt its internal type cache and crash
/// in __NSFastEnumerationMutationHandler. So there is at most one loop thread —
/// `stop()` waits for it to exit before returning, `start()` stops first, and ALL
/// NSPasteboard access happens on that single thread.
public final class ClipboardBridge: @unchecked Sendable {
    private var clip: OpaquePointer?
    private var thread: Thread?
    private var running = false
    private var finished: DispatchSemaphore?
    private var lastText = ""
    private var lastMacCount = 0

    public init() {}

    public func start(display: String?) {
        stop()                                   // tear down any previous loop first
        clip = display?.withCString { cx11_clip_open($0) } ?? cx11_clip_open(nil)
        guard clip != nil else { return }
        lastMacCount = NSPasteboard.general.changeCount
        lastText = ""
        running = true
        let done = DispatchSemaphore(value: 0)
        finished = done
        let t = Thread { [weak self] in self?.loop(); done.signal() }
        t.name = "x2go.clipboard"; t.stackSize = 1 << 20
        thread = t; t.start()
    }

    /// Stop the loop and WAIT for its thread to fully exit before returning, so we
    /// never run two clipboard loops at once.
    public func stop() {
        running = false
        finished?.wait()
        finished = nil
        thread = nil
        if clip != nil { cx11_clip_close(clip); clip = nil }
    }

    private func loop() {
        while running {
            cx11_clip_pump(clip, 50)   // serve pending X paste requests (also paces the loop)

            // mac → X: macOS pasteboard changed → own X CLIPBOARD with its text.
            let pb = NSPasteboard.general
            if pb.changeCount != lastMacCount {
                lastMacCount = pb.changeCount
                if let s = pb.string(forType: .string), s != lastText {
                    lastText = s
                    s.withCString { cx11_clip_set_text(clip, $0) }
                }
            }

            // X → mac: X CLIPBOARD changed → push onto the macOS pasteboard. Done on
            // THIS thread (not main) so all NSPasteboard access stays single-threaded.
            if let cptr = cx11_clip_get_text(clip) {
                let s = String(cString: cptr); free(cptr)
                if !s.isEmpty && s != lastText {
                    lastText = s
                    pb.clearContents()
                    pb.setString(s, forType: .string)
                    lastMacCount = pb.changeCount   // don't re-detect our own write
                }
            }
        }
    }

    deinit { stop() }
}

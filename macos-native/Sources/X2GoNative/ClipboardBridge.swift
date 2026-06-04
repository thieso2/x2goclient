import Foundation
import AppKit
import CX11

/// Bidirectional clipboard sync between the macOS pasteboard and the X CLIPBOARD
/// selection on the (Xvfb) display. Runs a background thread that:
///  - serves X paste requests with the latest macOS text (mac → X), and
///  - mirrors X copies onto the macOS pasteboard (X → mac).
/// A single `lastText` guards against ping-pong loops.
final class ClipboardBridge: @unchecked Sendable {
    private var clip: OpaquePointer?
    private var thread: Thread?
    private var running = false
    private var lastText = ""
    private var lastMacCount = 0

    func start(display: String?) {
        clip = display?.withCString { cx11_clip_open($0) } ?? cx11_clip_open(nil)
        guard clip != nil else { return }
        lastMacCount = NSPasteboard.general.changeCount
        running = true
        let t = Thread { [weak self] in self?.loop() }
        t.name = "x2go.clipboard"; t.stackSize = 1 << 20
        thread = t; t.start()
    }

    func stop() { running = false }

    private func loop() {
        while running {
            cx11_clip_pump(clip, 150)   // serve pending X paste requests

            // mac → X: macOS pasteboard changed → own X CLIPBOARD with its text
            let pb = NSPasteboard.general
            if pb.changeCount != lastMacCount {
                lastMacCount = pb.changeCount
                if let s = pb.string(forType: .string), s != lastText {
                    lastText = s
                    s.withCString { cx11_clip_set_text(clip, $0) }
                }
            }

            // X → mac: X CLIPBOARD changed → push onto the macOS pasteboard
            if let cptr = cx11_clip_get_text(clip) {
                let s = String(cString: cptr); free(cptr)
                if !s.isEmpty && s != lastText {
                    lastText = s
                    let text = s
                    DispatchQueue.main.async {
                        let pb = NSPasteboard.general
                        pb.clearContents()
                        pb.setString(text, forType: .string)
                        self.lastMacCount = pb.changeCount   // don't re-detect our own write
                    }
                }
            }
        }
    }

    deinit {
        stop()
        if clip != nil { cx11_clip_close(clip) }
    }
}

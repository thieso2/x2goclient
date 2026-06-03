import CX11
import Foundation

// Headless validation of the native input bridge: focus the session's terminal
// and type a marker command via the exact CX11 (XTEST) calls RemoteMetalView's
// NSEvent handlers invoke. Success is verified out-of-band by checking that the
// marker file appears on the X2Go server.

let display = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ":0"
let marker = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "/tmp/x2gonativeinputok"

guard let d = display.withCString({ cx11_open($0) }) else {
    FileHandle.standardError.write("cannot open display \(display)\n".data(using: .utf8)!); exit(1)
}
let win = cx11_find_window(d, "X2GO-")
guard win != 0 else {
    FileHandle.standardError.write("no X2GO- window on \(display)\n".data(using: .utf8)!); exit(2)
}

cx11_set_target(d, win)
// Focus the terminal: move+click near its top-left interior (window-relative).
cx11_motion(d, 200, 90)
cx11_button(d, 1, 1); cx11_button(d, 1, 0)
cx11_flush(d)
Thread.sleep(forTimeInterval: 0.4)

func type(_ s: String) {
    for ch in s.unicodeScalars {
        let ks: UInt32 = (ch == "\n") ? 0xFF0D : ch.value   // Return, else ASCII==keysym
        cx11_key_sym(d, ks, 1)
        cx11_key_sym(d, ks, 0)
        Thread.sleep(forTimeInterval: 0.02)
    }
    cx11_flush(d)
}

// All lowercase / digits / space / slash — no shift needed.
type("rm -f \(marker); touch \(marker)\n")
print("typed marker command for \(marker) into window \(win)")
cx11_close(d)

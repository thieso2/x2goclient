import Foundation

/// Detects the current macOS keyboard layout and maps it to an XKB layout code,
/// so the per-session Xvfb keymap matches what the user types on (otherwise keys
/// like ä/ö/ü/ß have no keycode on a US keymap and don't type). Ported from the
/// old launcher.c.
enum AppKeyboard {
    static func macLayout() -> String {
        let pr = Process()
        pr.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        pr.arguments = ["read",
                        NSHomeDirectory() + "/Library/Preferences/com.apple.HIToolbox.plist",
                        "AppleCurrentKeyboardLayoutInputSourceID"]
        let pipe = Pipe()
        pr.standardOutput = pipe
        pr.standardError = FileHandle.nullDevice
        try? pr.run()
        pr.waitUntilExit()
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let map: [(String, String)] = [
            ("German", "de"), ("Swiss", "ch"), ("British", "gb"), ("French", "fr"),
            ("Spanish", "es"), ("Italian", "it"), ("Portuguese", "pt"), ("Dutch", "nl"),
            ("Norwegian", "no"), ("Swedish", "se"), ("Danish", "dk"), ("Finnish", "fi"),
        ]
        for (needle, code) in map where out.contains(needle) { return code }
        return "us"
    }
}

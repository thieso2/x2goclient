import AppKit

/// Minimal NSEvent → X keysym mapping. Printable characters map via their
/// Latin-1 codepoint (== X keysym for ASCII); special keys map by macOS keyCode.
enum KeyMap {
    static let shiftL: UInt32   = 0xFFE1
    static let controlL: UInt32 = 0xFFE3
    static let altL: UInt32     = 0xFFE9

    // macOS virtual keyCodes -> X keysyms for non-printable keys.
    private static let special: [UInt16: UInt32] = [
        0x24: 0xFF0D, // Return
        0x4C: 0xFF8D, // KP_Enter
        0x30: 0xFF09, // Tab
        0x33: 0xFF08, // Delete -> BackSpace
        0x75: 0xFFFF, // Forward Delete
        0x35: 0xFF1B, // Escape
        0x7B: 0xFF51, // Left
        0x7C: 0xFF53, // Right
        0x7E: 0xFF52, // Up
        0x7D: 0xFF54, // Down
        0x73: 0xFF50, // Home
        0x77: 0xFF57, // End
        0x74: 0xFF55, // PageUp
        0x79: 0xFF56, // PageDown
        0x7A: 0xFFBE, // F1
        0x78: 0xFFBF, // F2
        0x63: 0xFFC0, // F3
        0x76: 0xFFC1, // F4
    ]

    static func keysym(for event: NSEvent) -> UInt32? {
        if let s = special[event.keyCode] { return s }
        guard let chars = event.charactersIgnoringModifiers, let c = chars.unicodeScalars.first else {
            return nil
        }
        let v = c.value
        if v == 0x7F { return 0xFF08 }      // DEL -> BackSpace
        if v >= 0x20 && v <= 0xFF { return v } // ASCII / Latin-1 == X keysym
        return nil
    }
}

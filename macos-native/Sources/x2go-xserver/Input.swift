import Foundation

// Input injection: translate macOS NSEvents (forwarded from the Metal window)
// into X11 input events delivered to nxagent, which is an X *client* of our
// server. nxagent receives KeyPress/ButtonPress/MotionNotify on its nested
// top-level window and routes them internally to the session's apps.

// X event state-mask bits
let ShiftMask:   UInt16 = 0x01
let LockMask:    UInt16 = 0x02
let ControlMask: UInt16 = 0x04
let Mod1Mask:    UInt16 = 0x08   // Alt / Option
let Mod4Mask:    UInt16 = 0x40   // Super / Command
let Button1Mask: UInt16 = 0x100
let Button2Mask: UInt16 = 0x200
let Button3Mask: UInt16 = 0x400

// Event-mask bits a window can select to receive input.
let InputSelectMask: UInt32 = 0x1 /*KeyPress*/ | 0x4 /*ButtonPress*/ | 0x40 /*PointerMotion*/

// A US-layout key: (X keycode, macOS virtual keycode, unshifted keysym, shifted keysym).
// X keycodes follow the conventional evdev layout so the reported keymap is
// standard; macOS virtual keycodes map the physical key the user pressed.
private let KEYS: [(xkc: UInt8, mac: UInt16, lo: UInt32, hi: UInt32)] = [
    // letters
    (38,0,0x61,0x41),(56,11,0x62,0x42),(54,8,0x63,0x43),(40,2,0x64,0x44),
    (26,14,0x65,0x45),(41,3,0x66,0x46),(42,5,0x67,0x47),(43,4,0x68,0x48),
    (31,34,0x69,0x49),(44,38,0x6a,0x4a),(45,40,0x6b,0x4b),(46,37,0x6c,0x4c),
    (58,46,0x6d,0x4d),(57,45,0x6e,0x4e),(32,31,0x6f,0x4f),(33,35,0x70,0x50),
    (24,12,0x71,0x51),(27,15,0x72,0x52),(39,1,0x73,0x53),(28,17,0x74,0x54),
    (30,32,0x75,0x55),(55,9,0x76,0x56),(25,13,0x77,0x57),(53,7,0x78,0x58),
    (29,16,0x79,0x59),(52,6,0x7a,0x5a),
    // number row
    (10,18,0x31,0x21),(11,19,0x32,0x40),(12,20,0x33,0x23),(13,21,0x34,0x24),
    (14,23,0x35,0x25),(15,22,0x36,0x5e),(16,26,0x37,0x26),(17,28,0x38,0x2a),
    (18,25,0x39,0x28),(19,29,0x30,0x29),
    // symbols
    (20,27,0x2d,0x5f),(21,24,0x3d,0x2b),(34,33,0x5b,0x7b),(35,30,0x5d,0x7d),
    (51,42,0x5c,0x7c),(47,41,0x3b,0x3a),(48,39,0x27,0x22),(49,50,0x60,0x7e),
    (59,43,0x2c,0x3c),(60,47,0x2e,0x3e),(61,44,0x2f,0x3f),
    // whitespace / editing
    (65,49,0x20,0x20),(36,36,0xff0d,0xff0d),(23,48,0xff09,0xff09),
    (22,51,0xff08,0xff08),(9,53,0xff1b,0xff1b),(119,117,0xffff,0xffff),
    // arrows + navigation
    (113,123,0xff51,0xff51),(114,124,0xff53,0xff53),(111,126,0xff52,0xff52),
    (116,125,0xff54,0xff54),(110,115,0xff50,0xff50),(115,119,0xff57,0xff57),
    (112,116,0xff55,0xff55),(117,121,0xff56,0xff56),
    // function keys
    (67,122,0xffbe,0xffbe),(68,120,0xffbf,0xffbf),(69,99,0xffc0,0xffc0),
    (70,118,0xffc1,0xffc1),(71,96,0xffc2,0xffc2),(72,97,0xffc3,0xffc3),
    (73,98,0xffc4,0xffc4),(74,100,0xffc5,0xffc5),(75,101,0xffc6,0xffc6),
    (76,109,0xffc7,0xffc7),(95,103,0xffc8,0xffc8),(96,111,0xffc9,0xffc9),
    // modifiers
    (50,56,0xffe1,0xffe1),(62,60,0xffe2,0xffe2),(37,59,0xffe3,0xffe3),
    (64,58,0xffe9,0xffe9),(133,55,0xffeb,0xffeb),(66,57,0xffe5,0xffe5),
]

// X keycode -> (lo, hi) keysyms, for GetKeyboardMapping.
nonisolated(unsafe) let keysymsByKeycode: [UInt8: (UInt32, UInt32)] = {
    var m = [UInt8: (UInt32, UInt32)](); for k in KEYS { m[k.xkc] = (k.lo, k.hi) }; return m
}()
// macOS virtual keycode -> X keycode.
nonisolated(unsafe) let macToXKeycode: [UInt16: UInt8] = {
    var m = [UInt16: UInt8](); for k in KEYS { m[k.mac] = k.xkc }; return m
}()

let MIN_KEYCODE: UInt8 = 8
let KEYSYMS_PER_KEYCODE = 2

/// GetKeyboardMapping reply payload (keysyms-per-keycode = 2 for [lo, hi]).
func keyboardMappingBytes(first: UInt8, count: Int, lsb: Bool) -> [UInt8] {
    var p = ByteWriter(lsb: lsb)
    for i in 0..<count {
        let kc = UInt8(truncatingIfNeeded: Int(first) + i)
        let (lo, hi) = keysymsByKeycode[kc] ?? (0, 0)
        p.u32(lo); p.u32(hi)
    }
    return p.bytes
}

/// GetModifierMapping reply payload (keycodes-per-modifier = 2).
/// Row order: Shift, Lock, Control, Mod1, Mod2, Mod3, Mod4, Mod5.
func modifierMappingBytes() -> [UInt8] {
    let rows: [[UInt8]] = [
        [50, 62],   // Shift   (Shift_L, Shift_R)
        [66, 0],    // Lock    (Caps_Lock)
        [37, 105],  // Control (Control_L, Control_R)
        [64, 108],  // Mod1    (Alt_L, Alt_R)
        [0, 0],     // Mod2
        [0, 0],     // Mod3
        [133, 0],   // Mod4    (Super_L / Command)
        [0, 0],     // Mod5
    ]
    return rows.flatMap { $0 }
}

// MARK: - live input state + the connection events go to

nonisolated(unsafe) var inputFd: Int32 = -1
nonisolated(unsafe) var inputLsb = true
nonisolated(unsafe) var inputWin: UInt32 = 0
nonisolated(unsafe) var inputWinArea = -1
nonisolated(unsafe) var ptrX = 0, ptrY = 0
nonisolated(unsafe) var modState: UInt16 = 0
nonisolated(unsafe) var btnState: UInt16 = 0
nonisolated(unsafe) var evTime: UInt32 = 1
let inputLock = NSLock()

/// Called from the request loop: remember the largest window that selects input
/// on the busiest connection — that is nxagent's nested input window.
func noteInputWindow(_ fd: Int32, _ lsb: Bool, _ wid: UInt32, _ mask: UInt32, _ area: Int) {
    guard (mask & InputSelectMask) != 0 else { return }
    inputLock.lock(); defer { inputLock.unlock() }
    if area >= inputWinArea {
        inputWinArea = area; inputWin = wid; inputFd = fd; inputLsb = lsb
    }
}

/// A pointer/keyboard grab is authoritative about where input goes (e.g. an
/// open menu grabs); use the grab window as the input target.
func setInputTarget(_ fd: Int32, _ lsb: Bool, _ wid: UInt32) {
    guard wid != 0 else { return }
    inputLock.lock(); inputFd = fd; inputLsb = lsb; inputWin = wid; inputLock.unlock()
}

private func sendInputEvent(_ code: UInt8, _ detail: UInt8, _ state: UInt16) {
    inputLock.lock()
    let fd = inputFd, lsb = inputLsb, win = inputWin
    let x = max(0, min(FB_W - 1, ptrX)), y = max(0, min(FB_H - 1, ptrY))
    evTime = evTime &+ 8
    let t = evTime
    inputLock.unlock()
    guard fd >= 0, win != 0 else { return }
    dlog("EVT code=\(code) detail=\(detail) at(\(x),\(y)) state=0x\(String(state, radix:16)) -> fd=\(fd) win=\(win)")
    var w = ByteWriter(lsb: lsb)
    w.u8(code); w.u8(detail); w.u16(curSeq(fd))
    w.u32(t)                          // time
    w.u32(ROOT)                       // root
    w.u32(win)                        // event window
    w.u32(0)                          // child = None
    w.u16(UInt16(x)); w.u16(UInt16(y))   // root-x, root-y
    w.u16(UInt16(x)); w.u16(UInt16(y))   // event-x, event-y
    w.u16(state)                      // key/button state
    w.u8(1)                           // same-screen
    w.u8(0)                           // unused
    enqueue(fd, w.bytes)
}

// MARK: - hooks called from the Metal window (AppKit main thread)

func injectMotion(_ fx: Int, _ fy: Int) {
    inputLock.lock(); ptrX = fx; ptrY = fy; let s = modState | btnState; inputLock.unlock()
    sendInputEvent(6 /*MotionNotify*/, 0, s)
}

func injectButton(_ button: UInt8, down: Bool, fx: Int, fy: Int) {
    let mask: UInt16 = button == 1 ? Button1Mask : button == 2 ? Button2Mask : button == 3 ? Button3Mask : 0
    // Always move the pointer to the click first: a lone ButtonPress does not
    // reposition nxagent's sprite, so the click would land at the last (often
    // 0,0) position. A preceding MotionNotify fixes "clicks do nothing".
    inputLock.lock(); ptrX = fx; ptrY = fy; let s0 = modState | btnState; inputLock.unlock()
    sendInputEvent(6 /*MotionNotify*/, 0, s0)
    inputLock.lock()
    let before = modState | btnState
    if down { btnState |= mask } else { btnState &= ~mask }
    inputLock.unlock()
    sendInputEvent(down ? 4 /*ButtonPress*/ : 5 /*ButtonRelease*/, button, before)
}

/// Scroll wheel = button 4 (up) / 5 (down), a press+release pair.
func injectScroll(up: Bool, fx: Int, fy: Int) {
    let b: UInt8 = up ? 4 : 5
    inputLock.lock(); ptrX = fx; ptrY = fy; let s = modState | btnState; inputLock.unlock()
    sendInputEvent(4, b, s); sendInputEvent(5, b, s)
}

func injectKey(macKeyCode: UInt16, down: Bool) {
    guard let xkc = macToXKeycode[macKeyCode] else { return }
    inputLock.lock(); let s = modState | btnState; inputLock.unlock()
    sendInputEvent(down ? 2 /*KeyPress*/ : 3 /*KeyRelease*/, xkc, s)
}

/// flagsChanged: diff modifier flags, emit modifier key events, update state.
func injectModifierFlags(shift: Bool, control: Bool, option: Bool, command: Bool, caps: Bool) {
    func upd(_ active: Bool, _ bit: UInt16, _ xkc: UInt8) {
        inputLock.lock(); let was = (modState & bit) != 0; inputLock.unlock()
        if active == was { return }
        inputLock.lock(); if active { modState |= bit } else { modState &= ~bit }; inputLock.unlock()
        sendInputEvent(active ? 2 : 3, xkc, 0)
    }
    upd(shift,   ShiftMask,   50)
    upd(control, ControlMask, 37)
    upd(option,  Mod1Mask,    64)
    upd(command, Mod4Mask,    133)
    upd(caps,    LockMask,    66)
}

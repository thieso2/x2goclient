import AppKit
import QuartzCore
import X2GoDisplay

/// Native NSView backed by a CAMetalLayer. Drives the capture→upload→draw loop
/// and forwards native NSEvent input to the session via XTEST.
final class RemoteMetalView: NSView {
    private let renderer: MetalRenderer
    private let session: X11Session
    private var timer: Timer?
    private var cursorTimer: Timer?
    private var tracking: NSTrackingArea?
    private var remoteCursor: NSCursor?
    private var lastCursorSerial: UInt = .max

    init(renderer: MetalRenderer, session: X11Session) {
        self.renderer = renderer
        self.session = session
        super.init(frame: .init(x: 0, y: 0, width: session.width, height: session.height))
        wantsLayer = true
        let ml = CAMetalLayer()
        ml.device = renderer.device
        ml.pixelFormat = .bgra8Unorm
        ml.framebufferOnly = true
        ml.isOpaque = true
        ml.drawableSize = CGSize(width: session.width, height: session.height)
        layer = ml
        layerContentsRedrawPolicy = .duringViewResize
    }

    required init?(coder: NSCoder) { nil }

    /// Keep the Metal drawable matched to the (possibly scaled) view size in
    /// backing pixels, so the GPU samples the session texture at output res.
    private func syncDrawableSize() {
        guard let ml = layer as? CAMetalLayer else { return }
        let s = window?.backingScaleFactor ?? 2.0
        let px = CGSize(width: max(1, bounds.width * s), height: max(1, bounds.height * s))
        if ml.drawableSize != px { ml.drawableSize = px }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        syncDrawableSize()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            timer?.invalidate(); timer = nil
            cursorTimer?.invalidate(); cursorTimer = nil
            releaseHeldModifiers()
        } else {
            syncDrawableSize()
        }
    }

    override var wantsUpdateLayer: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func startRendering() {
        let t = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.renderFrame() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t

        // Reflect the remote pointer shape (XFIXES) as the native NSCursor.
        let ct = Timer(timeInterval: 1.0 / 12.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollCursor() }
        }
        RunLoop.main.add(ct, forMode: .common)
        cursorTimer = ct
    }

    // MARK: - Remote cursor

    private func pollCursor() {
        guard let c = session.currentCursor(), c.serial != lastCursorSerial else { return }
        lastCursorSerial = c.serial
        remoteCursor = Self.makeCursor(c)
        window?.invalidateCursorRects(for: self)
    }

    override func resetCursorRects() {
        if let rc = remoteCursor { addCursorRect(bounds, cursor: rc) }
        else { super.resetCursorRects() }
    }

    private static func makeCursor(_ c: X11Session.CursorFrame) -> NSCursor? {
        guard c.width > 0, c.height > 0,
              let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: c.width, pixelsHigh: c.height,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: c.width * 4, bitsPerPixel: 32)
        else { return nil }
        if let dst = rep.bitmapData {
            c.rgba.withUnsafeBytes { src in
                if let base = src.baseAddress { memcpy(dst, base, min(c.rgba.count, c.width * c.height * 4)) }
            }
        }
        let img = NSImage(size: NSSize(width: c.width, height: c.height))
        img.addRepresentation(rep)
        return NSCursor(image: img, hotSpot: NSPoint(x: c.xhot, y: c.yhot))
    }

    private func renderFrame() {
        guard let ml = layer as? CAMetalLayer else { return }
        session.withFrame { ptr, w, h in renderer.upload(ptr, width: w, height: h) }
        renderer.draw(in: ml)
    }

    // MARK: - Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds,
                               options: [.activeInKeyWindow, .mouseMoved, .inVisibleRect, .mouseEnteredAndExited],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }

    /// Convert an event location to session pixel coordinates (top-left origin).
    private func sessionPoint(_ event: NSEvent) -> (Int, Int) {
        let p = convert(event.locationInWindow, from: nil)
        let w = max(bounds.width, 1), h = max(bounds.height, 1)
        let sx = Int((p.x / w) * CGFloat(session.width))
        let sy = Int(((h - p.y) / h) * CGFloat(session.height))   // flip Y
        return (max(0, min(session.width - 1, sx)), max(0, min(session.height - 1, sy)))
    }

    private func moveTo(_ event: NSEvent) {
        let (x, y) = sessionPoint(event)
        session.moveMouse(toSessionX: x, y: y)
    }

    override func mouseMoved(with e: NSEvent)    { moveTo(e) }
    override func mouseDragged(with e: NSEvent)  { moveTo(e) }
    override func rightMouseDragged(with e: NSEvent) { moveTo(e) }
    override func otherMouseDragged(with e: NSEvent) { moveTo(e) }

    // X button numbers: 1 = left, 2 = middle, 3 = right.
    // Right is macOS's native secondary click (two-finger / Ctrl / corner).
    // Middle has no trackpad equivalent, so ⌘-click emulates it — Command (unlike
    // Option) isn't forwarded as a keyboard modifier, so it's a clean middle click
    // (Option would send Alt+middle, which WMs bind to window resize).
    private var leftButton = 1   // which X button the current left press maps to

    override func mouseDown(with e: NSEvent) {
        moveTo(e)
        leftButton = e.modifierFlags.contains(.command) ? 2 : 1   // ⌘-click = middle
        session.mouseButton(leftButton, press: true)
    }
    override func mouseUp(with e: NSEvent) {
        moveTo(e)
        session.mouseButton(leftButton, press: false)
        leftButton = 1
    }
    override func rightMouseDown(with e: NSEvent) { moveTo(e); session.mouseButton(3, press: true) }
    override func rightMouseUp(with e: NSEvent)   { moveTo(e); session.mouseButton(3, press: false) }
    override func otherMouseDown(with e: NSEvent) { moveTo(e); session.mouseButton(2, press: true) }
    override func otherMouseUp(with e: NSEvent)   { moveTo(e); session.mouseButton(2, press: false) }

    override func scrollWheel(with e: NSEvent) {
        let dy = e.scrollingDeltaY
        if dy != 0 { session.scroll(up: dy > 0, amount: min(5, max(1, Int(abs(dy) / 4)))) }
    }

    // MARK: - Keyboard
    //
    // Modifiers are tracked by their real transitions (flagsChanged), not pressed
    // and released around each key. Inferring from per-key flags loses the release
    // when a modifier changes between key-down and key-up (or focus leaves
    // mid-press), leaving it stuck down in X — which reads as a stuck Caps Lock.

    private var heldMods: Set<UInt32> = []   // currently-pressed momentary modifiers
    private var capsOn = false               // mirrored Caps Lock state

    override func keyDown(with e: NSEvent) {
        syncModifiers(e.modifierFlags)
        if let ks = KeyMap.keysym(for: e) { session.key(keysym: ks, press: true); session.flush() }
    }

    override func keyUp(with e: NSEvent) {
        if let ks = KeyMap.keysym(for: e) { session.key(keysym: ks, press: false); session.flush() }
    }

    override func flagsChanged(with e: NSEvent) {
        syncModifiers(e.modifierFlags)
        session.flush()
    }

    private func syncModifiers(_ f: NSEvent.ModifierFlags) {
        setMod(KeyMap.shiftL,   down: f.contains(.shift))
        setMod(KeyMap.controlL, down: f.contains(.control))
        setMod(KeyMap.altL,     down: f.contains(.option))
        // Caps Lock is a locking toggle: tap it in X whenever the macOS state flips.
        let caps = f.contains(.capsLock)
        if caps != capsOn {
            capsOn = caps
            session.key(keysym: KeyMap.capsLock, press: true)
            session.key(keysym: KeyMap.capsLock, press: false)
        }
    }

    private func setMod(_ ks: UInt32, down: Bool) {
        if down, !heldMods.contains(ks) { heldMods.insert(ks); session.key(keysym: ks, press: true) }
        else if !down, heldMods.contains(ks) { heldMods.remove(ks); session.key(keysym: ks, press: false) }
    }

    /// Release every held momentary modifier — call when focus leaves so nothing
    /// stays stuck down in the session.
    private func releaseHeldModifiers() {
        guard !heldMods.isEmpty else { return }
        for ks in heldMods { session.key(keysym: ks, press: false) }
        heldMods.removeAll()
        session.flush()
    }

    override func resignFirstResponder() -> Bool {
        releaseHeldModifiers()
        return super.resignFirstResponder()
    }
}

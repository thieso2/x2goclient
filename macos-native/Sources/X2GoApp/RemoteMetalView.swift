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

    override func mouseDown(with e: NSEvent)  { moveTo(e); session.mouseButton(1, press: true) }
    override func mouseUp(with e: NSEvent)    { moveTo(e); session.mouseButton(1, press: false) }
    override func rightMouseDown(with e: NSEvent) { moveTo(e); session.mouseButton(3, press: true) }
    override func rightMouseUp(with e: NSEvent)   { moveTo(e); session.mouseButton(3, press: false) }
    override func otherMouseDown(with e: NSEvent) { moveTo(e); session.mouseButton(2, press: true) }
    override func otherMouseUp(with e: NSEvent)   { moveTo(e); session.mouseButton(2, press: false) }

    override func scrollWheel(with e: NSEvent) {
        let dy = e.scrollingDeltaY
        if dy != 0 { session.scroll(up: dy > 0, amount: min(5, max(1, Int(abs(dy) / 4)))) }
    }

    // MARK: - Keyboard

    override func keyDown(with e: NSEvent) { sendKey(e, press: true) }
    override func keyUp(with e: NSEvent)   { sendKey(e, press: false) }

    private func sendKey(_ e: NSEvent, press: Bool) {
        guard let ks = KeyMap.keysym(for: e) else { return }
        let mods = e.modifierFlags
        if press {
            if mods.contains(.shift)   { session.key(keysym: KeyMap.shiftL, press: true) }
            if mods.contains(.control) { session.key(keysym: KeyMap.controlL, press: true) }
            if mods.contains(.option)  { session.key(keysym: KeyMap.altL, press: true) }
            session.key(keysym: ks, press: true)
        } else {
            session.key(keysym: ks, press: false)
            if mods.contains(.option)  { session.key(keysym: KeyMap.altL, press: false) }
            if mods.contains(.control) { session.key(keysym: KeyMap.controlL, press: false) }
            if mods.contains(.shift)   { session.key(keysym: KeyMap.shiftL, press: false) }
        }
        session.flush()
    }
}

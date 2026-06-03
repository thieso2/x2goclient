import AppKit
import Metal
import QuartzCore

// Presents the composited framebuffer in a native window via Metal. Uses
// CAMetalDisplayLink (macOS 14+) to drive rendering in step with the display,
// and runtime-compiled MSL. The X server composites window surfaces into `fb`;
// this uploads `fb` to a texture and blits it to the drawable each vsync.

private let shaderSrc = """
#include <metal_stdlib>
using namespace metal;
struct VSOut { float4 pos [[position]]; float2 uv; };
vertex VSOut v_main(uint vid [[vertex_id]]) {
    float2 p[4] = { float2(-1,-1), float2(1,-1), float2(-1,1), float2(1,1) };
    float2 t[4] = { float2(0,1),  float2(1,1),  float2(0,0),  float2(1,0) };
    VSOut o; o.pos = float4(p[vid],0,1); o.uv = t[vid]; return o;
}
fragment float4 f_main(VSOut in [[stage_in]], texture2d<float> tex [[texture(0)]], sampler s [[sampler(0)]]) {
    return tex.sample(s, in.uv);
}
"""

/// Off-main-actor renderer driven by the display link.
final class MetalRenderer: NSObject, CAMetalDisplayLinkDelegate, @unchecked Sendable {
    let device: MTLDevice
    let queue: MTLCommandQueue
    let pipeline: MTLRenderPipelineState
    let sampler: MTLSamplerState
    let tex: MTLTexture
    let fb: Framebuffer

    init(device: MTLDevice, fb: Framebuffer) {
        self.device = device
        self.fb = fb
        queue = device.makeCommandQueue()!
        let lib = try! device.makeLibrary(source: shaderSrc, options: nil)
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = lib.makeFunction(name: "v_main")
        d.fragmentFunction = lib.makeFunction(name: "f_main")
        d.colorAttachments[0].pixelFormat = .bgra8Unorm
        pipeline = try! device.makeRenderPipelineState(descriptor: d)
        let sd = MTLSamplerDescriptor(); sd.minFilter = .linear; sd.magFilter = .nearest
        sampler = device.makeSamplerState(descriptor: sd)!
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                    width: fb.w, height: fb.h, mipmapped: false)
        td.usage = [.shaderRead]; td.storageMode = .shared
        tex = device.makeTexture(descriptor: td)!
        super.init()
    }

    func metalDisplayLink(_ link: CAMetalDisplayLink, needsUpdate update: CAMetalDisplayLink.Update) {
        // The compositor thread builds `fb`; we upload it lock-free (tearing is
        // harmless for display) so we never contend with the compositor or the
        // X server's draw threads — that contention made rendering glacial.
        fb.px.withUnsafeBytes { p in
            tex.replace(region: MTLRegionMake2D(0, 0, fb.w, fb.h), mipmapLevel: 0,
                        withBytes: p.baseAddress!, bytesPerRow: fb.w * 4)
        }
        let drawable = update.drawable
        guard let cmd = queue.makeCommandBuffer() else { return }
        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = drawable.texture
        rp.colorAttachments[0].loadAction = .clear
        rp.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
        rp.colorAttachments[0].storeAction = .store
        let enc = cmd.makeRenderCommandEncoder(descriptor: rp)!
        enc.setRenderPipelineState(pipeline)
        enc.setFragmentTexture(tex, index: 0)
        enc.setFragmentSamplerState(sampler, index: 0)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        enc.endEncoding()
        cmd.present(drawable)
        cmd.commit()
    }
}

final class FBView: NSView {
    let fb: Framebuffer
    let renderer: MetalRenderer
    let metalLayer = CAMetalLayer()
    var renderThread: Thread?

    init(fb: Framebuffer) {
        self.fb = fb
        let dev = MTLCreateSystemDefaultDevice()!
        renderer = MetalRenderer(device: dev, fb: fb)
        super.init(frame: NSRect(x: 0, y: 0, width: fb.w, height: fb.h))
        wantsLayer = true
        metalLayer.device = dev
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = true
        metalLayer.drawableSize = CGSize(width: fb.w, height: fb.h)
        layer = metalLayer
    }
    required init?(coder: NSCoder) { nil }

    // MARK: - input forwarding (-> X events to nxagent)

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    static let ilog = ProcessInfo.processInfo.environment["X2GO_INPUTLOG"] != nil
    private func il(_ s: String) {
        guard FBView.ilog else { return }
        FileHandle.standardError.write("NSEVENT \(s)\n".data(using: .utf8)!)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
            options: [.activeAlways, .mouseMoved, .inVisibleRect, .mouseEnteredAndExited],
            owner: self, userInfo: nil))
    }

    /// View point (bottom-left, points) -> framebuffer pixel (top-left).
    private func fbPoint(_ e: NSEvent) -> (Int, Int) {
        let p = convert(e.locationInWindow, from: nil)
        let bw = max(1, bounds.width), bh = max(1, bounds.height)
        let fx = Int((p.x / bw) * CGFloat(fb.w))
        let fy = Int(((bh - p.y) / bh) * CGFloat(fb.h))
        return (max(0, min(fb.w - 1, fx)), max(0, min(fb.h - 1, fy)))
    }

    override func mouseMoved(with e: NSEvent)        { let (x, y) = fbPoint(e); il("mouseMoved -> fb(\(x),\(y))"); injectMotion(x, y) }
    override func mouseDragged(with e: NSEvent)      { let (x, y) = fbPoint(e); injectMotion(x, y) }
    override func rightMouseDragged(with e: NSEvent) { let (x, y) = fbPoint(e); injectMotion(x, y) }
    override func otherMouseDragged(with e: NSEvent) { let (x, y) = fbPoint(e); injectMotion(x, y) }
    override func mouseDown(with e: NSEvent)         { let (x, y) = fbPoint(e); il("mouseDown -> fb(\(x),\(y)) win=\(inputWin) fd=\(inputFd)"); injectButton(1, down: true,  fx: x, fy: y) }
    override func mouseUp(with e: NSEvent)           { let (x, y) = fbPoint(e); injectButton(1, down: false, fx: x, fy: y) }
    override func rightMouseDown(with e: NSEvent)    { let (x, y) = fbPoint(e); injectButton(3, down: true,  fx: x, fy: y) }
    override func rightMouseUp(with e: NSEvent)      { let (x, y) = fbPoint(e); injectButton(3, down: false, fx: x, fy: y) }
    override func otherMouseDown(with e: NSEvent)    { let (x, y) = fbPoint(e); injectButton(2, down: true,  fx: x, fy: y) }
    override func otherMouseUp(with e: NSEvent)      { let (x, y) = fbPoint(e); injectButton(2, down: false, fx: x, fy: y) }
    override func scrollWheel(with e: NSEvent) {
        let (x, y) = fbPoint(e)
        if e.deltaY > 0.1 { injectScroll(up: true, fx: x, fy: y) }
        else if e.deltaY < -0.1 { injectScroll(up: false, fx: x, fy: y) }
    }
    override func keyDown(with e: NSEvent) { il("keyDown code=\(e.keyCode)"); injectKey(macKeyCode: e.keyCode, down: true) }
    override func keyUp(with e: NSEvent)   { injectKey(macKeyCode: e.keyCode, down: false) }
    override func flagsChanged(with e: NSEvent) {
        let f = e.modifierFlags
        injectModifierFlags(shift: f.contains(.shift), control: f.contains(.control),
                            option: f.contains(.option), command: f.contains(.command),
                            caps: f.contains(.capsLock))
    }

    func start() {
        // Drive the display link on a dedicated thread so its per-frame texture
        // upload + present never competes with the main run loop's NSEvent
        // delivery (which would make mouse/keyboard input feel unresponsive).
        let layer = metalLayer, rndr = renderer
        let t = Thread {
            let dl = CAMetalDisplayLink(metalLayer: layer)
            dl.delegate = rndr
            dl.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
            dl.add(to: .current, forMode: .common)
            RunLoop.current.run()
        }
        t.stackSize = 1 << 20
        t.start()
        renderThread = t
    }
}

final class PresenterDelegate: NSObject, NSApplicationDelegate {
    let fb: Framebuffer
    var win: NSWindow?
    init(fb: Framebuffer) { self.fb = fb }
    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.setActivationPolicy(.regular)
        let scale = 0.7
        let w = NSWindow(contentRect: NSRect(x: 100, y: 100, width: Double(fb.w)*scale, height: Double(fb.h)*scale),
                         styleMask: [.titled, .closable, .resizable, .miniaturizable],
                         backing: .buffered, defer: false)
        w.title = "X2Go (native · Metal · X server :77)"
        w.acceptsMouseMovedEvents = true
        let v = FBView(fb: fb)
        w.contentView = v
        w.makeKeyAndOrderFront(nil)
        w.makeFirstResponder(v)
        v.start()
        NSApp.activate(ignoringOtherApps: true)
        win = w
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }
}

func runMetalApp(_ fb: Framebuffer) {
    let app = NSApplication.shared
    let delegate = PresenterDelegate(fb: fb)
    app.delegate = delegate
    app.run()
}

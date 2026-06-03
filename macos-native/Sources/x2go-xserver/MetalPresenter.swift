import AppKit
import Metal
import QuartzCore

// Presents the X server's framebuffer in a native macOS window via Metal —
// the no-XQuartz native display surface. Shaders compiled at runtime.

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

final class FBView: NSView {
    let device = MTLCreateSystemDefaultDevice()!
    var queue: MTLCommandQueue!
    var pipeline: MTLRenderPipelineState!
    var sampler: MTLSamplerState!
    var tex: MTLTexture!
    let fb: Framebuffer
    var timer: Timer?

    init(fb: Framebuffer) {
        self.fb = fb
        super.init(frame: NSRect(x: 0, y: 0, width: fb.w, height: fb.h))
        wantsLayer = true
        let ml = CAMetalLayer()
        ml.device = device
        ml.pixelFormat = .bgra8Unorm
        ml.framebufferOnly = true
        ml.drawableSize = CGSize(width: fb.w, height: fb.h)
        layer = ml

        queue = device.makeCommandQueue()
        let lib = try! device.makeLibrary(source: shaderSrc, options: nil)
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = lib.makeFunction(name: "v_main")
        d.fragmentFunction = lib.makeFunction(name: "f_main")
        d.colorAttachments[0].pixelFormat = .bgra8Unorm
        pipeline = try! device.makeRenderPipelineState(descriptor: d)
        let sd = MTLSamplerDescriptor(); sd.minFilter = .linear; sd.magFilter = .nearest
        sampler = device.makeSamplerState(descriptor: sd)
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: fb.w, height: fb.h, mipmapped: false)
        td.usage = [.shaderRead]; td.storageMode = .managed
        tex = device.makeTexture(descriptor: td)
    }
    required init?(coder: NSCoder) { nil }

    func start() {
        let t = Timer(timeInterval: 1.0/30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.render() }
        }
        RunLoop.main.add(t, forMode: .common); timer = t
    }

    private func render() {
        fb.lock.lock()
        fb.px.withUnsafeBytes { p in
            tex.replace(region: MTLRegionMake2D(0, 0, fb.w, fb.h), mipmapLevel: 0,
                        withBytes: p.baseAddress!, bytesPerRow: fb.w * 4)
        }
        fb.lock.unlock()
        guard let ml = layer as? CAMetalLayer, let drw = ml.nextDrawable(),
              let cmd = queue.makeCommandBuffer() else { return }
        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = drw.texture
        rp.colorAttachments[0].loadAction = .clear
        rp.colorAttachments[0].clearColor = MTLClearColorMake(0,0,0,1)
        rp.colorAttachments[0].storeAction = .store
        let enc = cmd.makeRenderCommandEncoder(descriptor: rp)!
        enc.setRenderPipelineState(pipeline)
        enc.setFragmentTexture(tex, index: 0)
        enc.setFragmentSamplerState(sampler, index: 0)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        enc.endEncoding()
        cmd.present(drw); cmd.commit()
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
        let v = FBView(fb: fb)
        w.contentView = v
        w.makeKeyAndOrderFront(nil)
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

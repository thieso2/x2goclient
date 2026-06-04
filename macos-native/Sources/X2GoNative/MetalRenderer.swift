import Foundation
import Metal
import QuartzCore

/// Presents a BGRA framebuffer as a fullscreen textured quad on a CAMetalLayer.
/// Shaders are compiled at runtime (no offline Metal toolchain required).
final class MetalRenderer {
    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let sampler: MTLSamplerState
    private var texture: MTLTexture?
    private var texW = 0
    private var texH = 0

    static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;
    struct VSOut { float4 pos [[position]]; float2 uv; };
    vertex VSOut v_main(uint vid [[vertex_id]]) {
        float2 p[4] = { float2(-1,-1), float2(1,-1), float2(-1,1), float2(1,1) };
        float2 t[4] = { float2(0,1),  float2(1,1),  float2(0,0),  float2(1,0) };
        VSOut o; o.pos = float4(p[vid], 0, 1); o.uv = t[vid]; return o;
    }
    fragment float4 f_main(VSOut in [[stage_in]], texture2d<float> tex [[texture(0)]], sampler s [[sampler(0)]]) {
        return tex.sample(s, in.uv);
    }
    """

    init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.queue = queue

        do {
            let lib = try device.makeLibrary(source: Self.shaderSource, options: nil)
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = lib.makeFunction(name: "v_main")
            desc.fragmentFunction = lib.makeFunction(name: "f_main")
            desc.colorAttachments[0].pixelFormat = .bgra8Unorm
            self.pipeline = try device.makeRenderPipelineState(descriptor: desc)
        } catch {
            FileHandle.standardError.write("Metal pipeline error: \(error)\n".data(using: .utf8)!)
            return nil
        }

        let sd = MTLSamplerDescriptor()
        sd.minFilter = .linear    // smooth when the desktop is downscaled (fit)
        sd.magFilter = .nearest   // crisp pixels when zoomed in past 1:1
        guard let s = device.makeSamplerState(descriptor: sd) else { return nil }
        self.sampler = s
    }

    /// Ensure the backing texture matches the frame size.
    func ensureTexture(width: Int, height: Int) {
        guard width > 0, height > 0, (width != texW || height != texH) else { return }
        let d = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        d.usage = [.shaderRead]
        d.storageMode = .managed
        texture = device.makeTexture(descriptor: d)
        texW = width; texH = height
    }

    /// Upload a tightly-packed BGRA8 buffer into the texture.
    func upload(_ ptr: UnsafeRawPointer, width: Int, height: Int) {
        ensureTexture(width: width, height: height)
        guard let tex = texture else { return }
        tex.replace(region: MTLRegionMake2D(0, 0, width, height),
                    mipmapLevel: 0, withBytes: ptr, bytesPerRow: width * 4)
    }

    /// Draw the current texture into the layer's next drawable.
    func draw(in layer: CAMetalLayer) {
        guard let tex = texture,
              let drawable = layer.nextDrawable(),
              let cmd = queue.makeCommandBuffer() else { return }
        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = drawable.texture
        rp.colorAttachments[0].loadAction = .clear
        rp.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
        rp.colorAttachments[0].storeAction = .store
        guard let enc = cmd.makeRenderCommandEncoder(descriptor: rp) else { return }
        enc.setRenderPipelineState(pipeline)
        enc.setFragmentTexture(tex, index: 0)
        enc.setFragmentSamplerState(sampler, index: 0)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        enc.endEncoding()
        cmd.present(drawable)
        cmd.commit()
    }
}

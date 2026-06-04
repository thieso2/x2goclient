import AppKit

/// Hosts the RemoteMetalView and implements the viewer's zoom model:
///   - .fit (default, sticky): the whole session is uniformly downscaled to the
///     window; on resize it re-fits automatically. Never upscales past 1:1.
///   - .manual(scale): a fixed zoom; if the scaled content exceeds the window,
///     the (autohiding) scrollbars appear.
/// Aspect ratio is always preserved. The metal view is centered when smaller
/// than the viewport. Input maps correctly because RemoteMetalView reads the
/// click as a fraction of its (scaled) frame, which NSScrollView already offsets
/// for the scroll position.
final class RemoteScrollView: NSScrollView {
    enum ZoomMode { case fit; case manual(CGFloat) }

    let metalView: RemoteMetalView
    private let container = NSView()
    private let sessionSize: NSSize
    private(set) var currentScale: CGFloat = 1
    var mode: ZoomMode = .fit { didSet { reflow() } }

    init(metalView: RemoteMetalView, sessionSize: NSSize) {
        self.metalView = metalView
        self.sessionSize = sessionSize
        super.init(frame: .zero)
        hasHorizontalScroller = true
        hasVerticalScroller = true
        autohidesScrollers = true         // shown only when content overflows
        scrollerStyle = .legacy           // persistent bars (overlay only flashes)
        borderType = .noBorder
        drawsBackground = true
        backgroundColor = .black
        // The content is black, so render the scrollers in the dark theme with a
        // light knob, otherwise the knob is black-on-black and invisible.
        appearance = NSAppearance(named: .darkAqua)
        verticalScroller?.knobStyle = .light
        horizontalScroller?.knobStyle = .light
        container.wantsLayer = true
        container.addSubview(metalView)
        documentView = container
        reflow()
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        reflow()
    }

    // MARK: - Zoom API (driven by the View menu)

    func fit()   { mode = .fit }
    func setManual(_ s: CGFloat) { mode = .manual(max(0.1, min(8, s))) }
    func zoomIn()  { setManual(currentScale * 1.1) }
    func zoomOut() { setManual(currentScale / 1.1) }

    // MARK: - Layout

    private func reflow() {
        let clip = contentView.bounds.size
        guard sessionSize.width > 0, sessionSize.height > 0,
              clip.width > 0, clip.height > 0 else { return }

        var scale: CGFloat
        switch mode {
        case .fit:
            scale = min(clip.width / sessionSize.width,
                        clip.height / sessionSize.height)
            if scale > 1 { scale = 1 }          // fit never upscales
        case .manual(let s):
            scale = s
        }
        currentScale = scale

        let content = NSSize(width: (sessionSize.width * scale).rounded(),
                             height: (sessionSize.height * scale).rounded())
        // The document is at least the viewport so smaller content can center;
        // larger content drives the scrollbars.
        let docSize = NSSize(width: max(content.width, clip.width),
                             height: max(content.height, clip.height))
        if container.frame.size != docSize {
            container.frame = NSRect(origin: .zero, size: docSize)
        }
        let origin = NSPoint(x: ((docSize.width - content.width) / 2).rounded(),
                             y: ((docSize.height - content.height) / 2).rounded())
        let target = NSRect(origin: origin, size: content)
        if metalView.frame != target { metalView.frame = target }
    }
}

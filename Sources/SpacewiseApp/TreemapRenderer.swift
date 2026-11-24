import AppKit
import SpacewiseCore

/// One finished storage-map render: the layout it was computed for and the cushion-shaded bitmap.
struct RenderedMap: Sendable {
    let layout: TreemapLayout
    let image: CGImage
}

/// Layout and raster for the storage map, computed off the main actor. The view only blits the result.
enum TreemapRenderer {
    /// The longest side of the bitmap in pixels; larger maps are rendered at a lower scale and stretched.
    private static let maximumPixels: Double = 6000

    /// Layout + raster for one model at one size, off the main actor. Returns nil if cancelled.
    @concurrent static func render(
        model: TreemapModel, size: CGSize, scale: CGFloat, dark: Bool,
        tileEdges: Bool = false
    ) async -> RenderedMap? {
        guard !Task.isCancelled else { return nil }
        var factor = Double(scale)
        let longest = Double(max(size.width, size.height)) * factor
        if longest > maximumPixels { factor *= maximumPixels / longest }
        let width = max(1, Int((Double(size.width) * factor).rounded()))
        let height = max(1, Int((Double(size.height) * factor).rounded()))
        let layout = TreemapLayout.compute(model, in: CGRect(origin: .zero, size: size))
        guard !Task.isCancelled else { return nil }
        let bytes = width * height * 4
        let memory = UnsafeMutablePointer<UInt8>.allocate(capacity: bytes)
        let finished = TreemapRaster.renderIfNotCancelled(
            model: model, layout: layout, into: UnsafeMutableBufferPointer(start: memory, count: bytes),
            pixelWidth: width, pixelHeight: height, scale: factor,
            options: .init(dark: dark, tileEdges: tileEdges), isCancelled: { Task.isCancelled })
        guard finished else {
            memory.deallocate()
            return nil
        }
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        // The provider owns the rendered memory from here and frees it with the image: no copy of the bitmap.
        guard
            let provider = CGDataProvider(
                dataInfo: nil, data: memory, size: bytes,
                releaseData: { _, data, _ in
                    UnsafeMutableRawPointer(mutating: data).deallocate()
                })
        else {
            memory.deallocate()
            return nil
        }
        guard !Task.isCancelled,
            let image = CGImage(
                width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: bitmapInfo, provider: provider, decode: nil, shouldInterpolate: false,
                intent: .defaultIntent)
        else { return nil }
        return RenderedMap(layout: layout, image: image)
    }
}

extension NSAppearance {
    var isDarkAqua: Bool { bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }
}

extension TreemapPalette.RGB {
    var nsColor: NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: 1) }
}

/// Plays one `TreemapTransition` over the map: the outgoing and incoming bitmaps in two image views whose frames and
/// opacity follow the transition's geometry on the display's refresh. Nothing is rendered per frame; Core Animation
/// scales the existing bitmaps. It never takes a click: events fall through to the map underneath, which already
/// shows the end state, so interaction during a transition lands where it will be when it finishes.
///
/// The view's display link drives the frames. A display link fires only while the window is on screen, so it can
/// stay silent (a window on another Space, occluded, or between displays) without any error; a 60 Hz timer then
/// steps the transition instead, and only while the link has missed more than a frame and a half, so the zoom moves
/// and ends on time either way.
@MainActor final class TreemapTransitionView: NSView {
    private let outgoing = NSImageView()
    private let incoming = NSImageView()
    private var geometry: TreemapTransition.Geometry?
    private var duration = 0.0
    private var began: CFTimeInterval = 0
    private var link: CADisplayLink?
    /// Steps the transition when the display link is not firing.
    private var backup: Timer?
    /// Ends the transition on time even if neither the display link nor the backup timer fires.
    private var deadline: Timer?
    private var completion: (() -> Void)?
    /// When the last frame was shown, in `CACurrentMediaTime` seconds.
    private var lastFrame: CFTimeInterval = 0
    private static let frameInterval: CFTimeInterval = 1.0 / 60

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        for view in [outgoing, incoming] {
            view.imageScaling = .scaleAxesIndependently
            view.imageFrameStyle = .none
            view.isEditable = false
            view.wantsLayer = true
            view.setAccessibilityElement(false)
        }
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Start at the transition's first frame and play it. `outgoing` nil means the map was empty (fade in).
    func run(
        _ kind: TreemapTransition, outgoing old: CGImage?, incoming new: CGImage, backdrop: NSColor,
        completion: @escaping () -> Void
    ) {
        layer?.backgroundColor = backdrop.cgColor
        let geometry = kind.geometry(in: bounds)
        self.geometry = geometry
        duration = kind.duration
        self.completion = completion
        outgoing.image = old.map { NSImage(cgImage: $0, size: bounds.size) }
        outgoing.isHidden = old == nil
        incoming.image = NSImage(cgImage: new, size: bounds.size)
        // The picture that fades is on top.
        addSubview(geometry.incomingOnTop ? outgoing : incoming)
        addSubview(geometry.incomingOnTop ? incoming : outgoing)
        show(progress: 0)
        began = CACurrentMediaTime()
        lastFrame = began
        let link = displayLink(target: self, selector: #selector(step(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
        let backup = Timer(timeInterval: Self.frameInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.backupStep() }
        }
        RunLoop.main.add(backup, forMode: .common)
        self.backup = backup
        let deadline = Timer(timeInterval: duration + 0.05, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.complete() }
        }
        RunLoop.main.add(deadline, forMode: .common)
        self.deadline = deadline
    }

    @objc private func step(_ link: CADisplayLink) {
        advance(to: link.targetTimestamp)
    }

    /// A frame from the timer, only when the display link has fallen silent.
    private func backupStep() {
        let now = CACurrentMediaTime()
        guard now - lastFrame > 1.5 * Self.frameInterval else { return }
        advance(to: now)
    }

    private func advance(to time: CFTimeInterval) {
        lastFrame = CACurrentMediaTime()
        let linear = duration > 0 ? (time - began) / duration : 1
        show(progress: TreemapTransition.eased(linear))
        if linear >= 1 { complete() }
    }

    private func complete() {
        guard link != nil || backup != nil || deadline != nil else { return }
        stop()
        completion?()
    }

    private func show(progress: Double) {
        guard let geometry else { return }
        let frame = geometry.frame(at: CGFloat(progress))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        outgoing.frame = frame.outgoing
        incoming.frame = frame.incoming
        (geometry.incomingOnTop ? incoming : outgoing).alphaValue = frame.topOpacity
        CATransaction.commit()
    }

    func stop() {
        link?.invalidate()
        link = nil
        backup?.invalidate()
        backup = nil
        deadline?.invalidate()
        deadline = nil
    }
}

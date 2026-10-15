import AppKit

/// A snapshot in logical screen points. Keeping this independent of NSScreen
/// lets layout and display reconfiguration be checked without reading a screen.
struct ScreenGeometry: Equatable {
    let id: UInt32
    let frame: CGRect
    let visibleFrame: CGRect
    let scale: CGFloat

    init(id: UInt32, frame: CGRect, visibleFrame: CGRect? = nil, scale: CGFloat = 1) {
        self.id = id
        self.frame = frame
        self.visibleFrame = visibleFrame ?? frame
        self.scale = scale
    }

    @MainActor
    static var current: [ScreenGeometry] {
        NSScreen.screens.map { screen in
            ScreenGeometry(id: (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0,
                           frame: screen.frame, visibleFrame: screen.visibleFrame, scale: screen.backingScaleFactor)
        }
    }

    @MainActor
    static func resolveCurrent(point: CGPoint? = nil, anchor: CGRect) -> ScreenGeometry? {
        resolve(screens: current, point: point, anchor: anchor)
    }

    static func resolve(screens: [ScreenGeometry], point: CGPoint? = nil, anchor: CGRect) -> ScreenGeometry? {
        let screens = screens.filter { usable($0.frame) && usable($0.visibleFrame) }
        guard !screens.isEmpty else { return nil }
        let point = point.flatMap { finite($0) ? $0 : nil }
        if let point, let containing = screens.first(where: { $0.frame.contains(point) }) { return containing }
        if usable(anchor) {
            var best: ScreenGeometry?
            var largest: CGFloat = 0
            for screen in screens {
                let overlap = screen.frame.intersection(anchor)
                let area = overlap.isNull ? 0 : overlap.width * overlap.height
                if area > largest { largest = area; best = screen }
            }
            if let best { return best }
        }
        let center = CGPoint(x: anchor.midX, y: anchor.midY)
        let reference = point ?? (finite(center) ? center : .zero)
        return screens.min { TextLogic.distance(reference, to: $0.frame) < TextLogic.distance(reference, to: $1.frame) }
    }

    /// A cursor at the top edge must not create an anchor whose center belongs
    /// to the monitor above it (a frequent menu-bar trigger).
    static func pointerAnchor(_ point: CGPoint, size: CGSize = CGSize(width: 8, height: 18)) -> CGRect {
        CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height)
    }

    static func safeFrame(visible: CGRect, margin: CGFloat = 12) -> CGRect {
        guard usable(visible) else { return CGRect(x: 0, y: 0, width: 1, height: 1) }
        let margin = margin.isFinite ? max(0, margin) : 0
        let dx = min(margin, max(0, (visible.width - 1) / 2))
        let dy = min(margin, max(0, (visible.height - 1) / 2))
        return visible.insetBy(dx: dx, dy: dy)
    }

    static func constrainedFrame(_ frame: CGRect, visible: CGRect, margin: CGFloat = 12) -> CGRect {
        let safe = safeFrame(visible: visible, margin: margin)
        let width = min(safe.width, frame.width.isFinite ? max(1, frame.width) : safe.width)
        let height = min(safe.height, frame.height.isFinite ? max(1, frame.height) : safe.height)
        let x = frame.minX.isFinite ? frame.minX : safe.minX
        let y = frame.minY.isFinite ? frame.minY : safe.minY
        return CGRect(x: min(max(x, safe.minX), safe.maxX - width),
                      y: min(max(y, safe.minY), safe.maxY - height), width: width, height: height)
    }

    private static func finite(_ point: CGPoint) -> Bool { point.x.isFinite && point.y.isFinite }
    private static func usable(_ rect: CGRect) -> Bool {
        !rect.isNull && !rect.isInfinite && rect.minX.isFinite && rect.minY.isFinite
            && rect.width.isFinite && rect.height.isFinite && rect.width > 0 && rect.height > 0
    }
}

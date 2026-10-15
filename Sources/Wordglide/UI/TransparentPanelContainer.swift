import AppKit
import SwiftUI

/// The window's entire content tree must remain transparent outside its shape.
/// A visual-effect view can composite a rectangular backdrop even when a SwiftUI
/// child clips its own background, so solid cards use one explicit layer mask.
final class TransparentPanelContainer: NSView {
    let cornerRadius: CGFloat

    init(frame: NSRect, cornerRadius: CGFloat = 0) {
        self.cornerRadius = cornerRadius
        super.init(frame: frame)
        configureLayer()
    }

    required init?(coder: NSCoder) {
        cornerRadius = 0
        super.init(coder: coder)
        configureLayer()
    }

    override var isOpaque: Bool { false }
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        configureLayer()
    }

    private func configureLayer() {
        wantsLayer = true
        layer?.isOpaque = false
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.cornerRadius = cornerRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = cornerRadius > 0
    }
}

/// Explicit transparency prevents AppKit from treating the hosting root as an
/// opaque rectangular backing when it is placed in a borderless panel.
final class TransparentPanelHostingView<Content: View>: NSHostingView<Content> {
    override var isOpaque: Bool { false }
}

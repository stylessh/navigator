import AppKit
import SwiftUI

/// Hosts the SwiftUI toolbar inside the AppKit window.
///
/// The host is a fixed, transparent canvas along the bottom of the window (see
/// `canvasHeight`), and the toolbar lays itself out at the bottom-center of it. It used to be
/// sized to the toolbar's intrinsic size, but then every expand, collapse or shelf toggle
/// resized the NSView to the final size in one step while SwiftUI was still springing the
/// content, so the glass clipped and the bar jumped vertically mid-animation. With a fixed
/// canvas the window never re-lays out during a morph, and `hitTest` only claims clicks
/// inside the toolbar itself so the page underneath keeps everything else.
final class BrowserFloatingToolbarHostView: NSHostingView<BrowserFloatingToolbarView> {
	/// Tall enough for the tab shelf above the bar plus spring overshoot and glass shadow.
	static let canvasHeight: CGFloat = 220

	/// The toolbar's interactive frame in this view's (flipped, SwiftUI global) space.
	var interactiveRect: () -> CGRect = { .zero }

	required init(rootView: BrowserFloatingToolbarView) {
		super.init(rootView: rootView)
		sizingOptions = []
		safeAreaRegions = []
		translatesAutoresizingMaskIntoConstraints = false
		wantsLayer = true
		layer?.backgroundColor = NSColor.clear.cgColor
	}

	@available(*, unavailable)
	@MainActor required dynamic init?(coder aDecoder: NSCoder) {
		fatalError("init(coder:) has not been implemented")
	}

	override var mouseDownCanMoveWindow: Bool {
		false
	}

	override func hitTest(_ point: NSPoint) -> NSView? {
		guard let superview else { return nil }
		let local = convert(point, from: superview)
		// SwiftUI reports frames with a top-left origin.
		let swiftUIPoint = isFlipped ? local : CGPoint(x: local.x, y: bounds.height - local.y)
		guard interactiveRect().contains(swiftUIPoint) else { return nil }
		return super.hitTest(point)
	}

	/// Converts a rect in this view's (flipped, SwiftUI global) space to screen coordinates.
	func screenRect(forHostedRect rect: CGRect) -> NSRect? {
		guard let window, !rect.isEmpty else { return nil }
		let rectInWindow = convert(rect, to: nil)
		return window.convertToScreen(rectInWindow)
	}
}

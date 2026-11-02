import AppKit
import SwiftUI

/// Hosts the SwiftUI toolbar inside the AppKit window, sized to the toolbar's own content so it
/// only intercepts clicks where the glass actually is.
final class BrowserFloatingToolbarHostView: NSHostingView<BrowserFloatingToolbarView> {
	required init(rootView: BrowserFloatingToolbarView) {
		super.init(rootView: rootView)
		sizingOptions = [.intrinsicContentSize]
		safeAreaRegions = []
		translatesAutoresizingMaskIntoConstraints = false
		setContentHuggingPriority(.required, for: .horizontal)
		setContentHuggingPriority(.required, for: .vertical)
	}

	@available(*, unavailable)
	@MainActor required dynamic init?(coder aDecoder: NSCoder) {
		fatalError("init(coder:) has not been implemented")
	}

	override var mouseDownCanMoveWindow: Bool {
		false
	}

	/// Converts a rect in this view's (flipped, SwiftUI global) space to screen coordinates.
	func screenRect(forHostedRect rect: CGRect) -> NSRect? {
		guard let window, !rect.isEmpty else { return nil }
		let rectInWindow = convert(rect, to: nil)
		return window.convertToScreen(rectInWindow)
	}
}

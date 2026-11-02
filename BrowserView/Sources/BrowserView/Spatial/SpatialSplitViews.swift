import AppKit
import BrowserSidebar
import Vendors

/// Hosts every tab's `BrowserContainerView`. Containers are positioned by frame (not
/// constraints) so split panes can spring between layouts.
@MainActor
final class BrowserSpatialHostView: NSView {
	static let paneGap: CGFloat = 8

	/// Returns the frame for a container, or nil to fill the host.
	var paneFrames: ((CGRect) -> [BrowserTabID: CGRect])?
	var dividers: ((CGRect) -> [SpatialSplitDivider])?
	var focusedPaneID: (() -> BrowserTabID?)?
	var onDividerDrag: ((SpatialSplitDivider, CGPoint) -> Void)?
	var onDividerReset: ((SpatialSplitDivider) -> Void)?

	private var containersByID = [BrowserTabID: NSView]()
	private var springsByID = [BrowserTabID: SpatialFrameSpring]()
	private var dividerViews = [SpatialSplitDividerView]()
	private let focusRing = SpatialPaneFocusRingView()
	private var animatesNextLayout = false

	override var isFlipped: Bool {
		true
	}

	override init(frame frameRect: NSRect) {
		super.init(frame: frameRect)
		wantsLayer = true
		focusRing.alphaValue = 0
		addSubview(focusRing)
	}

	@available(*, unavailable)
	required init?(coder: NSCoder) {
		fatalError("init(coder:) has not been implemented")
	}

	func addContainer(_ container: NSView, for tabID: BrowserTabID) {
		containersByID[tabID] = container
		container.translatesAutoresizingMaskIntoConstraints = true
		container.autoresizingMask = []
		container.frame = bounds
		addSubview(container, positioned: .below, relativeTo: focusRing)
		springsByID[tabID] = SpatialFrameSpring(view: container)
	}

	func removeContainer(for tabID: BrowserTabID) {
		springsByID.removeValue(forKey: tabID)?.stop()
		containersByID.removeValue(forKey: tabID)
	}

	/// Re-applies pane frames; `animated` springs panes into place.
	func setNeedsSpatialLayout(animated: Bool) {
		animatesNextLayout = animatesNextLayout || animated
		needsLayout = true
	}

	override func layout() {
		super.layout()
		let animated = animatesNextLayout && SpatialMotion.prefersReducedMotion == false
		animatesNextLayout = false
		let frames = paneFrames?(bounds) ?? [:]
		for (tabID, container) in containersByID {
			let target = frames[tabID] ?? bounds
			guard let spring = springsByID[tabID] else {
				container.frame = target
				continue
			}
			if spring.target == target, spring.isAnimating || container.frame == target { continue }
			if animated, container.isHidden == false, container.frame.isEmpty == false {
				spring.animate(to: target, spring: SpatialMotion.split)
			}
			else {
				spring.set(target)
			}
		}
		layoutDividers(frames: frames)
		layoutFocusRing(frames: frames, animated: animated)
	}

	private func layoutDividers(frames: [BrowserTabID: CGRect]) {
		let nextDividers = frames.count > 1 ? (dividers?(bounds) ?? []) : []
		while dividerViews.count > nextDividers.count {
			dividerViews.removeLast().removeFromSuperview()
		}
		while dividerViews.count < nextDividers.count {
			let view = SpatialSplitDividerView()
			view.onDrag = { [weak self, weak view] location in
				guard let self, let divider = view?.divider else { return }
				self.onDividerDrag?(divider, self.convert(location, from: nil))
			}
			view.onReset = { [weak self, weak view] in
				guard let divider = view?.divider else { return }
				self?.onDividerReset?(divider)
			}
			addSubview(view)
			dividerViews.append(view)
		}
		for (view, divider) in zip(dividerViews, nextDividers) {
			view.divider = divider
			view.frame = divider.rect
		}
	}

	private func layoutFocusRing(frames: [BrowserTabID: CGRect], animated: Bool) {
		guard frames.count > 1, let focusedID = focusedPaneID?(), let frame = frames[focusedID] else {
			focusRing.alphaValue = 0
			return
		}
		let ringFrame = frame.insetBy(dx: -2, dy: -2)
		if animated, focusRing.alphaValue > 0 {
			focusRing.frameSpring.animate(to: ringFrame, spring: SpatialMotion.split)
		}
		else {
			focusRing.frameSpring.set(ringFrame)
		}
		focusRing.alphaValue = 1
		addSubview(focusRing, positioned: .above, relativeTo: nil)
		for view in dividerViews {
			addSubview(view, positioned: .above, relativeTo: focusRing)
		}
	}
}

/// Thin accent outline around the focused pane of a split.
@MainActor
final class SpatialPaneFocusRingView: NSView {
	lazy var frameSpring = SpatialFrameSpring(view: self)

	override init(frame frameRect: NSRect) {
		super.init(frame: frameRect)
		wantsLayer = true
		layer?.borderWidth = 2
		layer?.cornerRadius = 12
		layer?.cornerCurve = .continuous
		layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.55).cgColor
	}

	@available(*, unavailable)
	required init?(coder: NSCoder) {
		fatalError("init(coder:) has not been implemented")
	}

	override func hitTest(_ point: NSPoint) -> NSView? {
		nil
	}

	override func viewDidChangeEffectiveAppearance() {
		super.viewDidChangeEffectiveAppearance()
		layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.55).cgColor
	}
}

/// Draggable gap between two panes. Shows a small glass grip on hover.
@MainActor
final class SpatialSplitDividerView: NSView {
	var divider: SpatialSplitDivider? {
		didSet {
			if oldValue?.axis != divider?.axis {
				window?.invalidateCursorRects(for: self)
			}
			needsLayout = true
		}
	}

	var onDrag: ((CGPoint) -> Void)?
	var onReset: (() -> Void)?

	private let grip = SpatialGlassView(style: .regular, cornerRadius: 3)
	private lazy var gripAlpha = SpatialValueSpring(initial: 0) { [weak self] alpha in
		self?.grip.alphaValue = alpha
	}
	private var trackingArea: NSTrackingArea?
	private var isDragging = false

	override init(frame frameRect: NSRect) {
		super.init(frame: frameRect)
		wantsLayer = true
		addSubview(grip)
	}

	@available(*, unavailable)
	required init?(coder: NSCoder) {
		fatalError("init(coder:) has not been implemented")
	}

	override func layout() {
		super.layout()
		let isHorizontal = divider?.axis != .vertical
		let size = isHorizontal ? CGSize(width: 6, height: 44) : CGSize(width: 44, height: 6)
		grip.frame = CGRect(
			x: (bounds.width - size.width) / 2,
			y: (bounds.height - size.height) / 2,
			width: size.width,
			height: size.height
		)
	}

	override func resetCursorRects() {
		addCursorRect(bounds, cursor: divider?.axis == .vertical ? .resizeUpDown : .resizeLeftRight)
	}

	override func updateTrackingAreas() {
		super.updateTrackingAreas()
		if let trackingArea {
			removeTrackingArea(trackingArea)
		}
		let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
		addTrackingArea(area)
		trackingArea = area
	}

	override func mouseEntered(with event: NSEvent) {
		gripAlpha.animate(to: 1, spring: SpatialMotion.lift)
	}

	override func mouseExited(with event: NSEvent) {
		guard isDragging == false else { return }
		gripAlpha.animate(to: 0, spring: SpatialMotion.lift)
	}

	override func mouseDown(with event: NSEvent) {
		if event.clickCount == 2 {
			onReset?()
			return
		}
		isDragging = true
	}

	override func mouseDragged(with event: NSEvent) {
		onDrag?(event.locationInWindow)
	}

	override func mouseUp(with event: NSEvent) {
		isDragging = false
		let location = convert(event.locationInWindow, from: nil)
		if bounds.contains(location) == false {
			gripAlpha.animate(to: 0, spring: SpatialMotion.lift)
		}
	}
}

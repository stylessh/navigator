import AppKit

/// Wraps the browser view. In responsive mode it simply fills; with a viewport preset the page is
/// framed at the preset size, centered on a subtle dotted stage, and the size change is driven by a
/// spring on the display link (the page reflows live as the frame springs).
///
/// The right and bottom edges of the frame (and the corner) are drag handles for a custom size.
@MainActor
public final class DeveloperViewportStageView: NSView {
	public let contentView: NSView
	/// Called while the user drags a handle (custom size, in points).
	public var onCustomSizeChange: ((CGSize) -> Void)?

	private let frameView = DeveloperViewportFrameView()
	private var fillConstraints: [NSLayoutConstraint] = []
	private var framedConstraints: [NSLayoutConstraint] = []
	private var widthConstraint: NSLayoutConstraint?
	private var heightConstraint: NSLayoutConstraint?
	private lazy var animator = DeveloperSpringSizeAnimator(value: .zero)
	private let rightHandle = DeveloperViewportHandle(edge: .right)
	private let bottomHandle = DeveloperViewportHandle(edge: .bottom)
	private let cornerHandle = DeveloperViewportHandle(edge: .corner)
	private var isFramed = false
	private var dragOrigin: (point: CGPoint, size: CGSize)?

	/// Room kept around the framed page for the badge on top and the toolbar at the bottom.
	public var framedInsets = NSEdgeInsets(top: 56, left: 24, bottom: 96, right: 24) {
		didSet { needsLayout = true }
	}

	public private(set) var mode: DeveloperViewportMode = .responsive

	public init(contentView: NSView) {
		self.contentView = contentView
		super.init(frame: .zero)
		translatesAutoresizingMaskIntoConstraints = false
		wantsLayer = true

		frameView.translatesAutoresizingMaskIntoConstraints = false
		addSubview(frameView)

		contentView.translatesAutoresizingMaskIntoConstraints = false
		frameView.addSubview(contentView)
		NSLayoutConstraint.activate([
			contentView.topAnchor.constraint(equalTo: frameView.topAnchor),
			contentView.leadingAnchor.constraint(equalTo: frameView.leadingAnchor),
			contentView.trailingAnchor.constraint(equalTo: frameView.trailingAnchor),
			contentView.bottomAnchor.constraint(equalTo: frameView.bottomAnchor),
		])

		fillConstraints = [
			frameView.topAnchor.constraint(equalTo: topAnchor),
			frameView.leadingAnchor.constraint(equalTo: leadingAnchor),
			frameView.trailingAnchor.constraint(equalTo: trailingAnchor),
			frameView.bottomAnchor.constraint(equalTo: bottomAnchor),
		]

		let width = frameView.widthAnchor.constraint(equalToConstant: 100)
		let height = frameView.heightAnchor.constraint(equalToConstant: 100)
		widthConstraint = width
		heightConstraint = height
		// Center in the space between the insets: offset the vertical center by half the inset delta.
		framedConstraints = [
			frameView.centerXAnchor.constraint(equalTo: centerXAnchor),
			frameView.centerYAnchor.constraint(equalTo: centerYAnchor),
			width,
			height,
		]
		NSLayoutConstraint.activate(fillConstraints)

		for handle in [rightHandle, bottomHandle, cornerHandle] {
			handle.isHidden = true
			handle.onDrag = { [weak self] phase, location in
				self?.handleDrag(phase: phase, edge: handle.edge, location: location)
			}
			addSubview(handle)
		}

		animator.onChange = { [weak self] size in
			self?.apply(size: size)
		}
	}

	@available(*, unavailable)
	required init?(coder: NSCoder) {
		fatalError("init(coder:) has not been implemented")
	}

	override public var isFlipped: Bool {
		true
	}

	// MARK: Mode

	public func setMode(_ newMode: DeveloperViewportMode, animated: Bool) {
		guard newMode != mode else { return }
		mode = newMode
		layoutSubtreeIfNeeded()

		switch newMode {
		case .responsive:
			guard isFramed else { return }
			let fullSize = bounds.size
			if animated, window != nil {
				animator.animate(to: fullSize, in: self) { [weak self] in
					self?.switchToFill()
				}
			}
			else {
				animator.stop()
				switchToFill()
			}
			setStageVisible(false, animated: animated)
		case .preset:
			let target = clampedTargetSize()
			if isFramed == false {
				// Start the spring from the current full-bleed size so the frame visibly shrinks.
				switchToFramed(startingAt: frameView.frame.size)
			}
			setStageVisible(true, animated: animated)
			if animated, window != nil {
				animator.animate(to: target, in: self)
			}
			else {
				animator.jump(to: target)
			}
		}
	}

	private func switchToFramed(startingAt size: CGSize) {
		isFramed = true
		NSLayoutConstraint.deactivate(fillConstraints)
		NSLayoutConstraint.activate(framedConstraints)
		animator.jump(to: size)
		frameView.setFramed(true)
		[rightHandle, bottomHandle, cornerHandle].forEach { $0.isHidden = false }
	}

	private func switchToFill() {
		isFramed = false
		NSLayoutConstraint.deactivate(framedConstraints)
		NSLayoutConstraint.activate(fillConstraints)
		frameView.setFramed(false)
		[rightHandle, bottomHandle, cornerHandle].forEach { $0.isHidden = true }
		needsLayout = true
	}

	private func apply(size: CGSize) {
		widthConstraint?.constant = max(80, size.width)
		heightConstraint?.constant = max(80, size.height)
		layoutSubtreeIfNeeded()
		positionHandles()
	}

	private func availableSize() -> CGSize {
		CGSize(
			width: max(160, bounds.width - framedInsets.left - framedInsets.right),
			height: max(160, bounds.height - framedInsets.top - framedInsets.bottom)
		)
	}

	/// The preset size, shrunk to fit the window. (Scaling the page would break CEF hit testing,
	/// so a too-large preset is clamped and the badge still shows the requested size.)
	private func clampedTargetSize() -> CGSize {
		guard let target = mode.targetSize else { return bounds.size }
		let available = availableSize()
		return CGSize(width: min(target.width, available.width), height: min(target.height, available.height))
	}

	override public func layout() {
		super.layout()
		guard isFramed else { return }
		// Keep the frame inside the stage when the window resizes.
		if animator.isAnimating == false, dragOrigin == nil, mode.targetSize != nil {
			let target = clampedTargetSize()
			if abs(target.width - animator.value.width) > 0.5 || abs(target.height - animator.value.height) > 0.5 {
				animator.jump(to: target)
			}
		}
		// Bias the frame down so it sits between the badge and the toolbar.
		if let centerY = framedConstraints.first(where: { $0.firstAttribute == .centerY }) {
			centerY.constant = (framedInsets.top - framedInsets.bottom) / 2
		}
		positionHandles()
	}

	// MARK: Stage chrome

	private func setStageVisible(_ isVisible: Bool, animated: Bool) {
		let pattern = DeveloperViewportStageView.dotPatternColor(for: effectiveAppearance)
		let target: CGColor = isVisible ? pattern.cgColor : NSColor.clear.cgColor
		guard animated else {
			layer?.backgroundColor = target
			return
		}
		let fade = CABasicAnimation(keyPath: "backgroundColor")
		fade.fromValue = layer?.presentation()?.backgroundColor ?? layer?.backgroundColor
		fade.toValue = target
		fade.duration = 0.3
		layer?.add(fade, forKey: "stageFade")
		layer?.backgroundColor = target
	}

	override public func viewDidChangeEffectiveAppearance() {
		super.viewDidChangeEffectiveAppearance()
		if isFramed {
			layer?.backgroundColor = Self.dotPatternColor(for: effectiveAppearance).cgColor
		}
		frameView.refreshAppearance()
	}

	private static func dotPatternColor(for appearance: NSAppearance) -> NSColor {
		let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
		let size = NSSize(width: 16, height: 16)
		let image = NSImage(size: size, flipped: false) { rect in
			(isDark ? NSColor(white: 0.1, alpha: 1) : NSColor(white: 0.93, alpha: 1)).setFill()
			rect.fill()
			(isDark ? NSColor(white: 1, alpha: 0.09) : NSColor(white: 0, alpha: 0.09)).setFill()
			NSBezierPath(ovalIn: NSRect(x: 7, y: 7, width: 2, height: 2)).fill()
			return true
		}
		return NSColor(patternImage: image)
	}

	// MARK: Handles

	private func positionHandles() {
		guard isFramed else { return }
		let frame = frameView.frame
		let thickness: CGFloat = 10
		rightHandle.frame = NSRect(x: frame.maxX, y: frame.minY + 16, width: thickness, height: max(0, frame.height - 32))
		bottomHandle.frame = NSRect(x: frame.minX + 16, y: frame.maxY, width: max(0, frame.width - 32), height: thickness)
		cornerHandle.frame = NSRect(x: frame.maxX - 6, y: frame.maxY - 6, width: 18, height: 18)
	}

	private func handleDrag(phase: DeveloperViewportHandle.Phase, edge: DeveloperViewportHandle.Edge, location: CGPoint) {
		let point = convert(location, from: nil)
		switch phase {
		case .began:
			animator.stop()
			dragOrigin = (point, animator.value)
		case .changed:
			guard let origin = dragOrigin else { return }
			// The frame is centered, so a handle moves half as fast as the size changes.
			let dx = (point.x - origin.point.x) * 2
			let dy = (point.y - origin.point.y) * 2
			let available = availableSize()
			var size = origin.size
			if edge == .right || edge == .corner {
				size.width = min(available.width, max(240, origin.size.width + dx))
			}
			if edge == .bottom || edge == .corner {
				size.height = min(available.height, max(240, origin.size.height + dy))
			}
			animator.jump(to: size)
			onCustomSizeChange?(size)
		case .ended:
			dragOrigin = nil
		}
	}

	/// Excludes the stage background from hit testing so clicks on the dotted area do nothing odd,
	/// but keeps handles and the page interactive.
	override public func hitTest(_ point: NSPoint) -> NSView? {
		let hit = super.hitTest(point)
		return hit === self ? nil : hit
	}
}

/// Rounded, shadowed frame around the page when a preset is active.
@MainActor
private final class DeveloperViewportFrameView: NSView {
	private var isFramed = false

	override init(frame frameRect: NSRect) {
		super.init(frame: frameRect)
		wantsLayer = true
		layer?.masksToBounds = false
	}

	@available(*, unavailable)
	required init?(coder: NSCoder) {
		fatalError("init(coder:) has not been implemented")
	}

	func setFramed(_ framed: Bool) {
		isFramed = framed
		refreshAppearance()
	}

	func refreshAppearance() {
		guard let layer else { return }
		CATransaction.begin()
		CATransaction.setAnimationDuration(0.3)
		layer.cornerRadius = isFramed ? 14 : 0
		layer.masksToBounds = isFramed
		layer.borderWidth = isFramed ? 0.5 : 0
		layer.borderColor = NSColor.separatorColor.cgColor
		CATransaction.commit()
	}
}

/// Thin invisible drag strip with a resize cursor.
@MainActor
final class DeveloperViewportHandle: NSView {
	enum Edge {
		case right
		case bottom
		case corner
	}

	enum Phase {
		case began
		case changed
		case ended
	}

	let edge: Edge
	var onDrag: ((Phase, CGPoint) -> Void)?
	private var isHovering = false

	init(edge: Edge) {
		self.edge = edge
		super.init(frame: .zero)
		wantsLayer = true
	}

	@available(*, unavailable)
	required init?(coder: NSCoder) {
		fatalError("init(coder:) has not been implemented")
	}

	override var mouseDownCanMoveWindow: Bool {
		false
	}

	override func resetCursorRects() {
		let cursor: NSCursor = switch edge {
		case .right: .resizeLeftRight
		case .bottom: .resizeUpDown
		case .corner: .crosshair
		}
		addCursorRect(bounds, cursor: cursor)
	}

	override func updateTrackingAreas() {
		super.updateTrackingAreas()
		trackingAreas.forEach(removeTrackingArea)
		addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow], owner: self))
	}

	override func mouseEntered(with event: NSEvent) {
		setHighlighted(true)
	}

	override func mouseExited(with event: NSEvent) {
		setHighlighted(false)
	}

	private func setHighlighted(_ highlighted: Bool) {
		isHovering = highlighted
		CATransaction.begin()
		CATransaction.setAnimationDuration(0.15)
		layer?.backgroundColor = highlighted ? NSColor.controlAccentColor.withAlphaComponent(0.35).cgColor : nil
		layer?.cornerRadius = 4
		CATransaction.commit()
	}

	override func mouseDown(with event: NSEvent) {
		onDrag?(.began, event.locationInWindow)
	}

	override func mouseDragged(with event: NSEvent) {
		onDrag?(.changed, event.locationInWindow)
	}

	override func mouseUp(with event: NSEvent) {
		onDrag?(.ended, event.locationInWindow)
		setHighlighted(false)
	}
}

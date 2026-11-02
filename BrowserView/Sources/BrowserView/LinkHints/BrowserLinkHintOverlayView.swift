import AppKit
import Carbon.HIToolbox
import QuartzCore

/// Transparent overlay placed above the web content while hint mode is active.
///
/// It draws one glass chip per hint, takes keyboard focus so typed letters never reach the
/// page, and dismisses itself on any click or scroll.
@MainActor
final class BrowserLinkHintOverlayView: NSView {
	var onType: ((String) -> Void)?
	var onDeleteBackward: (() -> Void)?
	var onCancel: (() -> Void)?

	private var chipsByHintID = [Int: BrowserLinkHintChipView]()
	private let chipLayer: NSView
	private var isFinishing = false

	override init(frame frameRect: NSRect) {
		chipLayer = Self.makeChipContainer()
		super.init(frame: frameRect)
		wantsLayer = true
		layer?.masksToBounds = true
		chipLayer.frame = bounds
		chipLayer.autoresizingMask = [.width, .height]
		addSubview(chipLayer)
		setAccessibilityElement(true)
		setAccessibilityRole(.group)
		setAccessibilityLabel("Link hints")
	}

	@available(*, unavailable)
	required init?(coder: NSCoder) {
		fatalError("init(coder:) has not been implemented")
	}

	override var isFlipped: Bool { true }
	override var acceptsFirstResponder: Bool { true }

	override func hitTest(_ point: NSPoint) -> NSView? {
		// While the exit animation plays, let clicks fall through to the page.
		guard isFinishing == false else { return nil }
		return frame.contains(point) ? self : nil
	}

	/// The view that chips are added to. On macOS 26 this is the content view of a glass
	/// container so neighbouring chips share one glass pass.
	private var chipParent: NSView {
		#if compiler(>=6.2)
			if #available(macOS 26.0, *), let container = chipLayer as? NSGlassEffectContainerView {
				return container.contentView ?? chipLayer
			}
		#endif
		return chipLayer
	}

	private static func makeChipContainer() -> NSView {
		#if compiler(>=6.2)
			if #available(macOS 26.0, *) {
				let container = NSGlassEffectContainerView()
				container.spacing = 0
				let content = FlippedView()
				content.autoresizingMask = [.width, .height]
				container.contentView = content
				return container
			}
		#endif
		return FlippedView()
	}

	// MARK: Presentation

	/// Shows chips for `hints`. `scale` converts page CSS pixels to view points.
	func present(hints: [BrowserLinkHint], scale: CGFloat) {
		chipsByHintID.values.forEach { $0.removeFromSuperview() }
		chipsByHintID.removeAll()
		chipParent.frame = chipLayer.bounds

		let now = CACurrentMediaTime()
		let height = max(bounds.height, 1)
		for hint in hints {
			let chip = BrowserLinkHintChipView(label: hint.label, kind: hint.kind)
			let size = chip.fittingSize
			let targetRect = hint.pageRect.applying(CGAffineTransform(scaleX: scale, y: scale))
			chip.frame = Self.chipFrame(size: size, targetRect: targetRect, bounds: bounds)
			chipParent.addSubview(chip)
			chipsByHintID[hint.id] = chip
			// Stagger top-to-bottom so the hints "rain" in instead of popping all at once.
			let delay = Double(min(max(chip.frame.minY / height, 0), 1)) * 0.07
			chip.animateIn(beginTime: now + delay)
		}
	}

	static func chipFrame(size: CGSize, targetRect: CGRect, bounds: CGRect) -> CGRect {
		var origin: CGPoint
		if targetRect.height <= 44 {
			// Small targets (links in text, buttons): hang off the top-leading corner like a badge,
			// so the chip covers as little of the element's own text as possible.
			origin = CGPoint(
				x: targetRect.minX - size.width * 0.45,
				y: targetRect.minY - size.height * 0.5
			)
		}
		else {
			// Large targets (cards, images): tuck into the top-leading corner.
			origin = CGPoint(x: targetRect.minX + 4, y: targetRect.minY + 4)
		}
		origin.x = min(max(origin.x, 2), max(bounds.width - size.width - 2, 2))
		origin.y = min(max(origin.y, 2), max(bounds.height - size.height - 2, 2))
		return CGRect(origin: origin, size: size).integral
	}

	func update(matching: [BrowserLinkHint], typedPrefix: String) {
		let matchingIDs = Set(matching.map(\.id))
		for (id, chip) in chipsByHintID {
			if matchingIDs.contains(id) {
				chip.setTypedPrefixLength(typedPrefix.count)
				chip.setVisible(true)
			}
			else {
				chip.setVisible(false)
			}
		}
	}

	func reject() {
		let shake = CAKeyframeAnimation(keyPath: "transform.translation.x")
		shake.values = [0, -7, 6, -4, 3, -1, 0]
		shake.duration = 0.32
		shake.timingFunction = CAMediaTimingFunction(name: .easeOut)
		chipLayer.layer?.add(shake, forKey: "reject")
		NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
	}

	/// Plays the activation animation for `hintID`, then calls `completion`.
	func finish(activating hintID: Int, targetRect: CGRect, completion: @escaping @MainActor () -> Void) {
		guard isFinishing == false else { return }
		isFinishing = true
		for (id, chip) in chipsByHintID where id != hintID {
			chip.animateOut(duration: 0.12)
		}
		chipsByHintID[hintID]?.animateActivation()
		flashTarget(targetRect)
		Task { @MainActor in
			try? await Task.sleep(for: .seconds(0.45))
			completion()
		}
	}

	func dismiss(completion: @escaping @MainActor () -> Void) {
		guard isFinishing == false else { return }
		isFinishing = true
		chipsByHintID.values.forEach { $0.animateOut(duration: 0.12) }
		Task { @MainActor in
			try? await Task.sleep(for: .seconds(0.12))
			completion()
		}
	}

	private func flashTarget(_ rect: CGRect) {
		guard rect.isEmpty == false else { return }
		let flash = CALayer()
		flash.frame = rect.insetBy(dx: -3, dy: -3)
		flash.cornerRadius = 6
		flash.borderWidth = 2
		flash.borderColor = NSColor.controlAccentColor.cgColor
		flash.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.12).cgColor
		flash.opacity = 0
		layer?.addSublayer(flash)

		let fade = CAKeyframeAnimation(keyPath: "opacity")
		fade.values = [0, 1, 0]
		fade.keyTimes = [0, 0.25, 1]
		fade.duration = 0.45
		let grow = CASpringAnimation(perceptualDuration: 0.4, bounce: 0.35)
		grow.keyPath = "bounds.size"
		grow.fromValue = NSValue(size: rect.insetBy(dx: 2, dy: 2).size)
		grow.toValue = NSValue(size: flash.bounds.size)
		let group = CAAnimationGroup()
		group.animations = [fade, grow]
		group.duration = 0.45
		flash.add(group, forKey: "flash")
		Task { @MainActor in
			try? await Task.sleep(for: .seconds(0.5))
			flash.removeFromSuperlayer()
		}
	}

	// MARK: Input

	override func keyDown(with event: NSEvent) {
		let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
		if modifiers.contains(.command) {
			super.keyDown(with: event)
			return
		}
		switch Int(event.keyCode) {
		case kVK_Escape:
			onCancel?()
		case kVK_Delete, kVK_ForwardDelete:
			onDeleteBackward?()
		default:
			guard let characters = event.charactersIgnoringModifiers, characters.isEmpty == false else { return }
			onType?(characters)
		}
	}

	override func cancelOperation(_ sender: Any?) {
		onCancel?()
	}

	override func mouseDown(with event: NSEvent) {
		onCancel?()
	}

	override func rightMouseDown(with event: NSEvent) {
		onCancel?()
	}

	override func scrollWheel(with event: NSEvent) {
		onCancel?()
	}
}

private final class FlippedView: NSView {
	override var isFlipped: Bool { true }

	override func hitTest(_ point: NSPoint) -> NSView? {
		nil
	}
}

/// A single hint label rendered on Liquid Glass (macOS 26) or a blur material (macOS 15).
@MainActor
final class BrowserLinkHintChipView: NSView {
	private static let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .bold)
	private static let horizontalPadding: CGFloat = 6
	private static let verticalPadding: CGFloat = 2.5
	private static let cornerRadius: CGFloat = 7

	private let label: String
	private let textView = BrowserLinkHintLabelView()
	private var typedPrefixLength = 0
	private var isShown = true

	init(label: String, kind: BrowserLinkHintTarget.Kind) {
		self.label = label
		super.init(frame: .zero)
		wantsLayer = true
		applyText()

		// Size from the measured string, not NSTextField's intrinsic size: inside
		// NSGlassEffectView the text field was laid out a few points wide and clipped.
		let textSize = textView.attributedString.size()
		let size = CGSize(
			width: max(ceil(textSize.width + Self.horizontalPadding * 2), ceil(textSize.height + Self.verticalPadding * 2)),
			height: ceil(textSize.height + Self.verticalPadding * 2)
		)
		frame = CGRect(origin: .zero, size: size)
		textView.frame = bounds
		textView.autoresizingMask = [.width, .height]
		let background = Self.makeBackground(kind: kind, size: size, content: textView)
		background.frame = bounds
		background.autoresizingMask = [.width, .height]
		addSubview(background)
		setAccessibilityElement(true)
		setAccessibilityLabel("Hint \(label.uppercased())")
	}

	@available(*, unavailable)
	required init?(coder: NSCoder) {
		fatalError("init(coder:) has not been implemented")
	}

	override var fittingSize: NSSize { frame.size }

	override func hitTest(_ point: NSPoint) -> NSView? {
		nil
	}

	private static func makeBackground(kind: BrowserLinkHintTarget.Kind, size: CGSize, content: NSView) -> NSView {
		let tint: NSColor? = kind == .input ? NSColor.systemBlue.withAlphaComponent(0.18) : nil
		#if compiler(>=6.2)
			if #available(macOS 26.0, *) {
				let glass = NSGlassEffectView()
				glass.cornerRadius = cornerRadius
				glass.tintColor = tint
				glass.frame = CGRect(origin: .zero, size: size)
				content.frame = glass.bounds
				glass.contentView = content
				return glass
			}
		#endif
		let blur = NSVisualEffectView()
		blur.material = .popover
		blur.blendingMode = .withinWindow
		blur.state = .active
		blur.wantsLayer = true
		blur.layer?.cornerRadius = cornerRadius
		blur.layer?.cornerCurve = .continuous
		blur.layer?.masksToBounds = true
		blur.layer?.borderWidth = 0.5
		blur.layer?.borderColor = NSColor.separatorColor.cgColor
		if let tint {
			let tintView = NSView(frame: CGRect(origin: .zero, size: size))
			tintView.wantsLayer = true
			tintView.layer?.backgroundColor = tint.cgColor
			tintView.autoresizingMask = [.width, .height]
			blur.addSubview(tintView)
		}
		blur.addSubview(content)
		return blur
	}

	private func applyText() {
		let display = label.uppercased()
		let attributed = NSMutableAttributedString(
			string: display,
			attributes: [
				.font: Self.font,
				.foregroundColor: NSColor.labelColor,
				.kern: 0.6,
			]
		)
		if typedPrefixLength > 0 {
			attributed.addAttribute(
				.foregroundColor,
				value: NSColor.controlAccentColor,
				range: NSRange(location: 0, length: min(typedPrefixLength, display.utf16.count))
			)
		}
		textView.attributedString = attributed
	}

	func setTypedPrefixLength(_ length: Int) {
		guard length != typedPrefixLength else { return }
		typedPrefixLength = length
		applyText()
		if length > 0 {
			pulse()
		}
	}

	func setVisible(_ visible: Bool) {
		guard visible != isShown else { return }
		isShown = visible
		if visible {
			isHidden = false
			animateIn(beginTime: CACurrentMediaTime())
		}
		else {
			animateOut(duration: 0.14)
		}
	}

	// MARK: Spring animations

	private func scaleTransform(_ scale: CGFloat) -> CATransform3D {
		let size = bounds.size
		var transform = CATransform3DMakeTranslation(size.width / 2, size.height / 2, 0)
		transform = CATransform3DScale(transform, scale, scale, 1)
		return CATransform3DTranslate(transform, -size.width / 2, -size.height / 2, 0)
	}

	func animateIn(beginTime: CFTimeInterval) {
		guard let layer else { return }
		layer.removeAllAnimations()
		layer.opacity = 1
		layer.transform = CATransform3DIdentity

		let scale = CASpringAnimation(perceptualDuration: 0.38, bounce: 0.32)
		scale.keyPath = "transform"
		scale.fromValue = NSValue(caTransform3D: scaleTransform(0.4))
		scale.toValue = NSValue(caTransform3D: CATransform3DIdentity)
		scale.beginTime = beginTime
		scale.fillMode = .backwards
		scale.duration = scale.settlingDuration

		let fade = CABasicAnimation(keyPath: "opacity")
		fade.fromValue = 0
		fade.toValue = 1
		fade.duration = 0.14
		fade.beginTime = beginTime
		fade.fillMode = .backwards

		layer.add(scale, forKey: "in.scale")
		layer.add(fade, forKey: "in.fade")
	}

	func animateOut(duration: CFTimeInterval) {
		guard let layer else { return }
		let fromTransform = layer.presentation()?.transform ?? layer.transform
		let fromOpacity = layer.presentation()?.opacity ?? layer.opacity
		layer.removeAllAnimations()
		layer.opacity = 0
		layer.transform = scaleTransform(0.6)

		let scale = CASpringAnimation(perceptualDuration: duration * 2, bounce: 0)
		scale.keyPath = "transform"
		scale.fromValue = NSValue(caTransform3D: fromTransform)
		scale.toValue = NSValue(caTransform3D: scaleTransform(0.6))
		scale.duration = scale.settlingDuration

		let fade = CABasicAnimation(keyPath: "opacity")
		fade.fromValue = fromOpacity
		fade.toValue = 0
		fade.duration = duration

		layer.add(scale, forKey: "out.scale")
		layer.add(fade, forKey: "out.fade")
	}

	func animateActivation() {
		guard let layer else { return }
		layer.removeAllAnimations()
		layer.transform = scaleTransform(1.0)
		layer.opacity = 0

		let pop = CASpringAnimation(perceptualDuration: 0.3, bounce: 0.45)
		pop.keyPath = "transform"
		pop.fromValue = NSValue(caTransform3D: scaleTransform(1.0))
		pop.toValue = NSValue(caTransform3D: scaleTransform(1.25))
		pop.duration = 0.2

		let fade = CAKeyframeAnimation(keyPath: "opacity")
		fade.values = [1, 1, 0]
		fade.keyTimes = [0, 0.5, 1]
		fade.duration = 0.2

		layer.add(pop, forKey: "activate.pop")
		layer.add(fade, forKey: "activate.fade")
	}

	private func pulse() {
		guard let layer else { return }
		let pulse = CASpringAnimation(perceptualDuration: 0.3, bounce: 0.5)
		pulse.keyPath = "transform"
		pulse.fromValue = NSValue(caTransform3D: scaleTransform(1.12))
		pulse.toValue = NSValue(caTransform3D: CATransform3DIdentity)
		pulse.duration = pulse.settlingDuration
		layer.add(pulse, forKey: "pulse")
	}
}

/// Draws a hint label centred in its bounds. Custom drawing keeps sizing exact; NSTextField's
/// own layout got squeezed when hosted as a glass effect view's content.
@MainActor
private final class BrowserLinkHintLabelView: NSView {
	var attributedString = NSAttributedString() {
		didSet { needsDisplay = true }
	}

	override var isFlipped: Bool { true }

	override func hitTest(_ point: NSPoint) -> NSView? {
		nil
	}

	override func draw(_ dirtyRect: NSRect) {
		let size = attributedString.size()
		let origin = CGPoint(
			x: (bounds.width - size.width) / 2,
			y: (bounds.height - size.height) / 2
		)
		attributedString.draw(at: origin)
	}
}

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
	private let springs = BrowserLinkHintSpringDriver()

	override init(frame frameRect: NSRect) {
		chipLayer = Self.makeChipContainer()
		super.init(frame: frameRect)
		wantsLayer = true
		layer?.masksToBounds = true
		chipLayer.frame = bounds
		chipLayer.autoresizingMask = [.width, .height]
		addSubview(chipLayer)
		springs.hostView = self
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

		let height = max(bounds.height, 1)
		for hint in hints {
			let chip = BrowserLinkHintChipView(label: hint.label, kind: hint.kind, springs: springs)
			let size = chip.fittingSize
			let targetRect = hint.pageRect.applying(CGAffineTransform(scaleX: scale, y: scale))
			chip.restingFrame = Self.chipFrame(size: size, targetRect: targetRect, bounds: bounds)
			chipParent.addSubview(chip)
			chipsByHintID[hint.id] = chip
			// Stagger top-to-bottom so the hints "rain" in instead of popping all at once.
			let delay = Double(min(max(chip.restingFrame.minY / height, 0), 1)) * 0.06
			chip.animateIn(delay: delay)
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
		// Glass ignores layer transforms, so shake by moving the container's frame: an
		// underdamped spring kicked with a sideways velocity, settling back at zero offset.
		let restingOrigin = bounds.origin
		springs.animate(
			key: ObjectIdentifier(chipLayer),
			from: 0,
			to: 0,
			initialVelocity: -420,
			response: 0.22,
			dampingRatio: 0.28
		) { [weak self] offset in
			guard let self else { return }
			self.chipLayer.frame.origin = CGPoint(x: restingOrigin.x + offset, y: restingOrigin.y)
		}
		NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
	}

	/// Plays the activation animation for `hintID`, then calls `completion`.
	func finish(activating hintID: Int, targetRect: CGRect, completion: @escaping @MainActor () -> Void) {
		guard isFinishing == false else { return }
		isFinishing = true
		for (id, chip) in chipsByHintID where id != hintID {
			chip.animateOut()
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
		chipsByHintID.values.forEach { $0.animateOut() }
		Task { @MainActor in
			try? await Task.sleep(for: .seconds(0.16))
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

/// A single hint label rendered on Liquid Glass (macOS 26+) or a dark blur material (macOS 15).
///
/// Glass is composited outside the view's own layer, so it ignores layer transforms and opacity.
/// All motion therefore animates the view's frame (scale about the centre) with a spring, and
/// hiding uses `isHidden`.
@MainActor
final class BrowserLinkHintChipView: NSView {
	private static let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .bold)
	private static let horizontalPadding: CGFloat = 6
	private static let verticalPadding: CGFloat = 2.5
	private static let cornerRadius: CGFloat = 7
	/// Dark tint so white labels stay readable on any page (about 9:1 on white).
	private static let glassTint = NSColor(white: 0.06, alpha: 0.62)
	private static let inputGlassTint = NSColor(srgbRed: 0.04, green: 0.22, blue: 0.55, alpha: 0.66)

	private let label: String
	private let textView = BrowserLinkHintLabelView()
	private let springs: BrowserLinkHintSpringDriver
	private var typedPrefixLength = 0
	private var isShown = true
	private var currentScale: CGFloat = 1

	/// Final, full-size frame. The visible frame is this rect scaled about its centre.
	var restingFrame: CGRect = .zero {
		didSet { applyScale(currentScale) }
	}

	init(label: String, kind: BrowserLinkHintTarget.Kind, springs: BrowserLinkHintSpringDriver) {
		self.label = label
		self.springs = springs
		super.init(frame: .zero)
		applyText()

		// Size from the measured string, not NSTextField's intrinsic size: inside
		// NSGlassEffectView the text field was laid out a few points wide and clipped.
		let textSize = textView.attributedString.size()
		let size = CGSize(
			width: max(ceil(textSize.width + Self.horizontalPadding * 2), ceil(textSize.height + Self.verticalPadding * 2)),
			height: ceil(textSize.height + Self.verticalPadding * 2)
		)
		frame = CGRect(origin: .zero, size: size)
		restingFrame = frame
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

	override var fittingSize: NSSize { restingFrame.size }

	override func hitTest(_ point: NSPoint) -> NSView? {
		nil
	}

	private static func makeBackground(kind: BrowserLinkHintTarget.Kind, size: CGSize, content: NSView) -> NSView {
		let tint = kind == .input ? inputGlassTint : glassTint
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
		blur.material = .hudWindow
		blur.appearance = NSAppearance(named: .darkAqua)
		blur.blendingMode = .withinWindow
		blur.state = .active
		blur.wantsLayer = true
		blur.layer?.cornerRadius = cornerRadius
		blur.layer?.cornerCurve = .continuous
		blur.layer?.masksToBounds = true
		blur.layer?.borderWidth = 0.5
		blur.layer?.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor
		let tintView = NSView(frame: CGRect(origin: .zero, size: size))
		tintView.wantsLayer = true
		tintView.layer?.backgroundColor = tint.cgColor
		tintView.autoresizingMask = [.width, .height]
		blur.addSubview(tintView)
		blur.addSubview(content)
		return blur
	}

	private func applyText() {
		let display = label.uppercased()
		let attributed = NSMutableAttributedString(
			string: display,
			attributes: [
				.font: Self.font,
				.foregroundColor: NSColor.white,
				.kern: 0.6,
			]
		)
		if typedPrefixLength > 0 {
			// Already-typed letters recede so the next letter to press stands out.
			attributed.addAttribute(
				.foregroundColor,
				value: NSColor.white.withAlphaComponent(0.38),
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
		if visible {
			animateIn(delay: 0)
		}
		else {
			animateOut()
		}
	}

	// MARK: Spring animations

	private func applyScale(_ scale: CGFloat) {
		currentScale = scale
		let size = CGSize(width: restingFrame.width * scale, height: restingFrame.height * scale)
		frame = CGRect(
			x: restingFrame.midX - size.width / 2,
			y: restingFrame.midY - size.height / 2,
			width: max(size.width, 0),
			height: max(size.height, 0)
		)
		textView.alphaValue = min(max((scale - 0.5) * 2, 0), 1)
	}

	private func animateScale(
		to target: CGFloat,
		from start: CGFloat? = nil,
		delay: TimeInterval = 0,
		response: CGFloat,
		dampingRatio: CGFloat,
		completion: (@MainActor () -> Void)? = nil
	) {
		springs.animate(
			key: ObjectIdentifier(self),
			from: start ?? currentScale,
			to: target,
			delay: delay,
			response: response,
			dampingRatio: dampingRatio,
			apply: { [weak self] value in self?.applyScale(value) },
			completion: completion
		)
	}

	func animateIn(delay: TimeInterval) {
		isShown = true
		isHidden = false
		applyScale(0.45)
		animateScale(to: 1, from: 0.45, delay: delay, response: 0.34, dampingRatio: 0.62)
	}

	func animateOut() {
		isShown = false
		animateScale(to: 0.4, response: 0.16, dampingRatio: 1) { [weak self] in
			guard let self, self.isShown == false else { return }
			self.isHidden = true
		}
	}

	func animateActivation() {
		isShown = false
		animateScale(to: 1.3, response: 0.18, dampingRatio: 0.7)
		Task { @MainActor [weak self] in
			try? await Task.sleep(for: .seconds(0.16))
			guard let self, self.isShown == false else { return }
			self.isHidden = true
		}
	}

	private func pulse() {
		applyScale(1.14)
		animateScale(to: 1, from: 1.14, response: 0.3, dampingRatio: 0.5)
	}
}

/// Minimal main-thread spring integrator for properties Core Animation cannot drive on glass
/// (view frames). Uses SwiftUI-style `response` / `dampingRatio` parameters.
///
/// Ticks on the host view's display link, so every step lands on a real frame. It used to run
/// on a 120 Hz `Timer`, which drifts against the display's refresh and skipped or doubled
/// frames, the "judder" in the hints popping in.
@MainActor
final class BrowserLinkHintSpringDriver: NSObject {
	/// The view whose display link drives the springs. Without one (no window yet) a timer is used.
	weak var hostView: NSView?

	private struct Spring {
		var value: CGFloat
		var velocity: CGFloat
		var target: CGFloat
		var startTime: CFTimeInterval
		var stiffness: CGFloat
		var damping: CGFloat
		var apply: @MainActor (CGFloat) -> Void
		var completion: (@MainActor () -> Void)?
	}

	private var springs = [ObjectIdentifier: Spring]()
	private var timer: Timer?
	private var displayLink: CADisplayLink?
	private var lastTick: CFTimeInterval = 0

	func animate(
		key: ObjectIdentifier,
		from start: CGFloat,
		to target: CGFloat,
		initialVelocity: CGFloat = 0,
		delay: TimeInterval = 0,
		response: CGFloat,
		dampingRatio: CGFloat,
		apply: @escaping @MainActor (CGFloat) -> Void,
		completion: (@MainActor () -> Void)? = nil
	) {
		let omega = 2 * CGFloat.pi / max(response, 0.01)
		springs[key] = Spring(
			value: start,
			velocity: initialVelocity,
			target: target,
			startTime: CACurrentMediaTime() + delay,
			stiffness: omega * omega,
			damping: 2 * dampingRatio * omega,
			apply: apply,
			completion: completion
		)
		apply(start)
		startTimerIfNeeded()
	}

	private func startTimerIfNeeded() {
		guard timer == nil, displayLink == nil else { return }
		lastTick = CACurrentMediaTime()
		if let hostView, hostView.window != nil {
			let link = hostView.displayLink(target: self, selector: #selector(displayLinkFired(_:)))
			link.add(to: .main, forMode: .common)
			displayLink = link
			return
		}
		let timer = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] timer in
			guard let self else {
				timer.invalidate()
				return
			}
			MainActor.assumeIsolated {
				self.tick()
			}
		}
		RunLoop.main.add(timer, forMode: .common)
		self.timer = timer
	}

	@objc private func displayLinkFired(_: CADisplayLink) {
		tick()
	}

	private func stopTicking() {
		timer?.invalidate()
		timer = nil
		displayLink?.invalidate()
		displayLink = nil
	}

	private func tick() {
		let now = CACurrentMediaTime()
		let frameDelta = min(CGFloat(now - lastTick), 1.0 / 30.0)
		lastTick = now
		var finished = [(@MainActor () -> Void)]()

		for (key, var spring) in springs {
			guard now >= spring.startTime else { continue }
			// Sub-step for stability with stiff springs.
			let steps = 4
			let dt = frameDelta / CGFloat(steps)
			for _ in 0..<steps {
				let force = -spring.stiffness * (spring.value - spring.target) - spring.damping * spring.velocity
				spring.velocity += force * dt
				spring.value += spring.velocity * dt
			}
			if abs(spring.velocity) < 0.01, abs(spring.value - spring.target) < 0.002 {
				spring.apply(spring.target)
				springs.removeValue(forKey: key)
				if let completion = spring.completion {
					finished.append(completion)
				}
			}
			else {
				spring.apply(spring.value)
				springs[key] = spring
			}
		}

		finished.forEach { $0() }
		if springs.isEmpty {
			stopTicking()
		}
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

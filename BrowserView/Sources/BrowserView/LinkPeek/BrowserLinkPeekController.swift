import AppKit
import BrowserRuntime
import QuartzCore

/// Experiment: Link Peek.
///
/// Option-click a link, or force-click it on a trackpad, and the link opens in a floating
/// Liquid Glass card over the page instead of navigating. Drag the card up (or flick it) to promote
/// it to a real tab; drag it down, press Esc, or click outside to dismiss it. ⌘↩ promotes from the keyboard.
@MainActor
final class BrowserLinkPeekController {
	struct Dependencies {
		/// The runtime that owns the page browsers and creates the preview browser.
		var browserRuntime: any BrowserRuntimeDriving
		/// The browser of the selected tab, which is the page that gets hit tested.
		var selectedBrowser: @MainActor () -> CEFBridgeBrowserRef?
		/// Opens a URL as a new foreground tab.
		var openInNewTab: @MainActor (String) -> Void
		/// Whether the experiment is switched on right now.
		var isEnabled: @MainActor () -> Bool
	}

	private enum Spring {
		static let present = (mass: CGFloat(1), stiffness: CGFloat(260), damping: CGFloat(24))
		static let settle = (mass: CGFloat(1), stiffness: CGFloat(380), damping: CGFloat(30))
		static let promote = (mass: CGFloat(1), stiffness: CGFloat(300), damping: CGFloat(32))
	}

	private enum TransformKey {
		static let card = "navigator.linkPeek.transform"
		static let opacity = "navigator.linkPeek.opacity"
		static let backdrop = "navigator.linkPeek.backdrop"
	}

	private static let backdropOpacity: Float = 0.22
	private static let forceClickStage = 2
	private static let hitTestTimeout: Duration = .milliseconds(500)

	private let dependencies: Dependencies
	private weak var hostView: NSView?
	private weak var overlayParent: NSView?
	private var eventMonitor: Any?

	private var overlayView: BrowserLinkPeekOverlayView?
	private var cardView: BrowserLinkPeekCardView?
	private var previewContainer: BrowserContainerView?
	private var currentURL: String?
	private var currentTitle: String?
	private var isClosing = false
	private var lastPressureStage = 0
	private var dragStartTransform = CATransform3DIdentity
	private var didCrossPromoteThreshold = false

	/// The option-click we held back from the page while asking it whether a link is under the pointer.
	/// If there is no link, the click is replayed so the page still gets it.
	private var pendingClick: (down: NSEvent, up: NSEvent?)?
	private var hitTestGeneration = 0

	var isPresented: Bool {
		cardView != nil && isClosing == false
	}

	init(dependencies: Dependencies) {
		self.dependencies = dependencies
	}

	/// - Parameters:
	///   - hostView: the view that hosts the page browsers; hit testing is relative to its bounds.
	///   - overlayParent: the view the card overlay is added to, above `hostView`.
	func attach(hostView: NSView, overlayParent: NSView) {
		self.hostView = hostView
		self.overlayParent = overlayParent
		guard eventMonitor == nil else { return }
		eventMonitor = NSEvent.addLocalMonitorForEvents(
			matching: [.leftMouseDown, .leftMouseUp, .pressure, .keyDown]
		) { [weak self] event in
			guard let self else { return event }
			return self.handle(event)
		}
	}

	func detach() {
		if let eventMonitor {
			NSEvent.removeMonitor(eventMonitor)
		}
		eventMonitor = nil
		pendingClick = nil
		dismiss(animated: false)
	}

	// MARK: - Event routing

	private func handle(_ event: NSEvent) -> NSEvent? {
		switch event.type {
		case .keyDown:
			return handleKeyDown(event)
		case .leftMouseDown:
			return handleMouseDown(event)
		case .leftMouseUp:
			return handleMouseUp(event)
		case .pressure:
			handlePressure(event)
			return event
		default:
			return event
		}
	}

	private func handleKeyDown(_ event: NSEvent) -> NSEvent? {
		guard isPresented, event.window === hostView?.window else { return event }
		let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
		switch event.keyCode {
		case 53: // Esc
			dismiss(animated: true)
			return nil
		case 36 where modifiers == .command, 76 where modifiers == .command: // ⌘↩
			promote(velocity: 0)
			return nil
		default:
			return event
		}
	}

	private func handleMouseDown(_ event: NSEvent) -> NSEvent? {
		guard dependencies.isEnabled(), isPresented == false, pendingClick == nil else { return event }
		let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
		guard modifiers == .option, event.clickCount == 1 else { return event }
		guard let point = pagePoint(for: event) else { return event }
		pendingClick = (event, nil)
		hitTest(at: point, replayingClickIfMissed: true)
		return nil
	}

	private func handleMouseUp(_ event: NSEvent) -> NSEvent? {
		guard let pendingClick, pendingClick.up == nil, event.window === pendingClick.down.window else { return event }
		self.pendingClick = (pendingClick.down, event)
		return nil
	}

	private func handlePressure(_ event: NSEvent) {
		let stage = event.stage
		defer { lastPressureStage = stage }
		guard stage >= Self.forceClickStage, lastPressureStage < Self.forceClickStage else { return }
		guard dependencies.isEnabled(), isPresented == false, pendingClick == nil else { return }
		guard let point = pagePoint(for: event) else { return }
		hitTest(at: point, replayingClickIfMissed: false)
	}

	/// The event location as a viewport-normalized point, or nil when the event is not on the page.
	private func pagePoint(for event: NSEvent) -> CGPoint? {
		guard let hostView, let window = hostView.window, event.window === window, hostView.isHiddenOrHasHiddenAncestor == false
		else { return nil }
		// Only peek when the page itself is under the pointer, not chrome floating above it.
		if let contentView = window.contentView {
			let pointInContentSuperview = contentView.superview?.convert(event.locationInWindow, from: nil) ?? event.locationInWindow
			guard let hit = contentView.hitTest(pointInContentSuperview), hit.isDescendant(of: hostView) else { return nil }
		}
		let local = hostView.convert(event.locationInWindow, from: nil)
		return BrowserLinkPeekGeometry.normalizedPoint(for: local, in: hostView.bounds, isFlipped: hostView.isFlipped)
	}

	private func hitTest(at point: CGPoint, replayingClickIfMissed: Bool) {
		guard let browser = dependencies.selectedBrowser() else {
			if replayingClickIfMissed { replayPendingClick() }
			return
		}
		hitTestGeneration += 1
		let generation = hitTestGeneration
		if replayingClickIfMissed {
			// If the renderer is slow or hung, give the click back to the page instead of eating it.
			Task { @MainActor [weak self] in
				try? await Task.sleep(for: Self.hitTestTimeout)
				guard let self, generation == self.hitTestGeneration, self.pendingClick != nil else { return }
				self.hitTestGeneration += 1
				self.replayPendingClick()
			}
		}
		dependencies.browserRuntime.evaluateJavaScriptInRendererWithResult(
			browser,
			script: BrowserLinkPeekHitTest.script(fx: point.x, fy: point.y)
		) { [weak self] result, _ in
			guard let self, generation == self.hitTestGeneration else { return }
			guard let link = BrowserLinkPeekHitTest.parse(result) else {
				if replayingClickIfMissed { self.replayPendingClick() }
				return
			}
			self.pendingClick = nil
			self.present(link)
		}
	}

	private func replayPendingClick() {
		guard let pendingClick else { return }
		self.pendingClick = nil
		guard let window = pendingClick.down.window else { return }
		// sendEvent bypasses local monitors, so the replay is not caught again.
		window.sendEvent(pendingClick.down)
		if let up = pendingClick.up {
			window.sendEvent(up)
		}
	}

	// MARK: - Presentation

	private func present(_ link: BrowserLinkPeekHitTest.Link) {
		guard let hostView, let overlayParent, isPresented == false else { return }
		if cardView != nil {
			// A previous card is still animating out; drop it immediately.
			tearDown()
		}

		let overlay = BrowserLinkPeekOverlayView(frame: overlayParent.convert(hostView.bounds, from: hostView))
		overlay.autoresizingMask = [.width, .height]
		overlay.onBackdropClick = { [weak self] in
			self?.dismiss(animated: true)
		}
		overlayParent.addSubview(overlay, positioned: .above, relativeTo: nil)

		let cardFrame = BrowserLinkPeekGeometry.cardFrame(in: overlay.bounds)
		let card = BrowserLinkPeekCardView(frame: cardFrame)
		card.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin, .maxYMargin]
		card.setTitle(link.title, url: link.url)
		card.onOpenAsTab = { [weak self] in
			self?.promote(velocity: 0)
		}
		card.onClose = { [weak self] in
			self?.dismiss(animated: true)
		}
		card.onDrag = { [weak self] phase in
			self?.handleDrag(phase)
		}
		overlay.addSubview(card)
		overlay.layoutSubtreeIfNeeded()

		let preview = BrowserContainerView(initialURL: link.url, browserRuntime: dependencies.browserRuntime)
		preview.onBrowserCreated = { [weak self] browser in
			self?.bindPreviewBrowser(browser)
		}
		card.contentContainer.addSubview(preview)
		NSLayoutConstraint.activate([
			preview.topAnchor.constraint(equalTo: card.contentContainer.topAnchor),
			preview.leadingAnchor.constraint(equalTo: card.contentContainer.leadingAnchor),
			preview.trailingAnchor.constraint(equalTo: card.contentContainer.trailingAnchor),
			preview.bottomAnchor.constraint(equalTo: card.contentContainer.bottomAnchor),
		])

		overlayView = overlay
		cardView = card
		previewContainer = preview
		currentURL = link.url
		currentTitle = link.title
		isClosing = false

		let linkRect = link.normalizedRect.map {
			overlay.convert(
				BrowserLinkPeekGeometry.viewRect(for: $0, in: hostView.bounds, isFlipped: hostView.isFlipped),
				from: hostView
			)
		}
		animateIn(card: card, overlay: overlay, from: linkRect)
		NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
	}

	private func bindPreviewBrowser(_ browser: CEFBridgeBrowserRef) {
		let runtime = dependencies.browserRuntime
		runtime.setAddressChangeHandler(for: browser) { [weak self] url in
			guard let self, url.isEmpty == false, url != BrowserContainerState.blankPageURL else { return }
			self.currentURL = url
			self.cardView?.setTitle(self.currentTitle, url: url)
		}
		runtime.setTitleChangeHandler(for: browser) { [weak self] title in
			guard let self else { return }
			self.currentTitle = title
			self.cardView?.setTitle(title, url: self.currentURL ?? "")
		}
		// Links the preview wants to open in a new tab or window become real tabs.
		runtime.setOpenURLInTabHandler(for: browser) { [weak self] event in
			self?.dependencies.openInNewTab(event.url)
		}
	}

	private func animateIn(card: BrowserLinkPeekCardView, overlay: BrowserLinkPeekOverlayView, from linkRect: CGRect?) {
		guard let cardLayer = card.layer else { return }
		let start = BrowserLinkPeekGeometry.originTransform(card: card.frame, linkRect: linkRect)
		spring(cardLayer, to: CATransform3DIdentity, from: start, velocity: 0, parameters: Spring.present)
		fade(cardLayer, to: 1, from: 0, duration: 0.18, key: TransformKey.opacity)
		overlay.setBackdropOpacity(Self.backdropOpacity, animatedFrom: 0, duration: 0.25)
	}

	func dismiss(animated: Bool) {
		guard let card = cardView, let overlay = overlayView, isClosing == false else { return }
		isClosing = true
		previewContainer?.discardBrowser(stopLoad: true)
		guard animated, let cardLayer = card.layer else {
			tearDown()
			return
		}
		let current = cardLayer.presentation()?.transform ?? cardLayer.transform
		let end = BrowserLinkPeekGeometry.transform(
			scale: 0.9,
			translation: CGPoint(x: 0, y: -60),
			size: card.bounds.size
		)
		let duration = spring(cardLayer, to: end, from: current, velocity: 0, parameters: Spring.settle)
		fade(cardLayer, to: 0, from: Float(cardLayer.presentation()?.opacity ?? 1), duration: 0.16, key: TransformKey.opacity)
		overlay.setBackdropOpacity(0, animatedFrom: Self.backdropOpacity, duration: 0.2)
		scheduleTearDown(after: min(duration, 0.35))
	}

	private func promote(velocity: CGFloat) {
		guard let card = cardView, let overlay = overlayView, let cardLayer = card.layer, isClosing == false else { return }
		let url = currentURL
		isClosing = true
		NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)

		// Grow the card to fill the page, open the tab underneath it, then let the card dissolve
		// into the freshly opened tab.
		let current = cardLayer.presentation()?.transform ?? cardLayer.transform
		let fill = BrowserLinkPeekGeometry.transform(from: card.frame, to: overlay.bounds)
		let distance = max(1, overlay.bounds.maxY - card.frame.maxY)
		let duration = spring(
			cardLayer,
			to: fill,
			from: current,
			velocity: velocity / distance,
			parameters: Spring.promote
		)
		overlay.setBackdropOpacity(0, animatedFrom: Self.backdropOpacity, duration: 0.2)

		if let url {
			dependencies.openInNewTab(url)
		}
		Task { @MainActor [weak self] in
			try? await Task.sleep(for: .seconds(min(duration, 0.32)))
			guard let self, self.cardView === card else { return }
			self.previewContainer?.discardBrowser(stopLoad: true)
			self.fade(cardLayer, to: 0, from: 1, duration: 0.18, key: TransformKey.opacity)
			self.scheduleTearDown(after: 0.18)
		}
	}

	private func scheduleTearDown(after delay: TimeInterval) {
		let card = cardView
		Task { @MainActor [weak self] in
			try? await Task.sleep(for: .seconds(delay))
			guard let self, self.cardView === card else { return }
			self.tearDown()
		}
	}

	private func tearDown() {
		previewContainer?.discardBrowser(stopLoad: true)
		previewContainer?.removeFromSuperview()
		cardView?.removeFromSuperview()
		overlayView?.removeFromSuperview()
		previewContainer = nil
		cardView = nil
		overlayView = nil
		currentURL = nil
		currentTitle = nil
		isClosing = false
		didCrossPromoteThreshold = false
	}

	// MARK: - Drag

	private func handleDrag(_ phase: BrowserLinkPeekCardView.DragPhase) {
		guard let card = cardView, let cardLayer = card.layer, isClosing == false else { return }
		let height = card.bounds.height
		switch phase {
		case .began:
			// Catch the card mid-animation: continue from wherever it is on screen.
			let current = cardLayer.presentation()?.transform ?? cardLayer.transform
			cardLayer.removeAnimation(forKey: TransformKey.card)
			setTransform(current, on: cardLayer)
			dragStartTransform = current
			didCrossPromoteThreshold = false

		case let .changed(translation):
			let x = BrowserLinkPeekGeometry.rubberBand(translation.x, limit: 40)
			let y = translation.y > 0
				? BrowserLinkPeekGeometry.rubberBand(translation.y, limit: height * 0.6)
				: translation.y
			// Lifting the card grows it a little, as a preview of becoming the page.
			let progress = BrowserLinkPeekGeometry.promoteProgress(translation: translation.y, cardHeight: height)
			let scale = 1 + 0.04 * progress - (translation.y < 0 ? min(0.08, -translation.y / height * 0.2) : 0)
			let drag = BrowserLinkPeekGeometry.transform(scale: scale, translation: CGPoint(x: x, y: y), size: card.bounds.size)
			setTransform(CATransform3DConcat(dragStartTransform, drag), on: cardLayer)
			card.setPromoteProgress(progress)
			overlayView?.setBackdropOpacity(
				Self.backdropOpacity * Float(translation.y < 0 ? max(0, 1 + translation.y / height) : 1)
			)
			let crossed = progress >= 1
			if crossed != didCrossPromoteThreshold {
				didCrossPromoteThreshold = crossed
				NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
			}

		case let .ended(translation, velocity):
			card.setPromoteProgress(0)
			switch BrowserLinkPeekGeometry.releaseOutcome(translation: translation.y, velocity: velocity.y, cardHeight: height) {
			case .promote:
				promote(velocity: velocity.y)
			case .dismiss:
				dismiss(animated: true)
			case .settle:
				let current = cardLayer.transform
				let distance = max(1, abs(translation.y))
				spring(cardLayer, to: CATransform3DIdentity, from: current, velocity: -velocity.y / distance, parameters: Spring.settle)
				overlayView?.setBackdropOpacity(Self.backdropOpacity)
			}
		}
	}

	// MARK: - Animation helpers

	private func setTransform(_ transform: CATransform3D, on layer: CALayer) {
		CATransaction.begin()
		CATransaction.setDisableActions(true)
		layer.transform = transform
		CATransaction.commit()
	}

	@discardableResult
	private func spring(
		_ layer: CALayer,
		to target: CATransform3D,
		from start: CATransform3D,
		velocity: CGFloat,
		parameters: (mass: CGFloat, stiffness: CGFloat, damping: CGFloat)
	) -> TimeInterval {
		let animation = CASpringAnimation(keyPath: "transform")
		animation.mass = parameters.mass
		animation.stiffness = parameters.stiffness
		animation.damping = parameters.damping
		animation.initialVelocity = velocity.isFinite ? velocity : 0
		animation.fromValue = NSValue(caTransform3D: start)
		animation.toValue = NSValue(caTransform3D: target)
		animation.duration = animation.settlingDuration
		animation.isRemovedOnCompletion = true
		layer.removeAnimation(forKey: TransformKey.card)
		setTransform(target, on: layer)
		layer.add(animation, forKey: TransformKey.card)
		return animation.duration
	}

	private func fade(_ layer: CALayer, to target: Float, from start: Float, duration: TimeInterval, key: String) {
		let animation = CABasicAnimation(keyPath: "opacity")
		animation.fromValue = start
		animation.toValue = target
		animation.duration = duration
		animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
		CATransaction.begin()
		CATransaction.setDisableActions(true)
		layer.opacity = target
		CATransaction.commit()
		layer.add(animation, forKey: key)
	}
}

/// Full-page overlay behind the card: dims the page a little and dismisses the card on click.
@MainActor
final class BrowserLinkPeekOverlayView: NSView {
	var onBackdropClick: (() -> Void)?
	private let backdropLayer = CALayer()

	override init(frame frameRect: NSRect) {
		super.init(frame: frameRect)
		wantsLayer = true
		backdropLayer.backgroundColor = NSColor.black.cgColor
		backdropLayer.opacity = 0
		layer?.addSublayer(backdropLayer)
	}

	@available(*, unavailable)
	required init?(coder: NSCoder) {
		fatalError("init(coder:) has not been implemented")
	}

	override var mouseDownCanMoveWindow: Bool {
		false
	}

	override func layout() {
		super.layout()
		CATransaction.begin()
		CATransaction.setDisableActions(true)
		backdropLayer.frame = bounds
		CATransaction.commit()
	}

	override func mouseDown(with event: NSEvent) {
		onBackdropClick?()
	}

	override func rightMouseDown(with event: NSEvent) {
		onBackdropClick?()
	}

	/// Keep the page underneath from scrolling while the card is up.
	override func scrollWheel(with event: NSEvent) {}

	func setBackdropOpacity(_ opacity: Float, animatedFrom start: Float? = nil, duration: TimeInterval = 0) {
		CATransaction.begin()
		CATransaction.setDisableActions(true)
		backdropLayer.opacity = opacity
		CATransaction.commit()
		guard let start, duration > 0 else { return }
		let animation = CABasicAnimation(keyPath: "opacity")
		animation.fromValue = start
		animation.toValue = opacity
		animation.duration = duration
		animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
		backdropLayer.add(animation, forKey: "navigator.linkPeek.backdrop")
	}
}

import AppKit

/// Experiment: Link Peek. The floating card: a Liquid Glass shell (blur material before macOS 26)
/// with a header, a grabber, and a slot for the live preview browser.
@MainActor
final class BrowserLinkPeekCardView: NSView {
	enum DragPhase {
		case began
		case changed(translation: CGPoint)
		case ended(translation: CGPoint, velocity: CGPoint)
	}

	var onDrag: ((DragPhase) -> Void)?
	var onOpenAsTab: (() -> Void)?
	var onClose: (() -> Void)?

	let contentContainer = NSView()
	private let backgroundView: NSView
	private let dragSurface = BrowserLinkPeekDragSurfaceView()
	private let grabber = NSView()
	private let titleLabel = BrowserLinkPeekPassthroughLabel(labelWithString: "")
	private let hostLabel = BrowserLinkPeekPassthroughLabel(labelWithString: "")
	private let hintLabel = BrowserLinkPeekPassthroughLabel(labelWithString: "")
	private let openButton = NSButton()
	private let closeButton = NSButton()
	private lazy var titleCenterConstraint = titleLabel.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor)

	override init(frame frameRect: NSRect) {
		backgroundView = BrowserLinkPeekCardView.makeBackgroundView()
		super.init(frame: frameRect)
		wantsLayer = true
		layer?.cornerRadius = BrowserLinkPeekGeometry.cardCornerRadius
		layer?.cornerCurve = .continuous
		layer?.shadowColor = NSColor.black.cgColor
		layer?.shadowOpacity = 0.28
		layer?.shadowRadius = 30
		layer?.shadowOffset = CGSize(width: 0, height: -12)
		layer?.masksToBounds = false
		buildHierarchy()
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
		// An explicit shadow path. Without one Core Animation derives the 30pt shadow from the
		// alpha of every sublayer (glass, live web content) on every frame, offscreen, which is
		// what made the card stutter while it sprang in, was dragged, or flew out.
		let radius = BrowserLinkPeekGeometry.cardCornerRadius
		CATransaction.begin()
		CATransaction.setDisableActions(true)
		layer?.shadowPath = CGPath(
			roundedRect: bounds,
			cornerWidth: min(radius, bounds.width / 2),
			cornerHeight: min(radius, bounds.height / 2),
			transform: nil
		)
		CATransaction.commit()
	}

	func setTitle(_ title: String?, url: String) {
		let host = URL(string: url)?.host(percentEncoded: false) ?? url
		let trimmedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
		titleLabel.stringValue = trimmedTitle.isEmpty ? host : trimmedTitle
		hostLabel.stringValue = trimmedTitle.isEmpty ? "" : host
		hostLabel.isHidden = hostLabel.stringValue.isEmpty
		// Two lines (title over host) sit centered on the buttons; a lone title centers on them.
		titleCenterConstraint.constant = hostLabel.isHidden ? 0 : -7
	}

	/// Drives the "release to open" hint while the card is dragged up. 0 hides it, 1 means releasing promotes.
	func setPromoteProgress(_ progress: CGFloat) {
		let clamped = min(max(progress, 0), 1)
		hintLabel.alphaValue = clamped
		hintLabel.stringValue = clamped >= 1
			? String(localized: "Release to open in a new tab", bundle: .module)
			: String(localized: "Drag up to open in a new tab", bundle: .module)
		grabber.layer?.backgroundColor = (clamped >= 1 ? NSColor.controlAccentColor : NSColor.tertiaryLabelColor).cgColor
	}

	private func buildHierarchy() {
		for subview in [backgroundView, dragSurface, contentContainer, grabber, titleLabel, hostLabel, hintLabel, openButton, closeButton] {
			subview.translatesAutoresizingMaskIntoConstraints = false
			addSubview(subview)
		}

		dragSurface.onDrag = { [weak self] phase in
			self?.onDrag?(phase)
		}

		contentContainer.wantsLayer = true
		contentContainer.layer?.cornerRadius = BrowserLinkPeekGeometry.contentCornerRadius
		contentContainer.layer?.cornerCurve = .continuous
		contentContainer.layer?.masksToBounds = true
		contentContainer.layer?.backgroundColor = NSColor.textBackgroundColor.cgColor

		grabber.wantsLayer = true
		grabber.layer?.cornerRadius = 2.5
		grabber.layer?.backgroundColor = NSColor.tertiaryLabelColor.cgColor

		titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
		titleLabel.textColor = .labelColor
		titleLabel.lineBreakMode = .byTruncatingTail
		titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

		hostLabel.font = .systemFont(ofSize: 11, weight: .regular)
		hostLabel.textColor = .secondaryLabelColor
		hostLabel.lineBreakMode = .byTruncatingMiddle
		hostLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

		hintLabel.font = .systemFont(ofSize: 11, weight: .medium)
		hintLabel.textColor = .secondaryLabelColor
		hintLabel.alignment = .center
		hintLabel.alphaValue = 0

		configure(
			openButton,
			symbol: "arrow.up.forward.square",
			label: String(localized: "Open in New Tab", bundle: .module),
			action: #selector(openTapped)
		)
		configure(
			closeButton,
			symbol: "xmark.circle.fill",
			label: String(localized: "Close Preview", bundle: .module),
			action: #selector(closeTapped)
		)

		let inset = BrowserLinkPeekGeometry.contentInset
		let header = BrowserLinkPeekGeometry.headerHeight
		NSLayoutConstraint.activate([
			backgroundView.topAnchor.constraint(equalTo: topAnchor),
			backgroundView.leadingAnchor.constraint(equalTo: leadingAnchor),
			backgroundView.trailingAnchor.constraint(equalTo: trailingAnchor),
			backgroundView.bottomAnchor.constraint(equalTo: bottomAnchor),

			dragSurface.topAnchor.constraint(equalTo: topAnchor),
			dragSurface.leadingAnchor.constraint(equalTo: leadingAnchor),
			dragSurface.trailingAnchor.constraint(equalTo: trailingAnchor),
			dragSurface.bottomAnchor.constraint(equalTo: bottomAnchor),

			grabber.topAnchor.constraint(equalTo: topAnchor, constant: 6),
			grabber.centerXAnchor.constraint(equalTo: centerXAnchor),
			grabber.widthAnchor.constraint(equalToConstant: 36),
			grabber.heightAnchor.constraint(equalToConstant: 5),

			closeButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset + 6),
			closeButton.centerYAnchor.constraint(equalTo: topAnchor, constant: header / 2 + 3),
			closeButton.widthAnchor.constraint(equalToConstant: 22),
			closeButton.heightAnchor.constraint(equalToConstant: 22),

			openButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -(inset + 6)),
			openButton.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor),
			openButton.widthAnchor.constraint(equalToConstant: 22),
			openButton.heightAnchor.constraint(equalToConstant: 22),

			titleLabel.leadingAnchor.constraint(equalTo: closeButton.trailingAnchor, constant: 10),
			titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: hintLabel.leadingAnchor, constant: -8),
			titleCenterConstraint,

			hostLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
			hostLabel.trailingAnchor.constraint(lessThanOrEqualTo: hintLabel.leadingAnchor, constant: -8),
			hostLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 0),

			hintLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
			hintLabel.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor),
			hintLabel.trailingAnchor.constraint(lessThanOrEqualTo: openButton.leadingAnchor, constant: -8),

			contentContainer.topAnchor.constraint(equalTo: topAnchor, constant: header),
			contentContainer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
			contentContainer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
			contentContainer.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -inset),
		])
	}

	private func configure(_ button: NSButton, symbol: String, label: String, action: Selector) {
		button.bezelStyle = .regularSquare
		button.isBordered = false
		button.imagePosition = .imageOnly
		button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
		button.symbolConfiguration = .init(pointSize: 16, weight: .medium)
		button.contentTintColor = .secondaryLabelColor
		button.toolTip = label
		button.setAccessibilityLabel(label)
		button.target = self
		button.action = action
	}

	@objc private func openTapped() {
		onOpenAsTab?()
	}

	@objc private func closeTapped() {
		onClose?()
	}

	private static func makeBackgroundView() -> NSView {
		if #available(macOS 26.0, *) {
			let glass = NSGlassEffectView()
			glass.cornerRadius = BrowserLinkPeekGeometry.cardCornerRadius
			return glass
		}
		let material = NSVisualEffectView()
		material.material = .hudWindow
		material.blendingMode = .withinWindow
		material.state = .active
		material.wantsLayer = true
		material.layer?.cornerRadius = BrowserLinkPeekGeometry.cardCornerRadius
		material.layer?.cornerCurve = .continuous
		material.layer?.masksToBounds = true
		return material
	}
}

/// Transparent view behind the header and the rim of the card that turns mouse drags into card drags.
/// The web content and the buttons sit above it, so they keep their own clicks.
@MainActor
final class BrowserLinkPeekDragSurfaceView: NSView {
	var onDrag: ((BrowserLinkPeekCardView.DragPhase) -> Void)?
	private var startLocation: CGPoint?
	private var samples: [(time: TimeInterval, location: CGPoint)] = []

	override var mouseDownCanMoveWindow: Bool {
		false
	}

	override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
		true
	}

	override func mouseDown(with event: NSEvent) {
		let location = event.locationInWindow
		startLocation = location
		samples = [(event.timestamp, location)]
		onDrag?(.began)
	}

	override func mouseDragged(with event: NSEvent) {
		guard let startLocation else { return }
		let location = event.locationInWindow
		record(time: event.timestamp, location: location)
		onDrag?(.changed(translation: CGPoint(x: location.x - startLocation.x, y: location.y - startLocation.y)))
	}

	override func mouseUp(with event: NSEvent) {
		guard let startLocation else { return }
		let location = event.locationInWindow
		record(time: event.timestamp, location: location)
		let translation = CGPoint(x: location.x - startLocation.x, y: location.y - startLocation.y)
		onDrag?(.ended(translation: translation, velocity: velocity()))
		self.startLocation = nil
		samples.removeAll()
	}

	private func record(time: TimeInterval, location: CGPoint) {
		samples.append((time, location))
		// Keep only the last ~100 ms, which is what the release velocity should reflect.
		samples.removeAll { time - $0.time > 0.1 }
	}

	private func velocity() -> CGPoint {
		guard let first = samples.first, let last = samples.last else { return .zero }
		let elapsed = last.time - first.time
		guard elapsed > 0.001 else { return .zero }
		return CGPoint(
			x: (last.location.x - first.location.x) / elapsed,
			y: (last.location.y - first.location.y) / elapsed
		)
	}
}

/// A label that never takes mouse events, so drags on it reach the drag surface underneath.
final class BrowserLinkPeekPassthroughLabel: NSTextField {
	override func hitTest(_ point: NSPoint) -> NSView? {
		nil
	}
}

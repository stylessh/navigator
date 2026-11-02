import AppKit
import BrowserSidebar
import Vendors

struct SpatialOverviewItem: Equatable {
	var id: BrowserTabID
	var title: String
	var url: String
	var snapshot: CGImage?
	var isSelected: Bool
	var isInSplit: Bool

	var host: String {
		URL(string: url)?.host()?.replacingOccurrences(of: "www.", with: "") ?? url
	}
}

@MainActor
final class SpatialTabOverviewCardView: NSView {
	static let cornerRadius: CGFloat = 14

	private(set) var item: SpatialOverviewItem
	var captionHeight: CGFloat = 30
	var onClose: ((BrowserTabID) -> Void)?

	lazy var frameSpring = SpatialFrameSpring(view: self)
	private lazy var liftSpring = SpatialValueSpring(initial: 1) { [weak self] scale in
		self?.spatialApplyScale(scale)
	}
	private lazy var alphaSpring = SpatialValueSpring(initial: 1) { [weak self] alpha in
		self?.alphaValue = alpha
	}

	private let thumbnailView = NSView()
	private let thumbnailLayer = CALayer()
	private let placeholderLabel = NSTextField(labelWithString: "")
	private let titleLabel = NSTextField(labelWithString: "")
	private let hostLabel = NSTextField(labelWithString: "")
	private let closeButton = NSButton()
	private let splitBadge = NSImageView()
	private var trackingArea: NSTrackingArea?

	var isHighlighted = false {
		didSet { updateSelectionRing() }
	}

	private(set) var isHovered = false

	var isLifted = false {
		didSet {
			guard oldValue != isLifted else { return }
			layer?.zPosition = isLifted ? 100 : 0
			liftSpring.animate(to: isLifted ? 1.06 : (isHovered ? 1.025 : 1), spring: SpatialMotion.lift)
			updateShadow()
		}
	}

	override var isFlipped: Bool {
		true
	}

	init(item: SpatialOverviewItem) {
		self.item = item
		super.init(frame: .zero)
		wantsLayer = true
		layer?.masksToBounds = false
		build()
		update(item: item)
	}

	@available(*, unavailable)
	required init?(coder: NSCoder) {
		fatalError("init(coder:) has not been implemented")
	}

	private func build() {
		thumbnailView.wantsLayer = true
		thumbnailView.layer?.cornerRadius = Self.cornerRadius
		thumbnailView.layer?.cornerCurve = .continuous
		thumbnailView.layer?.masksToBounds = true
		thumbnailView.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
		thumbnailView.layer?.borderWidth = 0
		thumbnailLayer.contentsGravity = .resizeAspectFill
		thumbnailLayer.masksToBounds = true
		thumbnailView.layer?.addSublayer(thumbnailLayer)
		addSubview(thumbnailView)

		placeholderLabel.font = .systemFont(ofSize: 34, weight: .semibold)
		placeholderLabel.textColor = .tertiaryLabelColor
		placeholderLabel.alignment = .center
		thumbnailView.addSubview(placeholderLabel)

		titleLabel.font = .systemFont(ofSize: 12, weight: .medium)
		titleLabel.textColor = .labelColor
		titleLabel.lineBreakMode = .byTruncatingTail
		titleLabel.maximumNumberOfLines = 1
		addSubview(titleLabel)

		hostLabel.font = .systemFont(ofSize: 11, weight: .regular)
		hostLabel.textColor = .secondaryLabelColor
		hostLabel.lineBreakMode = .byTruncatingTail
		hostLabel.maximumNumberOfLines = 1
		addSubview(hostLabel)

		closeButton.bezelStyle = .circular
		closeButton.isBordered = false
		closeButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Close tab")
		closeButton.contentTintColor = .secondaryLabelColor
		closeButton.symbolConfiguration = .init(pointSize: 18, weight: .semibold)
		closeButton.target = self
		closeButton.action = #selector(closeTapped)
		closeButton.alphaValue = 0
		closeButton.setAccessibilityLabel("Close tab")
		addSubview(closeButton)

		splitBadge.image = NSImage(systemSymbolName: "rectangle.split.2x1", accessibilityDescription: "In split view")
		splitBadge.contentTintColor = .controlAccentColor
		splitBadge.symbolConfiguration = .init(pointSize: 11, weight: .semibold)
		addSubview(splitBadge)

		setAccessibilityElement(true)
		setAccessibilityRole(.button)
	}

	func update(item: SpatialOverviewItem) {
		self.item = item
		titleLabel.stringValue = item.title.isEmpty ? item.host : item.title
		hostLabel.stringValue = item.host
		thumbnailLayer.contents = item.snapshot
		updateThumbnailGravity()
		placeholderLabel.isHidden = item.snapshot != nil
		placeholderLabel.stringValue = item.host.first.map { String($0).uppercased() } ?? "•"
		splitBadge.isHidden = item.isInSplit == false
		setAccessibilityLabel(titleLabel.stringValue)
		updateSelectionRing()
	}

	func animateAlpha(to alpha: CGFloat, spring: Spring = SpatialMotion.reflow, completion: (@MainActor () -> Void)? = nil) {
		alphaSpring.animate(to: alpha, spring: spring, completion: completion)
	}

	func setAlpha(_ alpha: CGFloat) {
		alphaSpring.set(alpha)
	}

	func setScale(_ scale: CGFloat) {
		liftSpring.set(scale)
	}

	func animateScale(to scale: CGFloat, spring: Spring) {
		liftSpring.animate(to: scale, spring: spring)
	}

	/// The thumbnail rect inside a card of the given size.
	static func thumbnailRect(cardSize: CGSize, captionHeight: CGFloat) -> CGRect {
		CGRect(x: 0, y: 0, width: cardSize.width, height: max(cardSize.height - captionHeight, 0))
	}

	/// The card frame whose thumbnail exactly covers `rect`; used to zoom a card to and from the live page.
	static func cardFrame(coveringThumbnail rect: CGRect, captionHeight: CGFloat) -> CGRect {
		CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height + captionHeight)
	}

	override func layout() {
		super.layout()
		let thumbnailRect = Self.thumbnailRect(cardSize: bounds.size, captionHeight: captionHeight)
		thumbnailView.frame = thumbnailRect
		CATransaction.begin()
		CATransaction.setDisableActions(true)
		thumbnailLayer.frame = thumbnailView.bounds
		CATransaction.commit()
		updateThumbnailGravity()
		placeholderLabel.sizeToFit()
		placeholderLabel.frame.origin = CGPoint(
			x: (thumbnailRect.width - placeholderLabel.frame.width) / 2,
			y: (thumbnailRect.height - placeholderLabel.frame.height) / 2
		)

		let captionY = thumbnailRect.maxY + 6
		let badgeWidth: CGFloat = item.isInSplit ? 18 : 0
		splitBadge.frame = CGRect(x: 2, y: captionY + 1, width: badgeWidth, height: 14)
		titleLabel.frame = CGRect(x: 2 + badgeWidth, y: captionY, width: max(bounds.width * 0.62 - badgeWidth, 0), height: 16)
		hostLabel.frame = CGRect(x: titleLabel.frame.maxX + 6, y: captionY + 1, width: max(bounds.width - titleLabel.frame.maxX - 8, 0), height: 15)
		hostLabel.alignment = .right
		closeButton.frame = CGRect(x: -9, y: -9, width: 26, height: 26)
		updateShadow()
	}

	/// Fill the card when the snapshot has roughly the card's shape; otherwise (e.g. a narrow
	/// split pane) fit it whole, top-aligned, instead of cropping the page's header away.
	private func updateThumbnailGravity() {
		guard let image = item.snapshot, thumbnailView.bounds.width > 0, thumbnailView.bounds.height > 0 else { return }
		let imageAspect = CGFloat(image.width) / max(CGFloat(image.height), 1)
		let cardAspect = thumbnailView.bounds.width / thumbnailView.bounds.height
		let gravity: CALayerContentsGravity = abs(imageAspect / cardAspect - 1) < 0.15 ? .resizeAspectFill : .resizeAspect
		guard thumbnailLayer.contentsGravity != gravity else { return }
		CATransaction.begin()
		CATransaction.setDisableActions(true)
		thumbnailLayer.contentsGravity = gravity
		CATransaction.commit()
	}

	private func updateSelectionRing() {
		guard let thumbnailLayer = thumbnailView.layer else { return }
		let showsRing = item.isSelected || isHighlighted
		thumbnailLayer.borderWidth = showsRing ? 3 : 0.5
		thumbnailLayer.borderColor = showsRing
			? NSColor.controlAccentColor.withAlphaComponent(isHighlighted ? 1 : 0.75).cgColor
			: NSColor.separatorColor.cgColor
	}

	private func updateShadow() {
		guard let layer else { return }
		let thumbnailRect = Self.thumbnailRect(cardSize: bounds.size, captionHeight: captionHeight)
		layer.shadowColor = NSColor.black.cgColor
		layer.shadowOpacity = isLifted ? 0.32 : 0.18
		layer.shadowRadius = isLifted ? 24 : 12
		layer.shadowOffset = CGSize(width: 0, height: isLifted ? -14 : -5)
		layer.shadowPath = CGPath(
			roundedRect: thumbnailRect,
			cornerWidth: Self.cornerRadius,
			cornerHeight: Self.cornerRadius,
			transform: nil
		)
	}

	override func updateTrackingAreas() {
		super.updateTrackingAreas()
		if let trackingArea {
			removeTrackingArea(trackingArea)
		}
		let area = NSTrackingArea(
			rect: bounds,
			options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
			owner: self
		)
		addTrackingArea(area)
		trackingArea = area
	}

	override func mouseEntered(with event: NSEvent) {
		setHovered(true)
	}

	override func mouseExited(with event: NSEvent) {
		setHovered(false)
	}

	func setHovered(_ hovered: Bool) {
		guard hovered != isHovered else { return }
		isHovered = hovered
		guard isLifted == false else { return }
		liftSpring.animate(to: hovered ? 1.025 : 1, spring: SpatialMotion.lift)
		NSAnimationContext.runAnimationGroup { context in
			context.duration = 0.16
			closeButton.animator().alphaValue = hovered ? 1 : 0
		}
	}

	/// Mouse handling lives in the overview so it can run drags across cards;
	/// only the close button keeps its own hit testing.
	override func hitTest(_ point: NSPoint) -> NSView? {
		let local = convert(point, from: superview)
		if closeButton.alphaValue > 0.5, closeButton.frame.contains(local) {
			return closeButton
		}
		return nil
	}

	@objc
	private func closeTapped() {
		onClose?(item.id)
	}
}

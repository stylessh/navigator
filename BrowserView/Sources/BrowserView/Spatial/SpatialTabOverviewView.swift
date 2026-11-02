import AppKit
import BrowserSidebar
import Vendors

@MainActor
protocol SpatialTabOverviewViewDelegate: AnyObject {
	/// Where the live page for `tabID` sits, in overview coordinates. Cards zoom from/to this rect.
	func overviewPageRect(for tabID: BrowserTabID) -> CGRect
	func overviewDidChooseTab(_ tabID: BrowserTabID)
	func overviewDidRequestClose(_ tabID: BrowserTabID)
	func overviewDidRequestSplit(dragged: BrowserTabID, target: BrowserTabID, edge: SpatialSplitEdge)
	func overviewDidRequestMove(_ tabID: BrowserTabID, before target: BrowserTabID)
	/// The overview finished its exit animation and can be removed.
	func overviewDidFinishDismissing()
}

/// Zoomed-out grid of every tab in the current space.
///
/// Interactions: click opens a tab, ⌥-click splits it next to the current tab, drag a card onto
/// another card's edge to split them (or its middle to reorder), hover × or ⌫ closes, type to
/// filter, arrows + return to navigate, esc or pinch out to go back.
@MainActor
final class SpatialTabOverviewView: NSView {
	weak var delegate: SpatialTabOverviewViewDelegate?

	private let backdrop = SpatialGlassView(style: .backdrop)
	private let dimView = NSView()
	private let header = SpatialGlassView(style: .regular, cornerRadius: 19)
	private let headerLabel = NSTextField(labelWithString: "")
	private let queryLabel = NSTextField(labelWithString: "")
	private let hintLabel = NSTextField(labelWithString: "")
	private let dropHighlight = NSView()
	private lazy var dropHighlightSpring = SpatialFrameSpring(view: dropHighlight)
	private lazy var chromeAlpha = SpatialValueSpring(initial: 0) { [weak self] alpha in
		self?.backdrop.alphaValue = alpha
		self?.dimView.alphaValue = alpha
		self?.header.alphaValue = alpha
		self?.hintLabel.alphaValue = alpha
	}

	private var items = [SpatialOverviewItem]()
	private var cardsByID = [BrowserTabID: SpatialTabOverviewCardView]()
	private var visibleIDs = [BrowserTabID]()
	private var grid: SpatialOverviewGrid?
	private var query = ""
	private var highlightedIndex = 0
	private var thumbnailAspectRatio: CGFloat = 16 / 10
	private(set) var isDismissing = false
	private var hasPresented = false
	private var interactiveSourceID: BrowserTabID?

	private enum DragState {
		case idle
		case pressed(id: BrowserTabID, location: CGPoint, optionKey: Bool)
		case dragging(id: BrowserTabID, grabOffset: CGPoint, target: (id: BrowserTabID, drop: SpatialDropTarget)?)
	}

	private var dragState = DragState.idle
	private static let dragThreshold: CGFloat = 4

	override var isFlipped: Bool {
		true
	}

	override var acceptsFirstResponder: Bool {
		true
	}

	init() {
		super.init(frame: .zero)
		wantsLayer = true
		build()
	}

	@available(*, unavailable)
	required init?(coder: NSCoder) {
		fatalError("init(coder:) has not been implemented")
	}

	private func build() {
		// The overview always reads as a dark, focused space regardless of the page beneath
		// (a light page under clear glass made white captions illegible).
		appearance = NSAppearance(named: .darkAqua)
		addSubview(backdrop)
		dimView.wantsLayer = true
		dimView.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.42).cgColor
		addSubview(dimView)

		headerLabel.font = .systemFont(ofSize: 13, weight: .semibold)
		headerLabel.textColor = .labelColor
		queryLabel.font = .systemFont(ofSize: 13, weight: .regular)
		queryLabel.textColor = .secondaryLabelColor
		header.contentView.addSubview(headerLabel)
		header.contentView.addSubview(queryLabel)
		addSubview(header)

		hintLabel.font = .systemFont(ofSize: 11, weight: .medium)
		hintLabel.textColor = .secondaryLabelColor
		hintLabel.alignment = .center
		hintLabel.stringValue = "Drag a tab onto another's edge to split  ·  ⌥-click to split with current  ·  Type to filter"
		addSubview(hintLabel)

		dropHighlight.wantsLayer = true
		dropHighlight.layer?.cornerRadius = SpatialTabOverviewCardView.cornerRadius
		dropHighlight.layer?.cornerCurve = .continuous
		dropHighlight.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.28).cgColor
		dropHighlight.layer?.borderColor = NSColor.controlAccentColor.cgColor
		dropHighlight.layer?.borderWidth = 2
		dropHighlight.alphaValue = 0
		addSubview(dropHighlight)

		setAccessibilityRole(.group)
		setAccessibilityLabel("Tab overview")
	}

	// MARK: Data

	func setItems(_ nextItems: [SpatialOverviewItem], pageAspectRatio: CGFloat) {
		thumbnailAspectRatio = pageAspectRatio
		let removedIDs = Set(items.map(\.id)).subtracting(nextItems.map(\.id))
		items = nextItems
		for id in removedIDs {
			guard let card = cardsByID.removeValue(forKey: id) else { continue }
			card.animateAlpha(to: 0, spring: SpatialMotion.reflow) { [weak card] in
				card?.removeFromSuperview()
			}
			card.animateScale(to: 0.85, spring: SpatialMotion.reflow)
		}
		for item in nextItems {
			if let card = cardsByID[item.id] {
				card.update(item: item)
			}
			else {
				let card = SpatialTabOverviewCardView(item: item)
				card.onClose = { [weak self] id in
					self?.delegate?.overviewDidRequestClose(id)
				}
				addSubview(card, positioned: .below, relativeTo: dropHighlight)
				cardsByID[item.id] = card
				if hasPresented {
					card.setAlpha(0)
					card.setScale(0.9)
				}
			}
		}
		applyFilter(animated: hasPresented)
		if hasPresented {
			for id in visibleIDs {
				guard let card = cardsByID[id], card.alphaValue < 1 else { continue }
				card.animateAlpha(to: 1)
				card.animateScale(to: 1, spring: SpatialMotion.reflow)
			}
		}
	}

	/// Updates card content (e.g. a thumbnail that just arrived) without touching layout.
	func refreshContent(_ nextItems: [SpatialOverviewItem]) {
		for item in nextItems {
			cardsByID[item.id]?.update(item: item)
		}
		items = items.map { existing in nextItems.first { $0.id == existing.id } ?? existing }
	}

	private func applyFilter(animated: Bool) {
		let previousHighlightID = visibleIDs.indices.contains(highlightedIndex) ? visibleIDs[highlightedIndex] : nil
		visibleIDs = items
			.filter { SpatialOverviewFilter.matches(query: query, title: $0.title, url: $0.url) }
			.map(\.id)
		for (id, card) in cardsByID {
			let isVisible = visibleIDs.contains(id)
			card.isHidden = false
			if hasPresented {
				card.animateAlpha(to: isVisible ? 1 : 0)
			}
		}
		if let previousHighlightID, let index = visibleIDs.firstIndex(of: previousHighlightID) {
			highlightedIndex = index
		}
		else if let selectedIndex = visibleIDs.firstIndex(where: { id in items.first { $0.id == id }?.isSelected == true }) {
			highlightedIndex = selectedIndex
		}
		else {
			highlightedIndex = 0
		}
		updateHeader()
		relayoutCards(animated: animated)
		updateHighlight()
	}

	// MARK: Presentation

	/// Presents the overview. With `interactive`, call `setInteractiveProgress` as a pinch moves
	/// and finish with `completeInteractivePresentation(commit:)`.
	func present(interactive: Bool) {
		layoutSubtreeIfNeeded()
		computeGrid()
		let selectedID = items.first { $0.isSelected }?.id
		interactiveSourceID = selectedID
		for (index, id) in visibleIDs.enumerated() {
			guard let card = cardsByID[id], let target = grid?.frames[spatialSafe: index] else { continue }
			if id == selectedID, let delegate {
				card.frameSpring.set(
					SpatialTabOverviewCardView.cardFrame(coveringThumbnail: delegate.overviewPageRect(for: id), captionHeight: card.captionHeight)
				)
				card.setAlpha(1)
			}
			else {
				card.frameSpring.set(target)
				card.setAlpha(0)
				card.setScale(0.92)
			}
		}
		hasPresented = true
		window?.makeFirstResponder(self)
		if interactive {
			setInteractiveProgress(0)
		}
		else {
			settlePresentation()
		}
	}

	func setInteractiveProgress(_ progress: CGFloat) {
		guard let grid, let delegate else { return }
		let progress = max(progress, 0)
		chromeAlpha.set(min(progress, 1))
		for (index, id) in visibleIDs.enumerated() {
			guard let card = cardsByID[id], let target = grid.frames[spatialSafe: index] else { continue }
			if id == interactiveSourceID {
				let source = SpatialTabOverviewCardView.cardFrame(
					coveringThumbnail: delegate.overviewPageRect(for: id),
					captionHeight: card.captionHeight
				)
				card.frameSpring.set(source.interpolated(to: target, progress: progress))
			}
			else {
				card.setAlpha(min(progress * 1.4, 1))
				card.setScale(0.92 + 0.08 * min(progress, 1))
			}
		}
	}

	func completeInteractivePresentation(commit: Bool) {
		if commit {
			settlePresentation()
		}
		else {
			dismiss(choosing: interactiveSourceID, notifyChoice: false)
		}
	}

	private func settlePresentation() {
		chromeAlpha.animate(to: 1, spring: SpatialMotion.zoom)
		for (index, id) in visibleIDs.enumerated() {
			guard let card = cardsByID[id], let target = grid?.frames[spatialSafe: index] else { continue }
			card.frameSpring.animate(to: target, spring: SpatialMotion.zoom)
			if id != interactiveSourceID {
				// Small stagger by distance from the source card gives the grid a sense of depth.
				let delay = min(Double(index) * 0.012, 0.12)
				spatialAfter(delay) { [weak card] in
					card?.animateAlpha(to: 1, spring: SpatialMotion.zoom)
					card?.animateScale(to: 1, spring: SpatialMotion.zoom)
				}
			}
		}
	}

	/// Zooms the chosen card back to the page and fades the rest away.
	func dismiss(choosing tabID: BrowserTabID?, notifyChoice: Bool = true) {
		guard isDismissing == false else { return }
		isDismissing = true
		endDrag(cancelled: true)
		if notifyChoice, let tabID {
			delegate?.overviewDidChooseTab(tabID)
		}
		layoutSubtreeIfNeeded()
		chromeAlpha.animate(to: 0, spring: SpatialMotion.zoom)
		let zoomingCard = tabID.flatMap { visibleIDs.contains($0) ? cardsByID[$0] : nil }
		for (id, card) in cardsByID {
			if id == tabID, let delegate, visibleIDs.contains(id) {
				card.layer?.zPosition = 50
				card.setScale(1)
				card.frameSpring.animate(
					to: SpatialTabOverviewCardView.cardFrame(coveringThumbnail: delegate.overviewPageRect(for: id), captionHeight: card.captionHeight),
					spring: SpatialMotion.zoom
				)
			}
			else {
				card.animateAlpha(to: 0, spring: SpatialMotion.zoom)
				card.animateScale(to: 0.94, spring: SpatialMotion.zoom)
			}
		}
		// Hand the screen back to the live page once the zoom has visually landed.
		let settle = SpatialMotion.prefersReducedMotion ? 0 : SpatialMotion.zoom.settlingDuration * 0.7
		spatialAfter(settle) { [weak self, weak zoomingCard] in
			guard let self else { return }
			zoomingCard?.animateAlpha(to: 0, spring: SpatialMotion.highlight)
			spatialAfter(0.12) { [weak self] in
				self?.delegate?.overviewDidFinishDismissing()
			}
		}
	}

	// MARK: Layout

	override func layout() {
		super.layout()
		backdrop.frame = bounds
		dimView.frame = bounds
		layoutHeader()
		// Sits under the header pill; the bottom edge belongs to the floating toolbar.
		hintLabel.frame = CGRect(x: 24, y: header.frame.maxY + 10, width: max(bounds.width - 48, 0), height: 16)
		if hasPresented, isDismissing == false, case .idle = dragState {
			relayoutCards(animated: false)
		}
	}

	private func layoutHeader() {
		headerLabel.sizeToFit()
		queryLabel.sizeToFit()
		let showsQuery = query.isEmpty == false
		let contentWidth = headerLabel.frame.width + (showsQuery ? queryLabel.frame.width + 10 : 0)
		let size = CGSize(width: contentWidth + 36, height: 38)
		header.frame = CGRect(x: (bounds.width - size.width) / 2, y: 28, width: size.width, height: size.height)
		headerLabel.frame.origin = CGPoint(x: 18, y: (size.height - headerLabel.frame.height) / 2)
		queryLabel.isHidden = showsQuery == false
		queryLabel.frame.origin = CGPoint(x: headerLabel.frame.maxX + 10, y: (size.height - queryLabel.frame.height) / 2)
	}

	private func updateHeader() {
		let count = items.count
		headerLabel.stringValue = count == 1 ? "1 tab" : "\(count) tabs"
		queryLabel.stringValue = query.isEmpty ? "" : "“\(query)” · \(visibleIDs.count)"
		needsLayout = true
	}

	private func computeGrid() {
		grid = SpatialOverviewGrid(
			bounds: bounds,
			itemCount: visibleIDs.count,
			thumbnailAspectRatio: thumbnailAspectRatio,
			captionHeight: 30
		)
	}

	private func relayoutCards(animated: Bool) {
		computeGrid()
		guard let grid else { return }
		for (index, id) in visibleIDs.enumerated() {
			guard let card = cardsByID[id], let target = grid.frames[spatialSafe: index] else { continue }
			if case let .dragging(draggedID, _, _) = dragState, draggedID == id { continue }
			if animated {
				card.frameSpring.animate(to: target, spring: SpatialMotion.reflow)
			}
			else if card.frameSpring.isAnimating == false {
				card.frameSpring.set(target)
			}
		}
	}

	private func updateHighlight() {
		for (index, id) in visibleIDs.enumerated() {
			cardsByID[id]?.isHighlighted = index == highlightedIndex
		}
	}

	// MARK: Mouse

	private func cardID(at point: CGPoint, excluding excluded: BrowserTabID? = nil) -> BrowserTabID? {
		for id in visibleIDs.reversed() where id != excluded {
			if let card = cardsByID[id], card.frame.contains(point) {
				return id
			}
		}
		return nil
	}

	override func mouseDown(with event: NSEvent) {
		guard isDismissing == false else { return }
		let point = convert(event.locationInWindow, from: nil)
		guard let id = cardID(at: point) else {
			dragState = .idle
			return
		}
		dragState = .pressed(id: id, location: point, optionKey: event.modifierFlags.contains(.option))
	}

	override func mouseDragged(with event: NSEvent) {
		let point = convert(event.locationInWindow, from: nil)
		switch dragState {
		case .idle:
			return
		case let .pressed(id, start, _):
			guard hypot(point.x - start.x, point.y - start.y) > Self.dragThreshold, let card = cardsByID[id] else { return }
			card.frameSpring.stop()
			card.isLifted = true
			dragState = .dragging(id: id, grabOffset: CGPoint(x: start.x - card.frame.minX, y: start.y - card.frame.minY), target: nil)
			mouseDragged(with: event)
		case let .dragging(id, grabOffset, _):
			guard let card = cardsByID[id] else { return }
			card.frameSpring.set(CGRect(origin: CGPoint(x: point.x - grabOffset.x, y: point.y - grabOffset.y), size: card.frame.size))
			var nextTarget: (id: BrowserTabID, drop: SpatialDropTarget)?
			if let targetID = cardID(at: point, excluding: id), let targetCard = cardsByID[targetID] {
				let thumbnail = SpatialTabOverviewCardView.thumbnailRect(cardSize: targetCard.frame.size, captionHeight: targetCard.captionHeight)
					.offsetBy(dx: targetCard.frame.minX, dy: targetCard.frame.minY)
				if let drop = SpatialDropTarget.resolve(point: point, in: thumbnail.insetBy(dx: -1, dy: -1), edgeFraction: 0.38) {
					nextTarget = (targetID, drop)
					showDropHighlight(drop.previewRect(in: thumbnail))
				}
			}
			if nextTarget == nil {
				hideDropHighlight()
			}
			dragState = .dragging(id: id, grabOffset: grabOffset, target: nextTarget)
		}
	}

	override func mouseUp(with event: NSEvent) {
		switch dragState {
		case .idle:
			if event.clickCount == 2 {
				dismiss(choosing: items.first { $0.isSelected }?.id)
			}
		case let .pressed(id, _, optionKey):
			dragState = .idle
			if optionKey, let current = items.first(where: { $0.isSelected })?.id, current != id {
				delegate?.overviewDidRequestSplit(dragged: id, target: current, edge: .right)
			}
			else {
				dismiss(choosing: id)
			}
		case let .dragging(id, _, target):
			if let target {
				dragState = .idle
				cardsByID[id]?.isLifted = false
				hideDropHighlight()
				switch target.drop {
				case let .edge(edge):
					delegate?.overviewDidRequestSplit(dragged: id, target: target.id, edge: edge)
				case .center:
					delegate?.overviewDidRequestMove(id, before: target.id)
				}
				relayoutCards(animated: true)
			}
			else {
				endDrag(cancelled: true)
			}
		}
	}

	override func otherMouseUp(with event: NSEvent) {
		// Middle-click closes, like a tab strip.
		let point = convert(event.locationInWindow, from: nil)
		if event.buttonNumber == 2, let id = cardID(at: point) {
			delegate?.overviewDidRequestClose(id)
		}
	}

	private func endDrag(cancelled: Bool) {
		if case let .dragging(id, _, _) = dragState {
			cardsByID[id]?.isLifted = false
		}
		dragState = .idle
		hideDropHighlight()
		if cancelled, hasPresented, isDismissing == false {
			relayoutCards(animated: true)
		}
	}

	private func showDropHighlight(_ rect: CGRect) {
		if dropHighlight.alphaValue < 0.01 {
			dropHighlightSpring.set(rect)
		}
		else {
			dropHighlightSpring.animate(to: rect, spring: SpatialMotion.highlight)
		}
		NSAnimationContext.runAnimationGroup { context in
			context.duration = 0.12
			dropHighlight.animator().alphaValue = 1
		}
	}

	private func hideDropHighlight() {
		NSAnimationContext.runAnimationGroup { context in
			context.duration = 0.12
			dropHighlight.animator().alphaValue = 0
		}
	}

	// MARK: Keyboard

	override func keyDown(with event: NSEvent) {
		guard isDismissing == false else { return }
		switch Int(event.keyCode) {
		case 53: // esc
			if query.isEmpty {
				dismiss(choosing: items.first { $0.isSelected }?.id)
			}
			else {
				setQuery("")
			}
		case 36, 76: // return, enter
			if let id = visibleIDs[spatialSafe: highlightedIndex] {
				dismiss(choosing: id)
			}
		case 123: moveHighlight(.left)
		case 124: moveHighlight(.right)
		case 125: moveHighlight(.down)
		case 126: moveHighlight(.up)
		case 51: // delete
			if query.isEmpty {
				if let id = visibleIDs[spatialSafe: highlightedIndex] {
					delegate?.overviewDidRequestClose(id)
				}
			}
			else {
				setQuery(String(query.dropLast()))
			}
		default:
			let modifiers = event.modifierFlags.intersection([.command, .control])
			if modifiers.isEmpty, let characters = event.characters, characters.isEmpty == false,
			   characters.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.union(.punctuationCharacters).union(.whitespaces).union(.symbols).contains($0) }) {
				setQuery(query + characters)
			}
			else {
				super.keyDown(with: event)
			}
		}
	}

	private func setQuery(_ next: String) {
		query = next
		applyFilter(animated: true)
	}

	private func moveHighlight(_ direction: SpatialDirection) {
		guard let grid, visibleIDs.isEmpty == false else { return }
		highlightedIndex = grid.index(movingFrom: highlightedIndex, direction: direction)
		updateHighlight()
	}

	/// Pinching out over a card opens it.
	func handleZoomInGesture(at locationInWindow: CGPoint) {
		let point = convert(locationInWindow, from: nil)
		let id = cardID(at: point) ?? visibleIDs[spatialSafe: highlightedIndex] ?? items.first { $0.isSelected }?.id
		dismiss(choosing: id)
	}
}

extension CGRect {
	func interpolated(to target: CGRect, progress: CGFloat) -> CGRect {
		CGRect(
			x: minX + (target.minX - minX) * progress,
			y: minY + (target.minY - minY) * progress,
			width: width + (target.width - width) * progress,
			height: height + (target.height - height) * progress
		)
	}
}

extension Array {
	subscript(spatialSafe index: Int) -> Element? {
		indices.contains(index) ? self[index] : nil
	}
}

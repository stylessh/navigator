import CoreGraphics
import Foundation

/// Lays out tab cards for the zoomed-out tab overview (Exposé style).
/// Produces frames in a flipped (top-left origin) space.
public struct SpatialOverviewGrid: Equatable, Sendable {
	public var bounds: CGRect
	public var itemCount: Int
	/// Width / height of a card's thumbnail (usually the page's aspect ratio).
	public var thumbnailAspectRatio: CGFloat
	public var spacing: CGFloat
	public var insets: SpatialEdgeInsets
	/// Extra height under each thumbnail for the title row.
	public var captionHeight: CGFloat
	public var maximumCardWidth: CGFloat

	public private(set) var columns = 1
	public private(set) var rows = 0
	public private(set) var cardSize = CGSize.zero
	public private(set) var frames = [CGRect]()

	public init(
		bounds: CGRect,
		itemCount: Int,
		thumbnailAspectRatio: CGFloat,
		spacing: CGFloat = 28,
		insets: SpatialEdgeInsets = .init(top: 96, left: 48, bottom: 112, right: 48),
		captionHeight: CGFloat = 30,
		maximumCardWidth: CGFloat = 460
	) {
		self.bounds = bounds
		self.itemCount = max(itemCount, 0)
		self.thumbnailAspectRatio = thumbnailAspectRatio.isFinite && thumbnailAspectRatio > 0 ? thumbnailAspectRatio : 16 / 10
		self.spacing = spacing
		self.insets = insets
		self.captionHeight = captionHeight
		self.maximumCardWidth = maximumCardWidth
		solve()
	}

	private mutating func solve() {
		frames = []
		guard itemCount > 0 else {
			columns = 1
			rows = 0
			cardSize = .zero
			return
		}
		let available = CGRect(
			x: bounds.minX + insets.left,
			y: bounds.minY + insets.top,
			width: max(bounds.width - insets.left - insets.right, 1),
			height: max(bounds.height - insets.top - insets.bottom, 1)
		)

		var bestColumns = 1
		var bestWidth: CGFloat = 0
		for candidateColumns in 1 ... itemCount {
			let candidateRows = Int((Double(itemCount) / Double(candidateColumns)).rounded(.up))
			let widthByColumns = (available.width - CGFloat(candidateColumns - 1) * spacing) / CGFloat(candidateColumns)
			let rowHeight = (available.height - CGFloat(candidateRows - 1) * spacing) / CGFloat(candidateRows)
			let widthByRows = (rowHeight - captionHeight) * thumbnailAspectRatio
			let width = min(widthByColumns, widthByRows, maximumCardWidth)
			// Prefer more columns only when it actually yields bigger cards.
			if width > bestWidth + 0.5 {
				bestWidth = width
				bestColumns = candidateColumns
			}
		}

		let cardWidth = max(bestWidth, 1).rounded(.down)
		let cardHeight = (cardWidth / thumbnailAspectRatio + captionHeight).rounded(.down)
		columns = bestColumns
		rows = Int((Double(itemCount) / Double(bestColumns)).rounded(.up))
		cardSize = CGSize(width: cardWidth, height: cardHeight)

		let gridHeight = CGFloat(rows) * cardHeight + CGFloat(rows - 1) * spacing
		let originY = available.minY + max((available.height - gridHeight) / 2, 0)

		for index in 0 ..< itemCount {
			let row = index / columns
			let column = index % columns
			let itemsInRow = row == rows - 1 ? itemCount - row * columns : columns
			let rowWidth = CGFloat(itemsInRow) * cardWidth + CGFloat(itemsInRow - 1) * spacing
			let originX = available.minX + (available.width - rowWidth) / 2
			frames.append(
				CGRect(
					x: (originX + CGFloat(column) * (cardWidth + spacing)).rounded(),
					y: (originY + CGFloat(row) * (cardHeight + spacing)).rounded(),
					width: cardWidth,
					height: cardHeight
				)
			)
		}
	}

	/// The thumbnail part of a card frame (above the caption).
	public func thumbnailRect(forCardFrame frame: CGRect) -> CGRect {
		CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: max(frame.height - captionHeight, 0))
	}

	public func index(at point: CGPoint) -> Int? {
		frames.firstIndex { $0.contains(point) }
	}

	/// Keyboard navigation through the grid. Clamps at the edges instead of wrapping vertically.
	public func index(movingFrom index: Int, direction: SpatialDirection) -> Int {
		guard itemCount > 0 else { return 0 }
		let current = min(max(index, 0), itemCount - 1)
		switch direction {
		case .left:
			return max(current - 1, 0)
		case .right:
			return min(current + 1, itemCount - 1)
		case .up:
			return current - columns >= 0 ? current - columns : current
		case .down:
			if current + columns < itemCount { return current + columns }
			// Jump to the last item when the row below is shorter.
			let currentRow = current / columns
			return currentRow < rows - 1 ? itemCount - 1 : current
		}
	}
}

public struct SpatialEdgeInsets: Equatable, Sendable {
	public var top: CGFloat
	public var left: CGFloat
	public var bottom: CGFloat
	public var right: CGFloat

	public init(top: CGFloat, left: CGFloat, bottom: CGFloat, right: CGFloat) {
		self.top = top
		self.left = left
		self.bottom = bottom
		self.right = right
	}
}

/// Matches tabs against the overview's type-to-filter query.
public enum SpatialOverviewFilter {
	public static func matches(query: String, title: String, url: String) -> Bool {
		let tokens = query
			.lowercased()
			.split(whereSeparator: \.isWhitespace)
			.map(String.init)
		guard tokens.isEmpty == false else { return true }
		let haystack = (title + " " + url).lowercased()
		return tokens.allSatisfy { haystack.contains($0) }
	}
}

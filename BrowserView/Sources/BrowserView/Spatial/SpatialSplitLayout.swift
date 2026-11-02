import CoreGraphics
import Foundation

/// Experimental spatial layouts: a binary split tree of tab panes.
///
/// Geometry produced here is in a *flipped* (top-left origin) coordinate space,
/// matching `BrowserSpatialHostView.isFlipped == true`.
public enum SpatialSplitAxis: String, Codable, Equatable, Sendable {
	/// Children are laid out side by side (first = leading/left).
	case horizontal
	/// Children are stacked (first = top).
	case vertical
}

/// The edge of an existing pane a new pane is dropped against.
public enum SpatialSplitEdge: String, Codable, CaseIterable, Equatable, Sendable {
	case left
	case right
	case top
	case bottom

	var axis: SpatialSplitAxis {
		switch self {
		case .left, .right: .horizontal
		case .top, .bottom: .vertical
		}
	}

	/// Whether the inserted pane becomes the first child of the new split.
	var insertsFirst: Bool {
		self == .left || self == .top
	}
}

public enum SpatialDirection: Equatable, Sendable {
	case left
	case right
	case up
	case down
}

public indirect enum SpatialSplitNode<ID: Hashable & Codable & Sendable>: Equatable, Codable, Sendable {
	case pane(ID)
	case split(axis: SpatialSplitAxis, ratio: Double, first: SpatialSplitNode, second: SpatialSplitNode)
}

/// Identifies a split node by the path of child choices (0 = first, 1 = second) from the root.
public typealias SpatialSplitPath = [Int]

public struct SpatialSplitDivider: Equatable, Sendable {
	public var path: SpatialSplitPath
	public var axis: SpatialSplitAxis
	/// The divider's hit/visual rect (thickness == gap, or a minimum hit width).
	public var rect: CGRect
	/// The rect of the split node that owns this divider; used to turn a drag location into a ratio.
	public var containerRect: CGRect
}

public struct SpatialSplitLayout<ID: Hashable & Codable & Sendable>: Equatable, Codable, Sendable {
	public static var maximumPaneCount: Int { 4 }
	public static var minimumRatio: Double { 0.18 }
	public static var maximumRatio: Double { 0.82 }

	public private(set) var root: SpatialSplitNode<ID>

	public init(root: SpatialSplitNode<ID>) {
		self.root = root
	}

	/// A two-pane split.
	public init(_ existing: ID, adding new: ID, edge: SpatialSplitEdge = .right) {
		root = .pane(existing)
		_ = insert(new, adjacentTo: existing, edge: edge)
	}

	// MARK: Queries

	public var paneIDs: [ID] {
		Self.leaves(of: root)
	}

	public var paneCount: Int {
		paneIDs.count
	}

	public var canAddPane: Bool {
		paneCount < Self.maximumPaneCount
	}

	/// A layout with a single pane is not a split.
	public var isSplit: Bool {
		paneCount > 1
	}

	public func contains(_ id: ID) -> Bool {
		paneIDs.contains(id)
	}

	// MARK: Mutations

	/// Inserts `id` next to `target`. Returns false (and does nothing) when the target is
	/// missing, `id` is already present, or the layout is full.
	@discardableResult
	public mutating func insert(_ id: ID, adjacentTo target: ID, edge: SpatialSplitEdge) -> Bool {
		guard id != target, contains(target), contains(id) == false, canAddPane else { return false }
		root = Self.replacingPane(target, in: root) { existing in
			let inserted = SpatialSplitNode<ID>.pane(id)
			return .split(
				axis: edge.axis,
				ratio: 0.5,
				first: edge.insertsFirst ? inserted : existing,
				second: edge.insertsFirst ? existing : inserted
			)
		}
		return true
	}

	/// Removes a pane, collapsing its parent split into the sibling.
	/// Returns nil when the removed pane was the last one.
	public func removing(_ id: ID) -> SpatialSplitLayout? {
		guard let next = Self.removing(id, from: root) else { return nil }
		return SpatialSplitLayout(root: next)
	}

	/// Replaces one pane's tab with another (e.g. dropping a card onto the center of a pane).
	@discardableResult
	public mutating func replace(_ id: ID, with replacement: ID) -> Bool {
		guard contains(id), contains(replacement) == false else { return false }
		root = Self.replacingPane(id, in: root) { _ in .pane(replacement) }
		return true
	}

	/// Swaps the positions of two panes.
	@discardableResult
	public mutating func swap(_ a: ID, _ b: ID) -> Bool {
		guard a != b, contains(a), contains(b) else { return false }
		root = Self.mapPanes(root) { id in
			if id == a { return b }
			if id == b { return a }
			return id
		}
		return true
	}

	public mutating func setRatio(_ ratio: Double, at path: SpatialSplitPath) {
		root = Self.updatingSplit(at: path[...], in: root) { axis, _, first, second in
			.split(axis: axis, ratio: Self.clampRatio(ratio), first: first, second: second)
		}
	}

	/// Resets every split to an even 50/50 division.
	public mutating func equalize() {
		root = Self.equalized(root)
	}

	public static func clampRatio(_ ratio: Double) -> Double {
		guard ratio.isFinite else { return 0.5 }
		return min(max(ratio, minimumRatio), maximumRatio)
	}

	// MARK: Geometry

	/// Pane frames inside `rect`, separated by `gap` points.
	public func paneFrames(in rect: CGRect, gap: CGFloat) -> [ID: CGRect] {
		var frames = [ID: CGRect]()
		var dividers = [SpatialSplitDivider]()
		Self.layout(root, in: rect, gap: gap, path: [], frames: &frames, dividers: &dividers)
		return frames
	}

	public func dividers(in rect: CGRect, gap: CGFloat, minimumHitThickness: CGFloat = 8) -> [SpatialSplitDivider] {
		var frames = [ID: CGRect]()
		var dividers = [SpatialSplitDivider]()
		Self.layout(root, in: rect, gap: gap, path: [], frames: &frames, dividers: &dividers)
		return dividers.map { divider in
			var divider = divider
			switch divider.axis {
			case .horizontal where divider.rect.width < minimumHitThickness:
				divider.rect = divider.rect.insetBy(dx: (divider.rect.width - minimumHitThickness) / 2, dy: 0)
			case .vertical where divider.rect.height < minimumHitThickness:
				divider.rect = divider.rect.insetBy(dx: 0, dy: (divider.rect.height - minimumHitThickness) / 2)
			default:
				break
			}
			return divider
		}
	}

	/// Converts a drag location into the ratio for a divider.
	public static func ratio(for location: CGPoint, divider: SpatialSplitDivider, gap: CGFloat) -> Double {
		let container = divider.containerRect
		switch divider.axis {
		case .horizontal:
			let usable = max(container.width - gap, 1)
			return clampRatio(Double((location.x - container.minX - gap / 2) / usable))
		case .vertical:
			let usable = max(container.height - gap, 1)
			return clampRatio(Double((location.y - container.minY - gap / 2) / usable))
		}
	}

	/// The pane geometrically adjacent to `id` in `direction`, if any.
	public func neighbor(of id: ID, direction: SpatialDirection, in rect: CGRect = CGRect(x: 0, y: 0, width: 1000, height: 1000)) -> ID? {
		let frames = paneFrames(in: rect, gap: 0)
		guard let origin = frames[id] else { return nil }
		let candidates = frames.filter { candidateID, frame in
			guard candidateID != id else { return false }
			switch direction {
			case .left: return frame.maxX <= origin.minX + 0.5 && Self.overlaps(frame.minY ... frame.maxY, origin.minY ... origin.maxY)
			case .right: return frame.minX >= origin.maxX - 0.5 && Self.overlaps(frame.minY ... frame.maxY, origin.minY ... origin.maxY)
			case .up: return frame.maxY <= origin.minY + 0.5 && Self.overlaps(frame.minX ... frame.maxX, origin.minX ... origin.maxX)
			case .down: return frame.minY >= origin.maxY - 0.5 && Self.overlaps(frame.minX ... frame.maxX, origin.minX ... origin.maxX)
			}
		}
		return candidates.min { lhs, rhs in
			Self.distance(origin, lhs.value) < Self.distance(origin, rhs.value)
		}?.key
	}

	// MARK: Private helpers

	private static func overlaps(_ a: ClosedRange<CGFloat>, _ b: ClosedRange<CGFloat>) -> Bool {
		min(a.upperBound, b.upperBound) - max(a.lowerBound, b.lowerBound) > 0.5
	}

	private static func distance(_ a: CGRect, _ b: CGRect) -> CGFloat {
		hypot(a.midX - b.midX, a.midY - b.midY)
	}

	private static func leaves(of node: SpatialSplitNode<ID>) -> [ID] {
		switch node {
		case let .pane(id): [id]
		case let .split(_, _, first, second): leaves(of: first) + leaves(of: second)
		}
	}

	private static func replacingPane(
		_ target: ID,
		in node: SpatialSplitNode<ID>,
		with transform: (SpatialSplitNode<ID>) -> SpatialSplitNode<ID>
	) -> SpatialSplitNode<ID> {
		switch node {
		case let .pane(id):
			return id == target ? transform(node) : node
		case let .split(axis, ratio, first, second):
			return .split(
				axis: axis,
				ratio: ratio,
				first: replacingPane(target, in: first, with: transform),
				second: replacingPane(target, in: second, with: transform)
			)
		}
	}

	private static func removing(_ target: ID, from node: SpatialSplitNode<ID>) -> SpatialSplitNode<ID>? {
		switch node {
		case let .pane(id):
			return id == target ? nil : node
		case let .split(axis, ratio, first, second):
			let nextFirst = removing(target, from: first)
			let nextSecond = removing(target, from: second)
			switch (nextFirst, nextSecond) {
			case let (.some(a), .some(b)): return .split(axis: axis, ratio: ratio, first: a, second: b)
			case let (.some(a), .none): return a
			case let (.none, .some(b)): return b
			case (.none, .none): return nil
			}
		}
	}

	private static func mapPanes(_ node: SpatialSplitNode<ID>, _ transform: (ID) -> ID) -> SpatialSplitNode<ID> {
		switch node {
		case let .pane(id):
			return .pane(transform(id))
		case let .split(axis, ratio, first, second):
			return .split(axis: axis, ratio: ratio, first: mapPanes(first, transform), second: mapPanes(second, transform))
		}
	}

	private static func equalized(_ node: SpatialSplitNode<ID>) -> SpatialSplitNode<ID> {
		switch node {
		case .pane:
			return node
		case let .split(axis, _, first, second):
			return .split(axis: axis, ratio: 0.5, first: equalized(first), second: equalized(second))
		}
	}

	private static func updatingSplit(
		at path: ArraySlice<Int>,
		in node: SpatialSplitNode<ID>,
		transform: (SpatialSplitAxis, Double, SpatialSplitNode<ID>, SpatialSplitNode<ID>) -> SpatialSplitNode<ID>
	) -> SpatialSplitNode<ID> {
		guard case let .split(axis, ratio, first, second) = node else { return node }
		guard let step = path.first else {
			return transform(axis, ratio, first, second)
		}
		let rest = path.dropFirst()
		if step == 0 {
			return .split(axis: axis, ratio: ratio, first: updatingSplit(at: rest, in: first, transform: transform), second: second)
		}
		return .split(axis: axis, ratio: ratio, first: first, second: updatingSplit(at: rest, in: second, transform: transform))
	}

	private static func layout(
		_ node: SpatialSplitNode<ID>,
		in rect: CGRect,
		gap: CGFloat,
		path: SpatialSplitPath,
		frames: inout [ID: CGRect],
		dividers: inout [SpatialSplitDivider]
	) {
		switch node {
		case let .pane(id):
			frames[id] = rect.integral(ifLargerThan: 1)
		case let .split(axis, ratio, first, second):
			let ratio = CGFloat(clampRatio(ratio))
			let firstRect: CGRect
			let secondRect: CGRect
			let dividerRect: CGRect
			switch axis {
			case .horizontal:
				let usable = max(rect.width - gap, 0)
				let firstWidth = (usable * ratio).rounded()
				firstRect = CGRect(x: rect.minX, y: rect.minY, width: firstWidth, height: rect.height)
				dividerRect = CGRect(x: firstRect.maxX, y: rect.minY, width: gap, height: rect.height)
				secondRect = CGRect(x: dividerRect.maxX, y: rect.minY, width: max(rect.maxX - dividerRect.maxX, 0), height: rect.height)
			case .vertical:
				let usable = max(rect.height - gap, 0)
				let firstHeight = (usable * ratio).rounded()
				firstRect = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: firstHeight)
				dividerRect = CGRect(x: rect.minX, y: firstRect.maxY, width: rect.width, height: gap)
				secondRect = CGRect(x: rect.minX, y: dividerRect.maxY, width: rect.width, height: max(rect.maxY - dividerRect.maxY, 0))
			}
			dividers.append(.init(path: path, axis: axis, rect: dividerRect, containerRect: rect))
			layout(first, in: firstRect, gap: gap, path: path + [0], frames: &frames, dividers: &dividers)
			layout(second, in: secondRect, gap: gap, path: path + [1], frames: &frames, dividers: &dividers)
		}
	}
}

/// Where a dragged tab would land relative to a pane (or overview card).
public enum SpatialDropTarget: Equatable, Sendable {
	case edge(SpatialSplitEdge)
	case center

	/// Edge bands cover `edgeFraction` of each side; the rest is the center.
	public static func resolve(point: CGPoint, in rect: CGRect, edgeFraction: CGFloat = 0.3) -> SpatialDropTarget? {
		guard rect.width > 0, rect.height > 0, rect.contains(point) else { return nil }
		let nx = (point.x - rect.minX) / rect.width
		let ny = (point.y - rect.minY) / rect.height
		let distances: [(SpatialSplitEdge, CGFloat)] = [
			(.left, nx),
			(.right, 1 - nx),
			(.top, ny),
			(.bottom, 1 - ny),
		]
		guard let nearest = distances.min(by: { $0.1 < $1.1 }), nearest.1 < edgeFraction else {
			return .center
		}
		return .edge(nearest.0)
	}

	/// The highlighted preview rect for this drop target within `rect` (flipped space).
	public func previewRect(in rect: CGRect) -> CGRect {
		switch self {
		case .center: rect
		case .edge(.left): CGRect(x: rect.minX, y: rect.minY, width: rect.width / 2, height: rect.height)
		case .edge(.right): CGRect(x: rect.midX, y: rect.minY, width: rect.width / 2, height: rect.height)
		case .edge(.top): CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height / 2)
		case .edge(.bottom): CGRect(x: rect.minX, y: rect.midY, width: rect.width, height: rect.height / 2)
		}
	}
}

private extension CGRect {
	func integral(ifLargerThan minimum: CGFloat) -> CGRect {
		guard width > minimum, height > minimum else { return self }
		return CGRect(x: minX.rounded(), y: minY.rounded(), width: width.rounded(), height: height.rounded())
	}
}

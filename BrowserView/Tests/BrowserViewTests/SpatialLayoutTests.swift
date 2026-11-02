@testable import BrowserView
import CoreGraphics
import XCTest

final class SpatialSplitLayoutTests: XCTestCase {
	private typealias Layout = SpatialSplitLayout<String>
	private let rect = CGRect(x: 0, y: 0, width: 1000, height: 600)

	func testTwoPaneSplitPlacesNewPaneOnRequestedEdge() {
		let right = Layout("a", adding: "b", edge: .right)
		XCTAssertEqual(right.paneIDs, ["a", "b"])
		let left = Layout("a", adding: "b", edge: .left)
		XCTAssertEqual(left.paneIDs, ["b", "a"])

		let frames = right.paneFrames(in: rect, gap: 8)
		XCTAssertEqual(frames["a"], CGRect(x: 0, y: 0, width: 496, height: 600))
		XCTAssertEqual(frames["b"], CGRect(x: 504, y: 0, width: 496, height: 600))
	}

	func testVerticalSplitStacksTopToBottomInFlippedSpace() {
		let layout = Layout("a", adding: "b", edge: .bottom)
		let frames = layout.paneFrames(in: rect, gap: 0)
		XCTAssertEqual(frames["a"]?.minY, 0)
		XCTAssertEqual(frames["b"]?.minY, 300)
	}

	func testInsertRejectsDuplicatesMissingTargetsAndFullLayouts() {
		var layout = Layout("a", adding: "b")
		XCTAssertFalse(layout.insert("b", adjacentTo: "a", edge: .right))
		XCTAssertFalse(layout.insert("c", adjacentTo: "z", edge: .right))
		XCTAssertTrue(layout.insert("c", adjacentTo: "b", edge: .bottom))
		XCTAssertTrue(layout.insert("d", adjacentTo: "a", edge: .bottom))
		XCTAssertEqual(layout.paneCount, 4)
		XCTAssertFalse(layout.canAddPane)
		XCTAssertFalse(layout.insert("e", adjacentTo: "a", edge: .left))
	}

	func testRemovingCollapsesParentAndLastPaneReturnsNil() {
		var layout = Layout("a", adding: "b")
		layout.insert("c", adjacentTo: "b", edge: .bottom)
		let removed = layout.removing("b")
		XCTAssertEqual(removed?.paneIDs, ["a", "c"])
		XCTAssertEqual(removed?.removing("a")?.paneIDs, ["c"])
		XCTAssertEqual(removed?.removing("a")?.isSplit, false)
		XCTAssertNil(Layout(root: .pane("a")).removing("a"))
	}

	func testRatioIsClampedAndDividerDragMapsToRatio() {
		var layout = Layout("a", adding: "b")
		layout.setRatio(0.01, at: [])
		XCTAssertEqual(layout.paneFrames(in: rect, gap: 0)["a"]?.width, (1000 * Layout.minimumRatio).rounded())

		let divider = try! XCTUnwrap(layout.dividers(in: rect, gap: 8).first)
		XCTAssertEqual(divider.axis, .horizontal)
		let ratio = Layout.ratio(for: CGPoint(x: 750, y: 10), divider: divider, gap: 8)
		XCTAssertEqual(ratio, (750 - 4) / 992, accuracy: 0.0001)
		layout.setRatio(ratio, at: divider.path)
		layout.equalize()
		XCTAssertEqual(layout.paneFrames(in: rect, gap: 0)["a"]?.width, 500)
	}

	func testDividerHitAreaHasMinimumThickness() {
		let layout = Layout("a", adding: "b")
		let divider = try! XCTUnwrap(layout.dividers(in: rect, gap: 2, minimumHitThickness: 10).first)
		XCTAssertEqual(divider.rect.width, 10)
		XCTAssertEqual(divider.rect.midX, 500, accuracy: 1)
	}

	func testNeighborFollowsGeometry() {
		var layout = Layout("a", adding: "b")
		layout.insert("c", adjacentTo: "b", edge: .bottom)
		XCTAssertEqual(layout.neighbor(of: "a", direction: .right), "b")
		XCTAssertEqual(layout.neighbor(of: "b", direction: .down), "c")
		XCTAssertEqual(layout.neighbor(of: "c", direction: .up), "b")
		XCTAssertEqual(layout.neighbor(of: "c", direction: .left), "a")
		XCTAssertNil(layout.neighbor(of: "a", direction: .left))
	}

	func testSwapReplaceAndCodableRoundTrip() throws {
		var layout = Layout("a", adding: "b")
		XCTAssertTrue(layout.swap("a", "b"))
		XCTAssertEqual(layout.paneIDs, ["b", "a"])
		XCTAssertTrue(layout.replace("a", with: "z"))
		XCTAssertEqual(layout.paneIDs, ["b", "z"])
		let data = try JSONEncoder().encode(layout)
		XCTAssertEqual(try JSONDecoder().decode(Layout.self, from: data), layout)
	}
}

final class SpatialDropTargetTests: XCTestCase {
	private let rect = CGRect(x: 100, y: 100, width: 200, height: 100)

	func testEdgesAndCenter() {
		XCTAssertEqual(SpatialDropTarget.resolve(point: CGPoint(x: 105, y: 150), in: rect), .edge(.left))
		XCTAssertEqual(SpatialDropTarget.resolve(point: CGPoint(x: 295, y: 150), in: rect), .edge(.right))
		XCTAssertEqual(SpatialDropTarget.resolve(point: CGPoint(x: 200, y: 104), in: rect), .edge(.top))
		XCTAssertEqual(SpatialDropTarget.resolve(point: CGPoint(x: 200, y: 196), in: rect), .edge(.bottom))
		XCTAssertEqual(SpatialDropTarget.resolve(point: CGPoint(x: 200, y: 150), in: rect), .center)
		XCTAssertNil(SpatialDropTarget.resolve(point: .zero, in: rect))
	}

	func testPreviewRects() {
		XCTAssertEqual(SpatialDropTarget.edge(.right).previewRect(in: rect), CGRect(x: 200, y: 100, width: 100, height: 100))
		XCTAssertEqual(SpatialDropTarget.edge(.top).previewRect(in: rect), CGRect(x: 100, y: 100, width: 200, height: 50))
	}
}

final class SpatialOverviewGridTests: XCTestCase {
	private let bounds = CGRect(x: 0, y: 0, width: 1400, height: 900)

	func testFramesStayInsideAvailableAreaAndDoNotOverlap() {
		for count in 1 ... 24 {
			let grid = SpatialOverviewGrid(bounds: bounds, itemCount: count, thumbnailAspectRatio: 16 / 10)
			XCTAssertEqual(grid.frames.count, count)
			let available = CGRect(x: 48, y: 96, width: 1400 - 96, height: 900 - 208)
			for (index, frame) in grid.frames.enumerated() {
				XCTAssertTrue(available.insetBy(dx: -1, dy: -1).contains(frame), "count \(count) index \(index) \(frame)")
				for other in grid.frames[(index + 1)...] {
					XCTAssertFalse(frame.intersects(other), "count \(count)")
				}
			}
		}
	}

	func testCardsRespectMaximumWidthAndAspect() {
		let grid = SpatialOverviewGrid(bounds: bounds, itemCount: 2, thumbnailAspectRatio: 2, captionHeight: 30, maximumCardWidth: 400)
		XCTAssertEqual(grid.cardSize.width, 400)
		XCTAssertEqual(grid.cardSize.height, 230)
	}

	func testKeyboardNavigation() {
		let grid = SpatialOverviewGrid(bounds: bounds, itemCount: 7, thumbnailAspectRatio: 16 / 10)
		let columns = grid.columns
		XCTAssertGreaterThan(columns, 1)
		XCTAssertEqual(grid.index(movingFrom: 0, direction: .left), 0)
		XCTAssertEqual(grid.index(movingFrom: 0, direction: .right), 1)
		XCTAssertEqual(grid.index(movingFrom: 0, direction: .down), min(columns, 6))
		XCTAssertEqual(grid.index(movingFrom: 0, direction: .up), 0)
		XCTAssertEqual(grid.index(movingFrom: 6, direction: .right), 6)
	}

	func testEmptyGrid() {
		let grid = SpatialOverviewGrid(bounds: bounds, itemCount: 0, thumbnailAspectRatio: 1.6)
		XCTAssertTrue(grid.frames.isEmpty)
		XCTAssertNil(grid.index(at: CGPoint(x: 10, y: 10)))
	}

	func testFilter() {
		XCTAssertTrue(SpatialOverviewFilter.matches(query: "", title: "x", url: "y"))
		XCTAssertTrue(SpatialOverviewFilter.matches(query: "git nav", title: "Navigator", url: "https://github.com"))
		XCTAssertFalse(SpatialOverviewFilter.matches(query: "figma", title: "Navigator", url: "https://github.com"))
	}
}

final class SpatialPinchInterpreterTests: XCTestCase {
	func testSlowPinchCommitsPastThreshold() {
		var pinch = SpatialPinchInterpreter(direction: .zoomOut, fullTravel: 0.4, commitThreshold: 0.35, flickVelocity: 100)
		for step in 0 ..< 10 {
			pinch.update(magnificationDelta: -0.02, timestamp: Double(step) * 0.1)
		}
		XCTAssertEqual(pinch.progress, 0.5, accuracy: 0.001)
		XCTAssertEqual(pinch.outcome(), .commit)
	}

	func testShortPinchCancels() {
		var pinch = SpatialPinchInterpreter(direction: .zoomOut, fullTravel: 0.4, commitThreshold: 0.35, flickVelocity: 100)
		pinch.update(magnificationDelta: -0.05, timestamp: 0)
		pinch.update(magnificationDelta: -0.02, timestamp: 0.2)
		XCTAssertEqual(pinch.outcome(), .cancel)
	}

	func testFlickCommitsEarly() {
		var pinch = SpatialPinchInterpreter(direction: .zoomOut, fullTravel: 0.4, commitThreshold: 0.9, flickVelocity: 1)
		pinch.update(magnificationDelta: -0.03, timestamp: 0)
		pinch.update(magnificationDelta: -0.05, timestamp: 0.016)
		pinch.update(magnificationDelta: -0.05, timestamp: 0.032)
		XCTAssertEqual(pinch.outcome(), .commit)
	}

	func testReverseDirectionClampsAndRubberBands() {
		var pinch = SpatialPinchInterpreter(direction: .zoomOut, fullTravel: 0.4)
		pinch.update(magnificationDelta: 0.2, timestamp: 0)
		XCTAssertEqual(pinch.progress, 0)
		pinch.update(magnificationDelta: -1.2, timestamp: 0.1)
		XCTAssertEqual(pinch.progress, 1)
		XCTAssertGreaterThan(pinch.rubberBandedProgress, 1)
		XCTAssertLessThan(pinch.rubberBandedProgress, 1.3)
	}

	func testClaims() {
		XCTAssertTrue(SpatialPinchInterpreter.claims(direction: .zoomOut, firstDelta: -0.01))
		XCTAssertFalse(SpatialPinchInterpreter.claims(direction: .zoomOut, firstDelta: 0.01))
	}
}

@testable import BrowserView
import QuartzCore
import XCTest

final class BrowserLinkPeekHitTestTests: XCTestCase {
	func testParsesFoundHTTPSLink() {
		let json = #"{"found":true,"href":"https://example.com/a","title":"Example","rect":{"x":0.1,"y":0.2,"w":0.3,"h":0.05}}"#
		let link = BrowserLinkPeekHitTest.parse(json)
		XCTAssertEqual(link?.url, "https://example.com/a")
		XCTAssertEqual(link?.title, "Example")
		XCTAssertEqual(link?.normalizedRect, .init(x: 0.1, y: 0.2, w: 0.3, h: 0.05))
	}

	func testIgnoresMissesNonWebSchemesAndGarbage() {
		XCTAssertNil(BrowserLinkPeekHitTest.parse(#"{"found":false}"#))
		XCTAssertNil(BrowserLinkPeekHitTest.parse(#"{"found":true,"href":"javascript:void(0)"}"#))
		XCTAssertNil(BrowserLinkPeekHitTest.parse(#"{"found":true,"href":"mailto:a@b.c"}"#))
		XCTAssertNil(BrowserLinkPeekHitTest.parse("not json"))
		XCTAssertNil(BrowserLinkPeekHitTest.parse(nil))
	}

	func testEmptyTitleBecomesNil() {
		let link = BrowserLinkPeekHitTest.parse(#"{"found":true,"href":"http://example.com","title":""}"#)
		XCTAssertEqual(link?.url, "http://example.com")
		XCTAssertNil(link?.title)
	}

	func testScriptClampsAndEmbedsPoint() {
		let script = BrowserLinkPeekHitTest.script(fx: 0.25, fy: 2)
		XCTAssertTrue(script.hasSuffix("})(0.25, 1.0)"))
		XCTAssertTrue(BrowserLinkPeekHitTest.script(fx: .nan, fy: -1).hasSuffix("})(0.0, 0.0)"))
	}
}

final class BrowserLinkPeekGeometryTests: XCTestCase {
	func testCardFrameIsCenteredAndKeepsAspect() {
		let bounds = CGRect(x: 0, y: 0, width: 1000, height: 800)
		let card = BrowserLinkPeekGeometry.cardFrame(in: bounds)
		XCTAssertEqual(card.midX, bounds.midX, accuracy: 1)
		XCTAssertEqual(card.midY, bounds.midY, accuracy: 1)
		XCTAssertEqual(card.width / card.height, bounds.width / bounds.height, accuracy: 0.01)
	}

	func testCardFrameNeverExceedsBounds() {
		let bounds = CGRect(x: 0, y: 0, width: 300, height: 200)
		let card = BrowserLinkPeekGeometry.cardFrame(in: bounds)
		XCTAssertTrue(bounds.contains(card))
	}

	func testTransformScalesAroundCenter() {
		let size = CGSize(width: 200, height: 100)
		let matrix = BrowserLinkPeekGeometry.transform(scale: 0.5, translation: .zero, size: size)
		let affine = CATransform3DGetAffineTransform(matrix)
		let center = CGPoint(x: 100, y: 50).applying(affine)
		XCTAssertEqual(center.x, 100, accuracy: 0.001)
		XCTAssertEqual(center.y, 50, accuracy: 0.001)
		let corner = CGPoint.zero.applying(affine)
		XCTAssertEqual(corner.x, 50, accuracy: 0.001)
		XCTAssertEqual(corner.y, 25, accuracy: 0.001)
	}

	func testTransformFromCardToTargetMapsCorners() {
		let card = CGRect(x: 100, y: 100, width: 200, height: 100)
		let target = CGRect(x: 0, y: 0, width: 400, height: 200)
		let affine = CATransform3DGetAffineTransform(BrowserLinkPeekGeometry.transform(from: card, to: target))
		// Layer-local corners of the card should land on the target's corners, relative to the card origin.
		let topRight = CGPoint(x: card.width, y: card.height).applying(affine)
		XCTAssertEqual(topRight.x + card.minX, target.maxX, accuracy: 0.001)
		XCTAssertEqual(topRight.y + card.minY, target.maxY, accuracy: 0.001)
		let origin = CGPoint.zero.applying(affine)
		XCTAssertEqual(origin.x + card.minX, target.minX, accuracy: 0.001)
		XCTAssertEqual(origin.y + card.minY, target.minY, accuracy: 0.001)
	}

	func testReleaseOutcome() {
		let height: CGFloat = 500
		XCTAssertEqual(BrowserLinkPeekGeometry.releaseOutcome(translation: 10, velocity: 0, cardHeight: height), .settle)
		XCTAssertEqual(BrowserLinkPeekGeometry.releaseOutcome(translation: 120, velocity: 0, cardHeight: height), .promote)
		XCTAssertEqual(BrowserLinkPeekGeometry.releaseOutcome(translation: 20, velocity: 1200, cardHeight: height), .promote)
		XCTAssertEqual(BrowserLinkPeekGeometry.releaseOutcome(translation: -150, velocity: 0, cardHeight: height), .dismiss)
		XCTAssertEqual(BrowserLinkPeekGeometry.releaseOutcome(translation: -20, velocity: -1200, cardHeight: height), .dismiss)
		// A flick against the drag direction should not trigger.
		XCTAssertEqual(BrowserLinkPeekGeometry.releaseOutcome(translation: -20, velocity: 1200, cardHeight: height), .settle)
	}

	func testRubberBandIsMonotonicAndBounded() {
		let limit: CGFloat = 100
		var previous: CGFloat = 0
		for offset in stride(from: CGFloat(10), through: 2000, by: 10) {
			let value = BrowserLinkPeekGeometry.rubberBand(offset, limit: limit)
			XCTAssertGreaterThan(value, previous)
			XCTAssertLessThan(value, limit)
			previous = value
		}
		XCTAssertEqual(BrowserLinkPeekGeometry.rubberBand(-50, limit: limit), -BrowserLinkPeekGeometry.rubberBand(50, limit: limit))
	}

	func testNormalizedRoundTrip() {
		let bounds = CGRect(x: 0, y: 0, width: 800, height: 600)
		let normalized = BrowserLinkPeekHitTest.NormalizedRect(x: 0.25, y: 0.1, w: 0.5, h: 0.05)
		let unflipped = BrowserLinkPeekGeometry.viewRect(for: normalized, in: bounds, isFlipped: false)
		XCTAssertEqual(unflipped, CGRect(x: 200, y: 510, width: 400, height: 30))
		let flipped = BrowserLinkPeekGeometry.viewRect(for: normalized, in: bounds, isFlipped: true)
		XCTAssertEqual(flipped, CGRect(x: 200, y: 60, width: 400, height: 30))

		let point = BrowserLinkPeekGeometry.normalizedPoint(for: CGPoint(x: 400, y: 450), in: bounds, isFlipped: false)
		XCTAssertEqual(point?.x ?? -1, 0.5, accuracy: 0.0001)
		XCTAssertEqual(point?.y ?? -1, 0.25, accuracy: 0.0001)
		XCTAssertNil(BrowserLinkPeekGeometry.normalizedPoint(for: CGPoint(x: -1, y: 0), in: bounds, isFlipped: false))
	}
}

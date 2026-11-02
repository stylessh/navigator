@testable import BrowserView
import XCTest

final class BrowserLinkHintLabelGeneratorTests: XCTestCase {
	func testReturnsNoLabelsForZeroTargets() {
		XCTAssertEqual(BrowserLinkHintLabelGenerator.labels(count: 0), [])
	}

	func testUsesSingleCharactersWhenTheyFit() {
		let labels = BrowserLinkHintLabelGenerator.labels(count: 5)
		XCTAssertEqual(labels.count, 5)
		XCTAssertTrue(labels.allSatisfy { $0.count == 1 })
		XCTAssertEqual(Set(labels).count, 5)
	}

	func testLabelsArePrefixFreeAndUnique() {
		for count in [1, 2, 13, 14, 15, 50, 196, 197, 600] {
			let labels = BrowserLinkHintLabelGenerator.labels(count: count)
			XCTAssertEqual(labels.count, count, "count \(count)")
			XCTAssertEqual(Set(labels).count, count, "duplicates for count \(count)")
			for label in labels {
				for other in labels where other != label {
					XCTAssertFalse(other.hasPrefix(label), "\(label) is a prefix of \(other) (count \(count))")
				}
			}
		}
	}

	func testKeepsLabelsShort() {
		let alphabetCount = BrowserLinkHintLabelGenerator.defaultAlphabet.count
		let twoCharacterCapacity = alphabetCount * alphabetCount
		let labels = BrowserLinkHintLabelGenerator.labels(count: twoCharacterCapacity)
		XCTAssertTrue(labels.allSatisfy { $0.count <= 2 })
	}

	func testOnlyUsesAlphabetCharacters() {
		let alphabet = Set(BrowserLinkHintLabelGenerator.defaultAlphabet)
		let labels = BrowserLinkHintLabelGenerator.labels(count: 300)
		XCTAssertTrue(labels.allSatisfy { $0.allSatisfy(alphabet.contains) })
	}
}

final class BrowserLinkHintSessionTests: XCTestCase {
	private func makeCollection(count: Int) -> BrowserLinkHintCollection {
		BrowserLinkHintCollection(
			viewport: .init(width: 1000, height: 800),
			targets: (0..<count).map { index in
				BrowserLinkHintTarget(x: CGFloat(index * 10), y: 10, width: 40, height: 20, kind: .link)
			}
		)
	}

	func testDecodesCollectionFromPageJSON() throws {
		let json = """
		{"viewport":{"width":1280,"height":720},"targets":[{"x":1,"y":2,"width":30,"height":40,"kind":"input"},{"x":5,"y":6,"width":7,"height":8,"kind":"weird"}]}
		"""
		let collection = try XCTUnwrap(BrowserLinkHintCollection.from(json: json))
		XCTAssertEqual(collection.viewport.width, 1280)
		XCTAssertEqual(collection.targets.count, 2)
		XCTAssertEqual(collection.targets[0].rect, CGRect(x: 1, y: 2, width: 30, height: 40))
		XCTAssertEqual(collection.targets[0].kind, .input)
		XCTAssertEqual(collection.targets[1].kind, .button, "unknown kinds fall back to button")
	}

	func testSingleCharacterLabelActivatesImmediately() {
		var session = BrowserLinkHintSession(collection: makeCollection(count: 3), openInNewTab: false)
		let hint = session.hints[1]
		XCTAssertEqual(session.type(hint.label.uppercased()), .activate(hint))
	}

	func testTwoCharacterLabelsFilterThenActivate() {
		var session = BrowserLinkHintSession(collection: makeCollection(count: 40), openInNewTab: true)
		let target = session.hints.first { $0.label.count == 2 }!
		let first = String(target.label.prefix(1))

		guard case let .filtered(matching, prefix) = session.type(first) else {
			return XCTFail("expected filtering after the first character")
		}
		XCTAssertEqual(prefix, first)
		XCTAssertTrue(matching.contains(target))
		XCTAssertTrue(matching.allSatisfy { $0.label.hasPrefix(first) })

		XCTAssertEqual(session.type(String(target.label.suffix(1))), .activate(target))
		XCTAssertTrue(session.openInNewTab)
	}

	func testNonMatchingKeysAreRejectedWithoutChangingState() {
		var session = BrowserLinkHintSession(collection: makeCollection(count: 3), openInNewTab: false)
		XCTAssertEqual(session.type("z"), .rejected)
		XCTAssertEqual(session.type("1"), .rejected)
		XCTAssertEqual(session.type("ab"), .rejected)
		XCTAssertEqual(session.typedPrefix, "")
	}

	func testDeleteBackwardRestoresMatchesThenDismisses() {
		var session = BrowserLinkHintSession(collection: makeCollection(count: 40), openInNewTab: false)
		let target = session.hints.first { $0.label.count == 2 }!
		_ = session.type(String(target.label.prefix(1)))

		guard case let .filtered(matching, prefix) = session.deleteBackward() else {
			return XCTFail("expected filtering after delete")
		}
		XCTAssertEqual(prefix, "")
		XCTAssertEqual(matching, session.hints)
		XCTAssertEqual(session.deleteBackward(), .dismissed)
	}

	@MainActor
	func testChipFramePlacementStaysInsideBounds() {
		let bounds = CGRect(x: 0, y: 0, width: 300, height: 200)
		let size = CGSize(width: 24, height: 18)

		let small = BrowserLinkHintOverlayView.chipFrame(
			size: size,
			targetRect: CGRect(x: 100, y: 50, width: 80, height: 20),
			bounds: bounds
		)
		XCTAssertEqual(small.midY, 60, accuracy: 1)
		XCTAssertEqual(small.minX, 96, accuracy: 1)

		let offscreen = BrowserLinkHintOverlayView.chipFrame(
			size: size,
			targetRect: CGRect(x: -50, y: 190, width: 20, height: 20),
			bounds: bounds
		)
		XCTAssertTrue(bounds.contains(offscreen))
	}
}

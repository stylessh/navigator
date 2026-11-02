@testable import BrowserView
import Foundation
import XCTest

final class BrowserSiteTintColorTests: XCTestCase {
	func testHexParsing() {
		XCTAssertEqual(BrowserSiteTintColor(hex: "#ff0000"), .init(red: 1, green: 0, blue: 0))
		XCTAssertEqual(BrowserSiteTintColor(hex: "0f0"), .init(red: 0, green: 1, blue: 0))
		XCTAssertEqual(BrowserSiteTintColor(hex: "#0000FF80")?.alpha ?? 0, 128.0 / 255, accuracy: 0.001)
		XCTAssertNil(BrowserSiteTintColor(hex: "#zzz"))
		XCTAssertNil(BrowserSiteTintColor(hex: "#12345"))
		XCTAssertEqual(BrowserSiteTintColor(hex: "#1DA1F2")?.hexString, "#1DA1F2")
	}

	func testNeutralDetection() {
		XCTAssertTrue(BrowserSiteTintColor(hex: "#ffffff")!.isNeutral)
		XCTAssertTrue(BrowserSiteTintColor(hex: "#000000")!.isNeutral)
		XCTAssertTrue(BrowserSiteTintColor(hex: "#fafafa")!.isNeutral)
		XCTAssertTrue(BrowserSiteTintColor(red: 1, green: 0, blue: 0, alpha: 0.2).isNeutral)
		XCTAssertFalse(BrowserSiteTintColor(hex: "#ff0000")!.isNeutral)
		XCTAssertFalse(BrowserSiteTintColor(hex: "#24292f")!.isNeutral)
	}

	func testDarkAppearanceSoftensBrightColors() {
		let yellow = BrowserSiteTintColor(hex: "#ffe600")!
		XCTAssertLessThan(yellow.adjusted(forDarkAppearance: true).relativeLuminance, yellow.relativeLuminance)
		XCTAssertEqual(yellow.adjusted(forDarkAppearance: false), yellow)
	}
}

final class BrowserSiteTintResolverTests: XCTestCase {
	private let red = BrowserSiteTintColor(hex: "#cc0000")!
	private let blue = BrowserSiteTintColor(hex: "#0044cc")!
	private let white = BrowserSiteTintColor(hex: "#ffffff")!

	func testThemeColorWins() {
		let sample = BrowserSiteTintSample(themeColor: red, bottomEdge: blue, pageBackground: blue)
		let tint = BrowserSiteTintResolver.resolve(sample: sample, override: nil, isDarkAppearance: false)
		XCTAssertEqual(tint, .init(color: red, source: .themeColor))
	}

	func testNeutralThemeFallsBackToSampledEdge() {
		let sample = BrowserSiteTintSample(themeColor: white, bottomEdge: blue)
		let tint = BrowserSiteTintResolver.resolve(sample: sample, override: nil, isDarkAppearance: false)
		XCTAssertEqual(tint?.source, .bottomEdge)
	}

	func testPlainPageStaysNeutral() {
		let sample = BrowserSiteTintSample(bottomEdge: white, topEdge: white, pageBackground: white)
		XCTAssertNil(BrowserSiteTintResolver.resolve(sample: sample, override: nil, isDarkAppearance: false))
	}

	func testOverrides() {
		let sample = BrowserSiteTintSample(themeColor: red)
		XCTAssertNil(BrowserSiteTintResolver.resolve(sample: sample, override: .disabled, isDarkAppearance: false))
		XCTAssertEqual(
			BrowserSiteTintResolver.resolve(sample: sample, override: .color(blue), isDarkAppearance: false),
			.init(color: blue, source: .userOverride)
		)
		XCTAssertEqual(
			BrowserSiteTintResolver.resolve(sample: nil, override: .color(blue), isDarkAppearance: false)?.source,
			.userOverride
		)
	}
}

final class BrowserSiteTintSamplerTests: XCTestCase {
	func testDecodesSamplerPayload() {
		let json = #"{"theme":[29,161,242,255],"bottom":null,"top":[255,255,255,255],"background":[0,0,0,255]}"#
		let sample = BrowserSiteTintSampler.decode(json)
		XCTAssertEqual(sample?.themeColor?.hexString, "#1DA1F2")
		XCTAssertNil(sample?.bottomEdge)
		XCTAssertEqual(sample?.topEdge?.hexString, "#FFFFFF")
	}

	func testDecodesDoubleEncodedPayload() {
		let inner = #"{"theme":[204,0,0,255]}"#
		let data = try! JSONSerialization.data(withJSONObject: inner, options: .fragmentsAllowed)
		let sample = BrowserSiteTintSampler.decode(String(data: data, encoding: .utf8)!)
		XCTAssertEqual(sample?.themeColor?.hexString, "#CC0000")
	}

	func testDecodesPageMessage() {
		let message = BrowserSiteTintSampler.decodeMessage(#"{"kind":"siteTint","token":7,"theme":[29,161,242,255]}"#)
		XCTAssertEqual(message?.token, 7)
		XCTAssertEqual(message?.sample?.themeColor?.hexString, "#1DA1F2")
		XCTAssertNil(BrowserSiteTintSampler.decodeMessage(#"{"kind":"pip"}"#))
	}

	func testScriptEmbedsTokenAndPageCommand() {
		let script = BrowserSiteTintSampler.script(token: 42)
		XCTAssertTrue(script.contains("payload.token = 42;"))
		XCTAssertTrue(script.contains("__navigatorPageCommand__"))
		XCTAssertTrue(script.contains("'siteTint.sample', { payload: json }"))
	}

	func testRejectsErrors() {
		XCTAssertNil(BrowserSiteTintSampler.decode(#"{"error":"boom"}"#))
		XCTAssertNil(BrowserSiteTintSampler.decode("not json"))
		// What the fire-and-forget browser-process evaluation answers.
		XCTAssertNil(BrowserSiteTintSampler.decode(#"{"dispatched":true}"#))
	}
}

@MainActor
final class BrowserSiteTintStoreTests: XCTestCase {
	private let tabA = UUID()
	private let tabB = UUID()
	private let red = BrowserSiteTintColor(hex: "#cc0000")!
	private let blue = BrowserSiteTintColor(hex: "#0044cc")!

	func testPublishesSelectedTabTint() {
		let store = BrowserSiteTintStore(overrides: .init(), isEnabled: true)
		var changes = [BrowserSiteTint?]()
		store.onTintChange = { changes.append($0) }
		store.noteURL("https://a.example/", for: tabA)
		store.record(.init(themeColor: red), for: tabA)
		store.noteURL("https://b.example/", for: tabB)
		store.record(.init(themeColor: blue), for: tabB)
		XCTAssertNil(store.currentTint)

		store.selectTab(tabA)
		XCTAssertEqual(store.currentTint?.color, red)
		store.selectTab(tabB)
		XCTAssertEqual(store.currentTint?.color, blue)
		XCTAssertEqual(changes.count, 2)
	}

	func testNavigationKeepsPreviousColorUntilNextSample() {
		let store = BrowserSiteTintStore(overrides: .init(), isEnabled: true)
		var changes = [BrowserSiteTint?]()
		store.onTintChange = { changes.append($0) }
		store.selectTab(tabA)
		store.noteURL("https://a.example/one", for: tabA)
		store.record(.init(themeColor: red), for: tabA)
		store.noteURL("https://other.example/", for: tabA)
		XCTAssertEqual(store.currentTint?.color, red, "no dip to neutral mid-navigation")
		store.record(.init(themeColor: blue), for: tabA)
		XCTAssertEqual(store.currentTint?.color, blue)
		XCTAssertEqual(changes.map { $0?.color }, [red, blue])
	}

	func testOverrideForNewHostAppliesOnNavigation() {
		let overrides = BrowserSiteTintOverrides()
		overrides.setOverride(.disabled, forHost: "other.example")
		let store = BrowserSiteTintStore(overrides: overrides, isEnabled: true)
		store.selectTab(tabA)
		store.noteURL("https://a.example/", for: tabA)
		store.record(.init(themeColor: red), for: tabA)
		store.noteURL("https://other.example/", for: tabA)
		XCTAssertNil(store.currentTint)
	}

	func testHostOverrideAppliesAndClears() {
		let overrides = BrowserSiteTintOverrides()
		let store = BrowserSiteTintStore(overrides: overrides, isEnabled: true)
		store.selectTab(tabA)
		store.noteURL("https://a.example/", for: tabA)
		store.record(.init(themeColor: red), for: tabA)

		overrides.setOverride(.disabled, forHost: "www.A.example")
		let expectation = expectation(description: "override observed")
		DispatchQueue.main.async { expectation.fulfill() }
		wait(for: [expectation], timeout: 1)
		XCTAssertNil(store.currentTint)

		overrides.setOverride(nil, forHost: "a.example")
		let cleared = self.expectation(description: "override cleared")
		DispatchQueue.main.async { cleared.fulfill() }
		wait(for: [cleared], timeout: 1)
		XCTAssertEqual(store.currentTint?.color, red)
	}

	func testDisabledStorePublishesNothing() {
		let store = BrowserSiteTintStore(overrides: .init(), isEnabled: false)
		store.selectTab(tabA)
		store.record(.init(themeColor: red), for: tabA)
		XCTAssertNil(store.currentTint)
		store.isEnabled = true
		XCTAssertEqual(store.currentTint?.color, red)
	}
}

@MainActor
final class BrowserSiteTintSamplingCoordinatorTests: XCTestCase {
	private func tokens(in scripts: [String]) -> [Int] {
		scripts.compactMap { script in
			guard let range = script.range(of: "payload.token = ") else { return nil }
			return Int(script[range.upperBound...].prefix { $0.isNumber })
		}
	}

	func testDropsStaleResultsAndIgnoresOtherMessages() {
		let tab = UUID()
		var scripts = [String]()
		let coordinator = BrowserSiteTintSamplingCoordinator(
			evaluate: { _, script in scripts.append(script) },
			scheduler: { _, _ in {} }
		)
		let store = BrowserSiteTintStore(overrides: .init(), isEnabled: true)
		coordinator.store = store
		coordinator.tabSelected(tab)
		coordinator.titleChanged(for: tab)
		let issued = tokens(in: scripts)
		XCTAssertEqual(issued.count, 2)

		XCTAssertFalse(coordinator.handlePageMessage(#"{"kind":"other"}"#, for: tab))
		XCTAssertTrue(coordinator.handlePageMessage(
			#"{"kind":"siteTint","token":\#(issued[0]),"theme":[204,0,0,255]}"#,
			for: tab
		))
		XCTAssertNil(store.currentTint, "stale token must be dropped")
		coordinator.handlePageMessage(#"{"kind":"siteTint","token":\#(issued[1]),"theme":[0,68,204,255]}"#, for: tab)
		XCTAssertEqual(store.currentTint?.color.hexString, "#0044CC")
	}

	func testNavigationSchedulesResamples() {
		let tab = UUID()
		var scheduled = [TimeInterval]()
		let coordinator = BrowserSiteTintSamplingCoordinator(
			evaluate: { _, _ in },
			scheduler: { delay, _ in
				scheduled.append(delay)
				return {}
			}
		)
		coordinator.store = BrowserSiteTintStore(overrides: .init(), isEnabled: true)
		coordinator.navigationCommitted("https://a.example/", for: tab)
		XCTAssertEqual(scheduled, BrowserSiteTintSampler.resampleDelays)
	}

	func testWaitsForLoadBeforeSampling() {
		let tab = UUID()
		var isLoading = true
		var evaluated = 0
		var pending = [() -> Void]()
		let coordinator = BrowserSiteTintSamplingCoordinator(
			evaluate: { _, _ in evaluated += 1 },
			canSample: { _ in !isLoading },
			scheduler: { _, action in
				pending.append(action)
				return {}
			}
		)
		coordinator.store = BrowserSiteTintStore(overrides: .init(), isEnabled: true)
		coordinator.tabSelected(tab)
		coordinator.titleChanged(for: tab)
		XCTAssertEqual(evaluated, 0)
		XCTAssertEqual(pending.count, 1, "triggers during a load fold into one deferred sample")
		isLoading = false
		pending.removeFirst()()
		XCTAssertEqual(evaluated, 1)
	}
}

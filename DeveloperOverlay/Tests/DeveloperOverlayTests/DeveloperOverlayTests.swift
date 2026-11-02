@testable import DeveloperOverlay
import XCTest

final class DeveloperOverlayPayloadTests: XCTestCase {
	func testParsesPayloadFromAgentJSON() throws {
		let json = """
		{"v":1,"rev":7,"console":[{"id":3,"rev":5,"level":"warn","text":"careful","source":"app.js","ts":1700000000000}],
		"network":[{"id":"f1","rev":6,"kind":"fetch","method":"POST","url":"https://api.example.com/v1/items?x=1","start":12.5,"status":201,"duration":40.2,"size":512,"mime":"application/json"}],
		"picked":{"value":{"selector":"#app > button","tag":"button","id":null,"classes":["btn"],"rect":{"x":1,"y":2,"w":48,"h":32},
		"margin":{"t":4,"r":4,"b":4,"l":4},"padding":{"t":8,"r":16,"b":8,"l":16},"border":{"t":0,"r":0,"b":0,"l":0},
		"styles":{"display":"block","color":"rgb(0, 0, 0)"},"text":"Hi","children":0}},
		"picking":false,"url":"https://example.com/","title":"Example","viewport":{"w":393,"h":852,"dpr":3},"theme":"rgb(255, 85, 0)"}
		"""
		guard case let .payload(payload) = DeveloperOverlayPayload.parsePoll(result: json, error: nil) else {
			return XCTFail("Expected payload")
		}
		XCTAssertEqual(payload.revision, 7)
		XCTAssertEqual(payload.console.first?.id, "page-3")
		XCTAssertEqual(payload.console.first?.level, .warn)
		XCTAssertEqual(payload.network.first?.status, 201)
		XCTAssertEqual(payload.network.first?.displayName, "items?x=1")
		XCTAssertEqual(payload.network.first?.host, "api.example.com")
		let element = try XCTUnwrap(payload.picked?.value)
		XCTAssertEqual(element.selector, "#app > button")
		XCTAssertEqual(element.padding.shorthand, "8 16")
		XCTAssertEqual(element.margin.shorthand, "4")
		XCTAssertTrue(element.border.isZero)
		XCTAssertEqual(payload.viewport?.devicePixelRatio, 3)
		XCTAssertEqual(payload.themeColor, "rgb(255, 85, 0)")
		XCTAssertNotNil(DeveloperFormat.tint(fromCSS: "rgb(255, 85, 0)"))
		XCTAssertNil(DeveloperFormat.tint(fromCSS: "rgb(255, 255, 255)"))
	}

	func testMissingSentinelAndErrors() {
		XCTAssertEqual(
			DeveloperOverlayPayload.parsePoll(result: DeveloperOverlayAgentScript.missingSentinel, error: nil),
			.agentMissing
		)
		XCTAssertEqual(DeveloperOverlayPayload.parsePoll(result: nil, error: "boom"), .failure("boom"))
		if case .failure = DeveloperOverlayPayload.parsePoll(result: "{not json", error: nil) {} else {
			XCTFail("Expected failure")
		}
	}

	func testUnknownLevelsAndKindsFallBack() throws {
		let json = #"{"rev":1,"console":[{"id":1,"level":"trace","text":"x","ts":0}],"network":[{"id":"t1","kind":"ping","url":"u"}]}"#
		guard case let .payload(payload) = DeveloperOverlayPayload.parsePoll(result: json, error: nil) else {
			return XCTFail("Expected payload")
		}
		XCTAssertEqual(payload.console.first?.level, .log)
		XCTAssertEqual(payload.network.first?.kind, .other)
		XCTAssertTrue(payload.network.first?.isPending == true)
	}

	func testEvaluationResultParsing() {
		XCTAssertEqual(
			DeveloperEvaluationResult.parse(result: #"{"ok":false,"text":"SyntaxError"}"#, error: nil),
			DeveloperEvaluationResult(ok: false, text: "SyntaxError")
		)
		XCTAssertEqual(DeveloperEvaluationResult.parse(result: nil, error: "timeout").ok, false)
		XCTAssertTrue(
			DeveloperEvaluationResult.parse(result: #"{"ok":false,"blocked":true,"text":"EvalError"}"#, error: nil).isBlockedByCSP
		)
	}
}

final class DeveloperOverlayAgentScriptTests: XCTestCase {
	func testStringLiteralEscapesQuotesNewlinesAndLineSeparators() {
		XCTAssertEqual(DeveloperOverlayAgentScript.jsStringLiteral("a\"b\nc"), #""a\"b\nc""#)
		XCTAssertEqual(DeveloperOverlayAgentScript.jsStringLiteral("x\u{2028}y"), #""x\u2028y""#)
	}

	func testInlineEvaluationEmbedsSourceAsExpression() {
		let script = DeveloperOverlayAgentScript.evaluateInline("document.title // trailing comment")
		XCTAssertTrue(script.contains("evaluateInline(function () { return ("))
		XCTAssertTrue(script.contains("\ndocument.title // trailing comment\n); });"))
	}

	func testPollScriptReferencesRevisionAndSentinel() {
		let script = DeveloperOverlayAgentScript.poll(since: 42)
		XCTAssertTrue(script.contains("drain(42)"))
		XCTAssertTrue(script.contains(DeveloperOverlayAgentScript.missingSentinel))
		XCTAssertTrue(DeveloperOverlayAgentScript.poll(since: -3).contains("drain(0)"))
	}

	func testCallInstallsAgentWhenMissing() {
		let script = DeveloperOverlayAgentScript.evaluate("1 + 1")
		XCTAssertTrue(script.contains("__navigatorDevHUD"))
		XCTAssertTrue(script.contains(#"evaluate("1 + 1")"#))
	}
}

final class DeveloperSpringTests: XCTestCase {
	func testSpringSettlesOnTarget() {
		let spring = DeveloperSpring.morph
		var value = 0.0
		var velocity = 0.0
		for _ in 0..<240 {
			(value, velocity) = spring.step(value: value, velocity: velocity, target: 100, dt: 1.0 / 120.0)
		}
		XCTAssertEqual(value, 100, accuracy: 0.5)
		XCTAssertTrue(DeveloperSpring.isSettled(value: value, velocity: velocity, target: 100))
	}

	func testUnderdampedSpringOvershootsSlightly() {
		let spring = DeveloperSpring(response: 0.4, dampingFraction: 0.6)
		var value = 0.0
		var velocity = 0.0
		var peak = 0.0
		for _ in 0..<240 {
			(value, velocity) = spring.step(value: value, velocity: velocity, target: 100, dt: 1.0 / 120.0)
			peak = max(peak, value)
		}
		XCTAssertGreaterThan(peak, 100)
		XCTAssertLessThan(peak, 125)
	}
}

@MainActor
final class DeveloperOverlayModelTests: XCTestCase {
	@MainActor
	private final class FakePage {
		var identity: AnyHashable? = "tab-1"
		var scripts: [String] = []
		var nextResults: [(String?, String?)] = []

		var bridge: DeveloperOverlayPageBridge {
			DeveloperOverlayPageBridge(
				currentPageIdentity: { [unowned self] in self.identity },
				evaluate: { [unowned self] script, completion in
					self.scripts.append(script)
					let result = self.nextResults.isEmpty ? (nil, nil) : self.nextResults.removeFirst()
					completion(result.0, result.1)
				}
			)
		}
	}

	private func payload(_ json: String) -> DeveloperOverlayPayload.PollResult {
		DeveloperOverlayPayload.parsePoll(result: json, error: nil)
	}

	func testMergesFoldsRepeatsAndCountsUnseenErrors() {
		let model = DeveloperOverlayModel()
		model.isEnabled = false
		model.apply(payload(#"{"rev":3,"console":[{"id":1,"level":"error","text":"x","ts":0},{"id":2,"level":"error","text":"x","ts":0},{"id":3,"level":"log","text":"y","ts":0}]}"#))
		XCTAssertEqual(model.consoleEntries.count, 2)
		XCTAssertEqual(model.consoleEntries.first?.repeatCount, 2)
		XCTAssertEqual(model.errorCount, 2)
		XCTAssertEqual(model.unseenErrorCount, 2)

		model.togglePanel(tab: .console)
		XCTAssertEqual(model.unseenErrorCount, 0)
	}

	func testNetworkEntriesAreUpsertedByID() {
		let model = DeveloperOverlayModel()
		model.isEnabled = false
		model.apply(payload(#"{"rev":1,"network":[{"id":"f1","kind":"fetch","url":"https://a.dev/x","start":0}]}"#))
		XCTAssertTrue(model.networkEntries.first?.isPending == true)
		model.apply(payload(#"{"rev":2,"network":[{"id":"f1","kind":"fetch","url":"https://a.dev/x","start":0,"status":500,"duration":12}]}"#))
		XCTAssertEqual(model.networkEntries.count, 1)
		XCTAssertEqual(model.failedRequestCount, 1)
		model.networkFilter = .failed
		XCTAssertEqual(model.filteredNetworkEntries.count, 1)
	}

	func testMissingAgentAfterDataInsertsNavigationSeparatorAndReinstalls() {
		let page = FakePage()
		let model = DeveloperOverlayModel(bridge: page.bridge)
		model.isEnabled = false
		model.apply(payload(#"{"rev":4,"console":[{"id":1,"level":"log","text":"hi","ts":0}],"network":[{"id":"t1","kind":"document","url":"https://a.dev/"}]}"#))
		model.apply(.agentMissing)
		XCTAssertEqual(model.consoleEntries.last?.level, .system)
		XCTAssertTrue(model.networkEntries.isEmpty)
		XCTAssertEqual(page.scripts.last, DeveloperOverlayAgentScript.install)
	}

	func testPickedElementOpensElementTab() {
		let model = DeveloperOverlayModel()
		model.isEnabled = false
		model.apply(payload(#"{"rev":2,"picked":{"value":{"selector":"p","tag":"p","rect":{"x":0,"y":0,"w":10,"h":10}}}}"#))
		XCTAssertEqual(model.inspectedElement?.tag, "p")
		XCTAssertEqual(model.selectedTab, .element)
		XCTAssertTrue(model.isPanelPresented)
	}

	func testPollResetsWhenPageIdentityChanges() async {
		let page = FakePage()
		page.nextResults = [(#"{"rev":1,"console":[{"id":1,"level":"log","text":"a","ts":0}]}"#, nil)]
		let model = DeveloperOverlayModel(bridge: page.bridge)
		model.isEnabled = false
		await model.pollOnce()
		XCTAssertEqual(model.consoleEntries.count, 1)
		page.identity = "tab-2"
		page.nextResults = [(DeveloperOverlayAgentScript.missingSentinel, nil)]
		await model.pollOnce()
		XCTAssertTrue(model.consoleEntries.isEmpty)
	}

	func testPollPausesWhilePageIsLoading() async {
		let page = FakePage()
		var isLoading = true
		var bridge = page.bridge
		bridge.isPageLoading = { isLoading }
		let model = DeveloperOverlayModel(bridge: bridge)
		model.isEnabled = false
		await model.pollOnce()
		XCTAssertTrue(page.scripts.isEmpty)
		isLoading = false
		page.nextResults = [(#"{"rev":1}"#, nil)]
		await model.pollOnce()
		XCTAssertEqual(page.scripts.count, 1)
	}

	func testViewportCyclingAndRotation() {
		let model = DeveloperOverlayModel()
		model.cycleViewport()
		XCTAssertEqual(model.viewportMode.preset, DeveloperViewportPreset.builtIn.first)
		model.rotateViewport()
		XCTAssertEqual(model.viewportMode.orientation, .landscape)
		XCTAssertEqual(model.viewportMode.targetSize?.width, DeveloperViewportPreset.builtIn.first?.size.height)
		model.setViewport(model.viewportMode.preset)
		XCTAssertEqual(model.viewportMode, .responsive)
		model.setCustomViewportSize(CGSize(width: 500.4, height: 700.6))
		XCTAssertEqual(model.viewportMode.targetSize, CGSize(width: 500, height: 701))
	}

	func testConsoleFilter() {
		let model = DeveloperOverlayModel()
		model.isEnabled = false
		model.apply(payload(#"{"rev":2,"console":[{"id":1,"level":"log","text":"apple","ts":0},{"id":2,"level":"warn","text":"banana","ts":0}]}"#))
		model.consoleFilter.text = "ban"
		XCTAssertEqual(model.filteredConsoleEntries.map(\.text), ["banana"])
		model.consoleFilter.text = ""
		model.consoleFilter.showsWarnings = false
		XCTAssertEqual(model.filteredConsoleEntries.map(\.text), ["apple"])
	}
}

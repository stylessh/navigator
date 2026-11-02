@testable import BrowserRuntime
import XCTest

@MainActor
final class BrowserRuntimePageCommandTests: XCTestCase {
	private var nativeRegistrations = [(UnsafeMutableRawPointer?, Bool)]()
	private var browser: UnsafeMutableRawPointer!

	override func setUp() async throws {
		try await super.setUp()
		browser = UnsafeMutableRawPointer.allocate(byteCount: 1, alignment: 1)
		nativeRegistrations = []
		BrowserRuntimePageCommandBridge.setHandler = { [weak self] browser, callback, _ in
			MainActor.assumeIsolated {
				self?.nativeRegistrations.append((browser, callback != nil))
			}
		}
	}

	override func tearDown() async throws {
		BrowserRuntimePageCommandBridge.removeAll(browser: browser)
		BrowserRuntimePageCommandBridge.setHandler = BrowserRuntimePageCommandBridge.liveSetHandler
		browser.deallocate()
		try await super.tearDown()
	}

	func testDecodesCommandWithArguments() {
		let command = BrowserRuntimePageCommand.from(json: #"{"name":"a.b","arguments":{"x":"1"}}"#)
		XCTAssertEqual(command, BrowserRuntimePageCommand(name: "a.b", arguments: ["x": "1"]))
		XCTAssertEqual(BrowserRuntimePageCommand.from(json: #"{"name":"a"}"#)?.arguments, [:])
		XCTAssertNil(BrowserRuntimePageCommand.from(json: "not json"))
	}

	func testMultipleHandlersReceiveMatchingCommands() {
		var all = [String]()
		var onlyTint = [String]()
		_ = BrowserRuntimePageCommandBridge.add(browser: browser, name: nil) { all.append($0.name) }
		_ = BrowserRuntimePageCommandBridge.add(browser: browser, name: "siteTint.sample") { onlyTint.append($0.name) }
		let key = BrowserRuntimePageCommandBridge.browserKey(for: browser)

		BrowserRuntimePageCommandBridge.deliver(browserKey: key, payload: #"{"name":"linkHints.activate"}"#)
		BrowserRuntimePageCommandBridge.deliver(browserKey: key, payload: #"{"name":"siteTint.sample"}"#)

		XCTAssertEqual(all, ["linkHints.activate", "siteTint.sample"])
		XCTAssertEqual(onlyTint, ["siteTint.sample"])
		XCTAssertEqual(nativeRegistrations.count, 1, "native callback is installed once per browser")
	}

	func testRemovingLastHandlerClearsNativeCallback() {
		let first = BrowserRuntimePageCommandBridge.add(browser: browser, name: nil) { _ in }
		let second = BrowserRuntimePageCommandBridge.add(browser: browser, name: nil) { _ in }

		BrowserRuntimePageCommandBridge.remove(first)
		XCTAssertEqual(nativeRegistrations.map(\.1), [true])
		BrowserRuntimePageCommandBridge.remove(second)
		XCTAssertEqual(nativeRegistrations.map(\.1), [true, false])
	}

	func testLegacySetterReplacesOnlyItsOwnHandler() {
		var added = 0
		var legacyA = 0
		var legacyB = 0
		let runtimeHandlers = BrowserRuntimePageCommandBridge.self
		_ = runtimeHandlers.add(browser: browser, name: nil) { _ in added += 1 }

		let key = runtimeHandlers.browserKey(for: browser)
		let tokenA = runtimeHandlers.add(browser: browser, name: nil) { _ in legacyA += 1 }
		runtimeHandlers.legacyTokensByBrowserKey[key] = tokenA
		// Replace the legacy handler the same way setPageCommandHandler does.
		runtimeHandlers.remove(tokenA)
		let tokenB = runtimeHandlers.add(browser: browser, name: nil) { _ in legacyB += 1 }
		runtimeHandlers.legacyTokensByBrowserKey[key] = tokenB

		runtimeHandlers.deliver(browserKey: key, payload: #"{"name":"x"}"#)
		XCTAssertEqual([added, legacyA, legacyB], [1, 0, 1])
		XCTAssertNil(runtimeHandlers.legacyTokensByBrowserKey[key] == tokenA ? tokenA : nil)
	}
}

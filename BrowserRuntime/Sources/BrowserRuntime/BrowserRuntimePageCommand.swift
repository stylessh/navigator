import Foundation

@_silgen_name("CEFBridge_SetPageCommandHandler")
private func browserRuntimeCEFBridgeSetPageCommandHandler(
	_ browserRef: CEFBridgeBrowserRef?,
	_ callback: CEFBridgeMessageCallback?,
	_ userData: UnsafeMutableRawPointer?
)

/// A command sent from a Navigator-injected page script to the native app.
///
/// Page scripts emit commands with
/// `window.prompt("__navigatorPageCommand__", JSON.stringify({ name, arguments }))`.
/// The CEF JS dialog handler suppresses the prompt and forwards the JSON payload here.
/// The channel is generic so other injected features can reuse it.
public struct BrowserRuntimePageCommand: Sendable, Equatable, Decodable {
	public static let promptMessage = "__navigatorPageCommand__"

	public let name: String
	public let arguments: [String: String]

	public init(name: String, arguments: [String: String] = [:]) {
		self.name = name
		self.arguments = arguments
	}

	private enum CodingKeys: String, CodingKey {
		case name
		case arguments
	}

	public init(from decoder: any Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		name = try container.decode(String.self, forKey: .name)
		arguments = try container.decodeIfPresent([String: String].self, forKey: .arguments) ?? [:]
	}

	public static func from(json: String) -> BrowserRuntimePageCommand? {
		guard let data = json.data(using: .utf8) else { return nil }
		return try? JSONDecoder().decode(BrowserRuntimePageCommand.self, from: data)
	}
}

@MainActor
enum BrowserRuntimePageCommandBridge {
	typealias SetHandler = (CEFBridgeBrowserRef?, CEFBridgeMessageCallback?, UnsafeMutableRawPointer?) -> Void

	static let liveSetHandler: SetHandler = { browser, callback, userData in
		browserRuntimeCEFBridgeSetPageCommandHandler(browser, callback, userData)
	}

	static var setHandler: SetHandler = liveSetHandler
	static var handlersByBrowserKey = [UInt64: (BrowserRuntimePageCommand) -> Void]()
	/// Additional named listeners per browser, so several features can share the channel.
	static var listenersByBrowserKey = [UInt64: [String: (BrowserRuntimePageCommand) -> Void]]()

	static func hasAnyHandler(for browserKey: UInt64) -> Bool {
		handlersByBrowserKey[browserKey] != nil || listenersByBrowserKey[browserKey]?.isEmpty == false
	}

	static func browserKey(for browser: CEFBridgeBrowserRef) -> UInt64 {
		UInt64(UInt(bitPattern: browser))
	}

	static func deliver(browserKey: UInt64, payload: String) {
		guard hasAnyHandler(for: browserKey),
		      let command = BrowserRuntimePageCommand.from(json: payload)
		else {
			return
		}
		handlersByBrowserKey[browserKey]?(command)
		for listener in (listenersByBrowserKey[browserKey] ?? [:]).values {
			listener(command)
		}
	}
}

private let browserRuntimePageCommandMessageCallback: CEFBridgeMessageCallback = { userData, message in
	guard let userData else { return }
	let browserKey = UInt64(UInt(bitPattern: userData))
	let payload = message.map(String.init(cString:)) ?? ""
	Task { @MainActor [browserKey, payload] in
		BrowserRuntimePageCommandBridge.deliver(browserKey: browserKey, payload: payload)
	}
}

public extension BrowserRuntime {
	/// Registers (or clears, with `nil`) the handler for page commands emitted by injected scripts.
	@MainActor
	func setPageCommandHandler(
		for browser: CEFBridgeBrowserRef?,
		handler: ((BrowserRuntimePageCommand) -> Void)?
	) {
		guard let browser else { return }
		let key = BrowserRuntimePageCommandBridge.browserKey(for: browser)
		if let handler {
			BrowserRuntimePageCommandBridge.handlersByBrowserKey[key] = handler
			BrowserRuntimePageCommandBridge.setHandler(
				browser,
				browserRuntimePageCommandMessageCallback,
				browser
			)
			return
		}
		BrowserRuntimePageCommandBridge.handlersByBrowserKey.removeValue(forKey: key)
		guard BrowserRuntimePageCommandBridge.hasAnyHandler(for: key) == false else { return }
		BrowserRuntimePageCommandBridge.setHandler(browser, nil, nil)
	}

	/// Adds (or removes, with `nil`) a named listener for page commands on `browser`, alongside
	/// any handler set with `setPageCommandHandler`. Use a unique `id` per feature.
	@MainActor
	func setPageCommandListener(
		_ id: String,
		for browser: CEFBridgeBrowserRef?,
		handler: ((BrowserRuntimePageCommand) -> Void)?
	) {
		guard let browser else { return }
		let key = BrowserRuntimePageCommandBridge.browserKey(for: browser)
		if let handler {
			BrowserRuntimePageCommandBridge.listenersByBrowserKey[key, default: [:]][id] = handler
			BrowserRuntimePageCommandBridge.setHandler(browser, browserRuntimePageCommandMessageCallback, browser)
			return
		}
		BrowserRuntimePageCommandBridge.listenersByBrowserKey[key]?.removeValue(forKey: id)
		if BrowserRuntimePageCommandBridge.listenersByBrowserKey[key]?.isEmpty == true {
			BrowserRuntimePageCommandBridge.listenersByBrowserKey.removeValue(forKey: key)
		}
		guard BrowserRuntimePageCommandBridge.hasAnyHandler(for: key) == false else { return }
		BrowserRuntimePageCommandBridge.setHandler(browser, nil, nil)
	}
}

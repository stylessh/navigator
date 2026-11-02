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
///
/// This is the shared page → native channel for every experiment. Use a namespaced `name`
/// (e.g. `"linkHints.activate"`, `"siteTint.sample"`) and register with
/// `BrowserRuntime.addPageCommandHandler(for:name:handler:)`; several handlers can coexist on
/// the same browser.
public struct BrowserRuntimePageCommand: Sendable, Equatable, Decodable {
	public static let promptMessage = "__navigatorPageCommand__"

	/// JavaScript expression that sends a command, for building injected scripts:
	/// `"\(BrowserRuntimePageCommand.javaScriptSendFunction)('siteTint.sample', { color: c })"`.
	/// Argument values are stringified so they decode as `[String: String]`.
	public static let javaScriptSendFunction = """
	((name, args) => { try { const a = {}; for (const [k, v] of Object.entries(args || {})) { \
	a[k] = typeof v === 'string' ? v : JSON.stringify(v); } \
	window.prompt("__navigatorPageCommand__", JSON.stringify({ name, arguments: a })); } catch (e) {} })
	"""

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

/// Returned by `addPageCommandHandler`; pass it to `removePageCommandHandler` to unregister.
public struct BrowserRuntimePageCommandHandlerToken: Hashable, Sendable {
	fileprivate let browserKey: UInt64
	fileprivate let id: UUID
}

@MainActor
enum BrowserRuntimePageCommandBridge {
	typealias SetHandler = (CEFBridgeBrowserRef?, CEFBridgeMessageCallback?, UnsafeMutableRawPointer?) -> Void
	typealias Handler = (BrowserRuntimePageCommand) -> Void

	struct Registration {
		let id: UUID
		/// Exact command name to match, or nil for every command.
		let name: String?
		let handler: Handler
	}

	static let liveSetHandler: SetHandler = { browser, callback, userData in
		browserRuntimeCEFBridgeSetPageCommandHandler(browser, callback, userData)
	}

	static var setHandler: SetHandler = liveSetHandler
	static var registrationsByBrowserKey = [UInt64: [Registration]]()
	/// Token used by the single-handler `setPageCommandHandler` API, per browser.
	static var legacyTokensByBrowserKey = [UInt64: BrowserRuntimePageCommandHandlerToken]()

	static func browserKey(for browser: CEFBridgeBrowserRef) -> UInt64 {
		UInt64(UInt(bitPattern: browser))
	}

	static func browserRef(for browserKey: UInt64) -> CEFBridgeBrowserRef? {
		CEFBridgeBrowserRef(bitPattern: UInt(browserKey))
	}

	static func add(
		browser: CEFBridgeBrowserRef,
		name: String?,
		handler: @escaping Handler
	) -> BrowserRuntimePageCommandHandlerToken {
		let key = browserKey(for: browser)
		let registration = Registration(id: UUID(), name: name, handler: handler)
		let wasEmpty = registrationsByBrowserKey[key, default: []].isEmpty
		registrationsByBrowserKey[key, default: []].append(registration)
		if wasEmpty {
			setHandler(browser, browserRuntimePageCommandMessageCallback, browser)
		}
		return BrowserRuntimePageCommandHandlerToken(browserKey: key, id: registration.id)
	}

	static func remove(_ token: BrowserRuntimePageCommandHandlerToken) {
		guard var registrations = registrationsByBrowserKey[token.browserKey] else { return }
		registrations.removeAll { $0.id == token.id }
		if legacyTokensByBrowserKey[token.browserKey] == token {
			legacyTokensByBrowserKey.removeValue(forKey: token.browserKey)
		}
		if registrations.isEmpty {
			registrationsByBrowserKey.removeValue(forKey: token.browserKey)
			setHandler(browserRef(for: token.browserKey), nil, nil)
		}
		else {
			registrationsByBrowserKey[token.browserKey] = registrations
		}
	}

	static func removeAll(browser: CEFBridgeBrowserRef) {
		let key = browserKey(for: browser)
		legacyTokensByBrowserKey.removeValue(forKey: key)
		guard registrationsByBrowserKey.removeValue(forKey: key) != nil else { return }
		setHandler(browser, nil, nil)
	}

	static func deliver(browserKey: UInt64, payload: String) {
		guard let registrations = registrationsByBrowserKey[browserKey],
		      let command = BrowserRuntimePageCommand.from(json: payload)
		else {
			return
		}
		for registration in registrations where registration.name == nil || registration.name == command.name {
			registration.handler(command)
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
	/// Adds a handler for page commands from `browser`. Pass `name` to receive only that command,
	/// or nil to receive every command. Several handlers can be registered per browser; they're
	/// all removed automatically when the browser closes.
	@MainActor
	@discardableResult
	func addPageCommandHandler(
		for browser: CEFBridgeBrowserRef?,
		name: String? = nil,
		handler: @escaping (BrowserRuntimePageCommand) -> Void
	) -> BrowserRuntimePageCommandHandlerToken? {
		guard let browser else { return nil }
		return BrowserRuntimePageCommandBridge.add(browser: browser, name: name, handler: handler)
	}

	@MainActor
	func removePageCommandHandler(_ token: BrowserRuntimePageCommandHandlerToken) {
		BrowserRuntimePageCommandBridge.remove(token)
	}

	@MainActor
	func removeAllPageCommandHandlers(for browser: CEFBridgeBrowserRef?) {
		guard let browser else { return }
		BrowserRuntimePageCommandBridge.removeAll(browser: browser)
	}

	/// Single-handler convenience: replaces the handler previously set through this method
	/// (handlers added with `addPageCommandHandler` are left alone). Pass nil to clear it.
	@MainActor
	func setPageCommandHandler(
		for browser: CEFBridgeBrowserRef?,
		handler: ((BrowserRuntimePageCommand) -> Void)?
	) {
		guard let browser else { return }
		let key = BrowserRuntimePageCommandBridge.browserKey(for: browser)
		if let existing = BrowserRuntimePageCommandBridge.legacyTokensByBrowserKey[key] {
			BrowserRuntimePageCommandBridge.remove(existing)
		}
		guard let handler else { return }
		let token = BrowserRuntimePageCommandBridge.add(browser: browser, name: nil, handler: handler)
		BrowserRuntimePageCommandBridge.legacyTokensByBrowserKey[key] = token
	}
}

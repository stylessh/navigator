import BrowserRuntime
import Foundation

/// Request/response transport for the developer overlay's page scripts.
///
/// Neither existing JS path returns values in this build: the renderer path times out because the
/// bundled CEF helpers don't run Navigator's render-process handler, and the browser-process path
/// only reports `{"dispatched":true}`. So each script is wrapped, executed in the browser process,
/// and its value comes back through the page-command prompt channel
/// (`window.prompt("__navigatorPageCommand__", …)`), matched to the request by id.
@MainActor
final class NavigatorDeveloperOverlayPageChannel {
	nonisolated static let listenerID = "developerOverlay"
	nonisolated static let resultCommandName = "developerOverlay.result"

	var timeout: Duration = .seconds(2.5)

	private var nextRequestID = 0
	private var pending: [String: @MainActor (String?, String?) -> Void] = [:]
	private var listeningBrowserKeys = Set<UInt>()

	func evaluate(
		_ expression: String,
		in browser: CEFBridgeBrowserRef,
		runtime: BrowserRuntime,
		completion: @escaping @MainActor (String?, String?) -> Void
	) {
		listenIfNeeded(to: browser, runtime: runtime)
		nextRequestID += 1
		let requestID = String(nextRequestID)
		pending[requestID] = completion

		runtime.evaluateJavaScriptWithResult(browser, script: Self.wrap(expression, requestID: requestID)) { [weak self] _, error in
			guard let self, let error, error.isEmpty == false else { return }
			self.finish(requestID, result: nil, error: error)
		}

		let timeout = timeout
		Task { [weak self] in
			try? await Task.sleep(for: timeout)
			self?.finish(requestID, result: nil, error: "Page script timed out")
		}
	}

	private func listenIfNeeded(to browser: CEFBridgeBrowserRef, runtime: BrowserRuntime) {
		let key = UInt(bitPattern: browser)
		guard listeningBrowserKeys.insert(key).inserted else { return }
		runtime.setPageCommandListener(Self.listenerID, for: browser) { [weak self] command in
			self?.handle(command)
		}
	}

	private func handle(_ command: BrowserRuntimePageCommand) {
		guard command.name == Self.resultCommandName, let requestID = command.arguments["id"] else { return }
		let error = command.arguments["error"].flatMap { $0.isEmpty ? nil : $0 }
		let result = command.arguments["hasResult"] == "1" ? command.arguments["result"] : nil
		finish(requestID, result: result, error: error)
	}

	private func finish(_ requestID: String, result: String?, error: String?) {
		guard let completion = pending.removeValue(forKey: requestID) else { return }
		completion(result, error)
	}

	/// Wraps an expression so its value (stringified) is posted back with `requestID`.
	/// Every argument value is a string, as the page-command decoder requires.
	nonisolated static func wrap(_ expression: String, requestID: String) -> String {
		"""
		(function () {
		  var __r = null, __e = null;
		  try {
		    __r = (\(expression));
		    if (__r !== undefined && __r !== null && typeof __r !== "string") { __r = String(__r); }
		  } catch (__x) {
		    __e = String((__x && __x.message) || __x);
		  }
		  try {
		    window.prompt("\(BrowserRuntimePageCommand.promptMessage)", JSON.stringify({
		      name: "\(resultCommandName)",
		      arguments: {
		        id: "\(requestID)",
		        hasResult: (__r === undefined || __r === null) ? "0" : "1",
		        result: (__r === undefined || __r === null) ? "" : __r,
		        error: __e || ""
		      }
		    }));
		  } catch (__ignored) {}
		})();
		"""
	}
}

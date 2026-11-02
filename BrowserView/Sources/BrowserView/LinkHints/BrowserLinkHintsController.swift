import AppKit
import BrowserRuntime
import Observation
import Vendors

/// Runs keyboard link hint sessions for one browser window.
///
/// Flow: the page script (or the ⌥⌘F menu item) asks for hints, the controller collects
/// targets from the page, shows the native overlay, feeds typed keys into
/// `BrowserLinkHintSession`, and finally activates the chosen target in the page.
@MainActor
final class BrowserLinkHintsController {
	struct Environment {
		/// Runs a script in the given browser's main frame. Results come back as page commands
		/// (see `handlePageCommand`), because the browser-process bridge does not return values.
		var evaluateJavaScript: (CEFBridgeBrowserRef, String) -> Void
		/// Opens `url` in a new background tab.
		var openURLInNewTab: (String) -> Void
	}

	private enum State {
		case idle
		case collecting(Request)
		case showing(BrowserLinkHintSession, Active)
	}

	private struct Request {
		var token: Int
		var browser: CEFBridgeBrowserRef
		weak var hostView: NSView?
		var openInNewTab: Bool
	}

	private struct Active {
		var browser: CEFBridgeBrowserRef
		var overlay: BrowserLinkHintOverlayView
		var scale: CGFloat
		weak var previousFirstResponder: NSResponder?
	}

	private let environment: Environment
	private var state = State.idle
	private var nextToken = 0

	init(environment: Environment) {
		self.environment = environment
	}

	var isActive: Bool {
		if case .idle = state { return false }
		return true
	}

	static var isExperimentEnabled: Bool {
		NavigatorExperiments.shared.isEnabled(.linkHints)
	}

	/// Starts hint mode for `browser`, whose web content is drawn inside `hostView`.
	func begin(browser: CEFBridgeBrowserRef, hostView: NSView, openInNewTab: Bool) {
		guard Self.isExperimentEnabled else { return }
		if case .showing = state {
			cancel()
			return
		}
		guard case .idle = state else { return }

		nextToken += 1
		let token = nextToken
		state = .collecting(Request(token: token, browser: browser, hostView: hostView, openInNewTab: openInNewTab))
		environment.evaluateJavaScript(browser, BrowserKeyboardNavigationJavaScript.collectTargetsScript(token: token))
		// If the page never answers (crashed renderer, blocked script), drop the request.
		Task { @MainActor [weak self] in
			try? await Task.sleep(for: .seconds(2))
			guard let self, case let .collecting(request) = self.state, request.token == token else { return }
			self.state = .idle
		}
	}

	/// Handles link-hint page commands from `browser`. Returns true when the command was consumed.
	@discardableResult
	func handlePageCommand(_ command: BrowserRuntimePageCommand, from browser: CEFBridgeBrowserRef) -> Bool {
		switch command.name {
		case BrowserKeyboardNavigationJavaScript.targetsCommand:
			guard case let .collecting(request) = state,
			      request.browser == browser,
			      command.arguments[BrowserKeyboardNavigationJavaScript.tokenArgument] == String(request.token)
			else {
				return true
			}
			guard let hostView = request.hostView,
			      let payload = command.arguments[BrowserKeyboardNavigationJavaScript.payloadArgument],
			      let collection = BrowserLinkHintCollection.from(json: payload),
			      collection.targets.isEmpty == false,
			      collection.viewport.width > 0
			else {
				state = .idle
				NSSound.beep()
				return true
			}
			show(collection: collection, browser: browser, hostView: hostView, openInNewTab: request.openInNewTab)
			return true
		case BrowserKeyboardNavigationJavaScript.openURLCommand:
			if let url = command.arguments[BrowserKeyboardNavigationJavaScript.urlArgument], url.isEmpty == false {
				environment.openURLInNewTab(url)
			}
			return true
		default:
			return false
		}
	}

	func cancel() {
		switch state {
		case .idle:
			return
		case .collecting:
			state = .idle
		case let .showing(_, active):
			state = .idle
			environment.evaluateJavaScript(active.browser, BrowserKeyboardNavigationJavaScript.clearTargetsScript)
			let overlay = active.overlay
			restoreFirstResponder(active)
			overlay.dismiss { overlay.removeFromSuperview() }
		}
	}

	/// Cancels the session if it belongs to a browser other than `browser` (tab switch, close).
	func cancelIfNotShowing(browser: CEFBridgeBrowserRef?) {
		guard case let .showing(_, active) = state else {
			if browser == nil { cancel() }
			return
		}
		if active.browser != browser {
			cancel()
		}
	}

	/// Cancels the session if it is showing hints for `browser` (the tab is going away).
	func cancelIfShowing(browser: CEFBridgeBrowserRef?) {
		guard case let .showing(_, active) = state, active.browser == browser else { return }
		cancel()
	}

	private func show(
		collection: BrowserLinkHintCollection,
		browser: CEFBridgeBrowserRef,
		hostView: NSView,
		openInNewTab: Bool
	) {
		let session = BrowserLinkHintSession(collection: collection, openInNewTab: openInNewTab)
		let overlay = BrowserLinkHintOverlayView(frame: hostView.bounds)
		overlay.autoresizingMask = [.width, .height]
		hostView.addSubview(overlay, positioned: .above, relativeTo: nil)

		let scale = hostView.bounds.width / collection.viewport.width
		let window = hostView.window
		let active = Active(
			browser: browser,
			overlay: overlay,
			scale: scale,
			previousFirstResponder: window?.firstResponder
		)
		state = .showing(session, active)

		overlay.onType = { [weak self] text in self?.handleType(text) }
		overlay.onDeleteBackward = { [weak self] in self?.handleDeleteBackward() }
		overlay.onCancel = { [weak self] in self?.cancel() }
		overlay.present(hints: session.hints, scale: scale)
		window?.makeFirstResponder(overlay)
	}

	private func handleType(_ text: String) {
		guard case .showing(var session, let active) = state else { return }
		let outcome = session.type(text)
		state = .showing(session, active)
		apply(outcome, session: session, active: active)
	}

	private func handleDeleteBackward() {
		guard case .showing(var session, let active) = state else { return }
		let outcome = session.deleteBackward()
		state = .showing(session, active)
		apply(outcome, session: session, active: active)
	}

	private func apply(_ outcome: BrowserLinkHintSession.Outcome, session: BrowserLinkHintSession, active: Active) {
		switch outcome {
		case let .filtered(matching, typedPrefix):
			active.overlay.update(matching: matching, typedPrefix: typedPrefix)
		case .rejected:
			active.overlay.reject()
		case .dismissed:
			cancel()
		case let .activate(hint):
			state = .idle
			let targetRect = hint.pageRect.applying(CGAffineTransform(scaleX: active.scale, y: active.scale))
			let overlay = active.overlay
			// Hand focus back to the page before clicking, so a focused input receives typing.
			restoreFirstResponder(active)
			overlay.finish(activating: hint.id, targetRect: targetRect) {
				overlay.removeFromSuperview()
			}
			activate(hint, in: active.browser, openInNewTab: session.openInNewTab)
		}
	}

	private func activate(_ hint: BrowserLinkHint, in browser: CEFBridgeBrowserRef, openInNewTab: Bool) {
		let script = BrowserKeyboardNavigationJavaScript.activateTargetScript(
			index: hint.id,
			openInNewTab: openInNewTab
		)
		// "Open in new tab" answers with an `openURL` page command.
		environment.evaluateJavaScript(browser, script)
	}

	private func restoreFirstResponder(_ active: Active) {
		guard let window = active.overlay.window, window.firstResponder === active.overlay else { return }
		if let previous = active.previousFirstResponder,
		   let previousView = previous as? NSView,
		   previousView.window === window {
			window.makeFirstResponder(previousView)
		}
		else {
			window.makeFirstResponder(nil)
		}
	}
}

/// Re-arms an Observation tracker so `onChange` fires every time the link hints toggle flips.
@MainActor
final class BrowserLinkHintsExperimentObserver {
	private let onChange: @MainActor (Bool) -> Void
	private var isObserving = true

	init(onChange: @escaping @MainActor (Bool) -> Void) {
		self.onChange = onChange
		observe()
	}

	func stop() {
		isObserving = false
	}

	private func observe() {
		guard isObserving else { return }
		withObservationTracking {
			_ = BrowserLinkHintsController.isExperimentEnabled
		} onChange: { [weak self] in
			Task { @MainActor [weak self] in
				guard let self, self.isObserving else { return }
				self.onChange(BrowserLinkHintsController.isExperimentEnabled)
				self.observe()
			}
		}
	}
}

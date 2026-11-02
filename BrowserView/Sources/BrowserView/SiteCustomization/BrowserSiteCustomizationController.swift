import AppKit
import BrowserCustomization
import BrowserCustomizationUI
import BrowserRuntime
import BrowserSidebar
import ModelKit
import Observation
import SwiftUI
import Vendors

/// Bridges `SiteCustomizationCenter` (pure model) to live CEF browsers:
/// injects boosts as pages commit and finish loading, drives the zap picker,
/// hosts the customization panel, and performs registry actions.
@MainActor
public final class BrowserSiteCustomizationController: NavigatorActionPerformer {
	public let center: SiteCustomizationCenter
	/// Set by the app to show toasts in its own overlay.
	public var toastHandler: (@MainActor (String, String?) -> Void)?
	/// Called whenever the set of actions or the selected page changes, so hosts can refresh toolbar items.
	public var onActionsChange: (@MainActor () -> Void)?

	private weak var owner: BrowserViewController?
	private var loadingTabIDs: Set<BrowserTabID> = []
	private var pickerURL: URL?
	private var pendingResults: [String: CheckedContinuation<String?, Never>] = [:]
	private static let resultTimeout: Duration = .seconds(2)
	private var panelController: SiteCustomizationPanelWindowController?
	private var centerObserver: UUID?
	private var isAttached = false

	init(owner: BrowserViewController, center: SiteCustomizationCenter = .shared) {
		self.owner = owner
		self.center = center
	}

	private var chromeView: BrowserChromeView? {
		owner?.chromeView
	}

	private var runtime: (any BrowserRuntimeDriving)? {
		owner?.browserRuntime
	}

	private var isExperimentEnabled: Bool {
		NavigatorExperiments.shared.isEnabled(.siteCustomization)
	}

	// MARK: Lifecycle

	func attach() {
		guard isAttached == false, let chromeView else { return }
		isAttached = true
		center.start()
		center.isEnabled = isExperimentEnabled
		observeExperimentToggle()

		chromeView.pageLifecycleHooks.didCommit = { [weak self] tabID, browser, url in
			self?.pageDidCommit(tabID: tabID, browser: browser, url: url)
		}
		chromeView.pageLifecycleHooks.didSyncLoadingState = { [weak self] tabID, browser, isLoading in
			self?.loadingStateDidSync(tabID: tabID, browser: browser, isLoading: isLoading)
		}
		chromeView.pageLifecycleHooks.didReceivePageCommand = { [weak self] tabID, command in
			self?.handlePageCommand(command, tabID: tabID)
		}
		centerObserver = center.addChangeObserver { [weak self] in
			self?.resyncAllLiveBrowsers()
			self?.onActionsChange?()
		}
	}

	private func observeExperimentToggle() {
		withObservationTracking {
			_ = NavigatorExperiments.shared.isEnabled(.siteCustomization)
		} onChange: { [weak self] in
			Task { @MainActor [weak self] in
				guard let self else { return }
				self.center.isEnabled = self.isExperimentEnabled
				self.onActionsChange?()
				self.observeExperimentToggle()
			}
		}
	}

	private func pageDidCommit(tabID: BrowserTabID, browser: CEFBridgeBrowserRef, url: String) {
		guard let url = URL(string: url) else { return }
		evaluate(center.scripts(for: url, phase: .commit), in: browser)
		if tabID == owner?.selectedTabID {
			// Navigating away ends any pick in progress; the old document's picker is gone.
			if pickerURL != nil, pickerURL?.host != url.host || pickerURL?.path != url.path {
				pickerURL = nil
				panelController?.setPassthrough(false)
			}
			onActionsChange?()
		}
	}

	private func loadingStateDidSync(tabID: BrowserTabID, browser: CEFBridgeBrowserRef, isLoading: Bool) {
		if isLoading {
			loadingTabIDs.insert(tabID)
			return
		}
		guard loadingTabIDs.remove(tabID) != nil else { return }
		guard let urlString = chromeView?.liveBrowsers().first(where: { $0.tabID == tabID })?.url,
		      let url = URL(string: urlString)
		else { return }
		// Re-sync on load end too: some pages replace <head> or reset adoptedStyleSheets while booting.
		evaluate(center.scripts(for: url, phase: .idle), in: browser)
	}

	private func resyncAllLiveBrowsers() {
		guard let chromeView else { return }
		for live in chromeView.liveBrowsers() {
			guard let url = URL(string: live.url) else { continue }
			evaluate(center.scripts(for: url, phase: .commit), in: live.browser)
		}
	}

	private func evaluate(_ scripts: [String], in browser: CEFBridgeBrowserRef) {
		for script in scripts {
			runtime?.evaluateJavaScriptWithResult(browser, script: script) { _, _ in }
		}
	}

	// MARK: Current page

	public var currentContext: NavigatorActionContext {
		guard let owner else { return NavigatorActionContext(url: nil, title: nil) }
		return NavigatorActionContext(
			url: owner.selectedTabCurrentURL.flatMap(URL.init(string:)),
			title: owner.selectedTabTitle
		)
	}

	/// Actions for a placement on the current page, empty when the experiment is off.
	public func actions(for placement: NavigatorActionPlacement, matching query: String = "") -> [NavigatorAction] {
		guard center.isEnabled else { return [] }
		return center.actions.actions(for: placement, context: currentContext, matching: query)
	}

	/// Toolbar-ready items for the current page, so the app target doesn't need to import BrowserCustomization.
	public func toolbarItems() -> [BrowserSiteActionItem] {
		actions(for: .toolbar).map { action in
			BrowserSiteActionItem(
				id: action.id,
				title: action.title,
				systemImage: action.systemImage,
				help: [action.title, action.shortcutHint].compactMap { $0 }.joined(separator: "  ")
			)
		}
	}

	public func perform(actionID: String) {
		let context = currentContext
		Task { @MainActor in
			await center.actions.perform(id: actionID, context: context, performer: self)
		}
	}

	// MARK: NavigatorActionPerformer

	/// Evaluates a JS expression in the selected page and returns its string value.
	///
	/// Neither evaluate API returns values reliably (the browser-process one only reports
	/// `{"dispatched":true}`), so the page posts the value back as a `boost.result` page command.
	/// Returns nil on error, on a null/undefined value, or after a 2 s timeout.
	public func evaluateInPage(_ expression: String) async -> String? {
		guard let browser = owner?.hostedBrowser, let runtime else { return nil }
		let token = UUID().uuidString
		return await withCheckedContinuation { continuation in
			pendingResults[token] = continuation
			runtime.evaluateJavaScriptWithResult(
				browser,
				script: BoostScriptBuilder.reportScript(expression: expression, token: token)
			) { _, _ in }
			Task { @MainActor [weak self] in
				try? await Task.sleep(for: Self.resultTimeout)
				self?.pendingResults.removeValue(forKey: token)?.resume(returning: nil)
			}
		}
	}

	private func handlePageCommand(_ command: BrowserRuntimePageCommand, tabID: BrowserTabID) {
		switch command.name {
		case BoostScriptBuilder.PageCommand.result:
			guard let token = command.arguments["token"],
			      let continuation = pendingResults.removeValue(forKey: token)
			else { return }
			let failed = command.arguments["error"] != nil || command.arguments["isNull"] == "true"
			continuation.resume(returning: failed ? nil : command.arguments["value"])
		case BoostScriptBuilder.PageCommand.pick:
			guard tabID == owner?.selectedTabID, let url = pickerURL else { return }
			pickerURL = nil
			panelController?.setPassthrough(false)
			let selector = command.arguments["selector"] ?? ""
			guard command.arguments["cancelled"] != "true", selector.isEmpty == false else { return }
			center.boosts.addZap(selector, for: url)
			showToast("Hidden on \(SiteHost.normalized(url.host) ?? "this site")", systemImage: "scope")
		default:
			break
		}
	}

	public func open(_ url: URL, inNewTab: Bool) {
		if inNewTab {
			owner?.openNewTab(with: url.absoluteString)
		}
		else {
			owner?.navigateSelectedTab(to: url.absoluteString)
		}
	}

	public func copyToPasteboard(_ string: String) {
		NSPasteboard.general.clearContents()
		NSPasteboard.general.setString(string, forType: .string)
	}

	public func showToast(_ message: String, systemImage: String?) {
		toastHandler?(message, systemImage)
	}

	public func startZapPicker() {
		guard center.isEnabled else { return }
		guard let browser = owner?.hostedBrowser, let url = currentContext.url, currentContext.isWebPage else {
			showToast("Zap works on web pages", systemImage: "scope")
			return
		}
		let accent = center.boosts.siteBoost(for: url).flatMap { boost -> String? in
			if case let .custom(hex) = boost.tint { return hex }
			return nil
		}
		// The pick comes back as a `boost.pick` page command (see handlePageCommand).
		pickerURL = url
		runtime?.evaluateJavaScriptWithResult(browser, script: BoostScriptBuilder.startPickerScript(accentHex: accent)) { _, _ in }
		panelController?.setPassthrough(true)
	}

	public func cancelZapPicker() {
		pickerURL = nil
		panelController?.setPassthrough(false)
		if let browser = owner?.hostedBrowser {
			runtime?.evaluateJavaScriptWithResult(browser, script: BoostScriptBuilder.cancelPickerScript) { _, _ in }
		}
	}

	public func presentCustomizationPanel() {
		guard center.isEnabled else { return }
		guard let window = owner?.view.window, let url = currentContext.url, currentContext.isWebPage else {
			showToast("Open a web page to customize it", systemImage: "paintbrush.pointed")
			return
		}
		if let panelController, panelController.isVisible {
			panelController.dismiss()
			self.panelController = nil
			return
		}
		let controller = SiteCustomizationPanelWindowController(
			store: center.boosts,
			url: url,
			actions: SiteCustomizationPanelActions(
				startZapPicker: { [weak self] in self?.startZapPicker() },
				countMatches: { [weak self] selector in
					guard let self else { return nil }
					let raw = await self.evaluateInPage(BoostScriptBuilder.countMatchesScript(selector: selector))
					return raw.flatMap { Int($0) }
				},
				dismiss: { [weak self] in
					self?.panelController?.close()
					self?.panelController = nil
				}
			)
		)
		controller.present(over: window)
		panelController = controller
	}

	public var isCustomizationPanelVisible: Bool {
		panelController?.isVisible == true
	}

	public var isZapPickerActive: Bool {
		pickerURL != nil
	}

	/// The panel never takes key focus from the page by itself, so the app routes Escape here.
	public func dismissCustomizationPanel() {
		guard let panelController else { return }
		panelController.dismiss()
		self.panelController = nil
	}

	public func toggleCustomizationPanel() {
		presentCustomizationPanel()
	}

	public func copyCleanLink() {
		guard center.isEnabled else { return }
		perform(actionID: BuiltInActions.copyCleanURLID)
	}
}

public struct BrowserSiteActionItem: Identifiable, Equatable, Sendable {
	public let id: String
	public let title: String
	public let systemImage: String
	public let help: String
}

/// Borderless panels refuse key status by default; the CSS editor needs it.
private final class SiteCustomizationPanelWindow: NSPanel {
	override var canBecomeKey: Bool {
		true
	}
}

/// Transparent child window hosting the SwiftUI panel at the top-right of the browser window.
/// A child window (rather than a subview) keeps the glass above CEF's own layer-backed view.
/// The window has a fixed size; the panel is pinned to its top-right corner and grows downward.
/// Fully transparent pixels let clicks through to the page.
@MainActor
final class SiteCustomizationPanelWindowController {
	private let panel: NSPanel
	private static let windowSize = NSSize(width: 400, height: 760)
	private static let inset: CGFloat = 4

	init(store: BoostStore, url: URL, actions: SiteCustomizationPanelActions) {
		let root = SiteCustomizationPanel(store: store, url: url, actions: actions)
			.padding(24) // room for the shadow and the spring overshoot
			.frame(width: Self.windowSize.width, height: Self.windowSize.height, alignment: .topTrailing)
		let hosting = NSHostingView(rootView: root)
		panel = SiteCustomizationPanelWindow(
			contentRect: NSRect(origin: .zero, size: Self.windowSize),
			styleMask: [.borderless, .nonactivatingPanel],
			backing: .buffered,
			defer: false
		)
		panel.isOpaque = false
		panel.backgroundColor = .clear
		panel.hasShadow = false
		panel.level = .floating
		panel.becomesKeyOnlyIfNeeded = true
		panel.isReleasedWhenClosed = false
		panel.contentView = hosting
	}

	var isVisible: Bool {
		panel.isVisible
	}

	func present(over window: NSWindow) {
		let content = window.convertToScreen(window.contentLayoutRect)
		let size = Self.windowSize
		let height = min(size.height, content.height)
		panel.setFrame(
			NSRect(
				x: content.maxX - size.width - Self.inset,
				y: content.maxY - height - Self.inset,
				width: size.width,
				height: height
			),
			display: true
		)
		window.addChildWindow(panel, ordered: .above)
		panel.orderFront(nil)
	}

	/// While the zap picker runs, let clicks fall through to the page and fade the panel back.
	func setPassthrough(_ passthrough: Bool) {
		panel.ignoresMouseEvents = passthrough
		NSAnimationContext.runAnimationGroup { context in
			context.duration = 0.2
			panel.animator().alphaValue = passthrough ? 0.35 : 1
		}
		if passthrough {
			panel.parent?.makeKey()
		}
	}

	func dismiss() {
		NSAnimationContext.runAnimationGroup { context in
			context.duration = 0.16
			panel.animator().alphaValue = 0
		} completionHandler: { [self] in
			// Strong on purpose: callers drop this controller right after dismissing, and a weak
			// capture left an invisible panel on screen swallowing clicks.
			MainActor.assumeIsolated {
				self.close()
			}
		}
	}

	func close() {
		panel.parent?.removeChildWindow(panel)
		panel.orderOut(nil)
	}
}

import AppKit
import CoreGraphics
import Foundation
import Observation

/// How the overlay talks to whatever page is in front. The app supplies this; the package never
/// imports the browser runtime, which keeps it testable and free of CEF.
@MainActor
public struct DeveloperOverlayPageBridge {
	/// Identity of the page currently shown (for example the selected tab's browser handle).
	/// When it changes, the overlay drops its logs and starts over on the new page.
	public var currentPageIdentity: @MainActor () -> AnyHashable?
	/// Evaluates `script` in the page's main world and calls back with `(result, error)`.
	public var evaluate: @MainActor (_ script: String, _ completion: @escaping @MainActor (String?, String?) -> Void) -> Void
	/// True while the page is navigating. Background polls pause then: page scripts report back via
	/// `window.prompt`, and a dialog opened mid-navigation can cancel a renderer-started navigation.
	public var isPageLoading: @MainActor () -> Bool

	public init(
		currentPageIdentity: @escaping @MainActor () -> AnyHashable?,
		evaluate: @escaping @MainActor (String, @escaping @MainActor (String?, String?) -> Void) -> Void,
		isPageLoading: @escaping @MainActor () -> Bool = { false }
	) {
		self.currentPageIdentity = currentPageIdentity
		self.evaluate = evaluate
		self.isPageLoading = isPageLoading
	}

	public static let disconnected = DeveloperOverlayPageBridge(
		currentPageIdentity: { nil },
		evaluate: { _, completion in completion(nil, "No page") }
	)
}

/// State for the developer overlay: logs, network, inspected element, and viewport mode.
@MainActor
@Observable
public final class DeveloperOverlayModel {
	public struct ConsoleFilter: Equatable, Sendable {
		public var text = ""
		public var showsLogs = true
		public var showsWarnings = true
		public var showsErrors = true

		public init() {}

		func includes(_ entry: DeveloperConsoleEntry) -> Bool {
			switch entry.level {
			case .error: guard showsErrors else { return false }
			case .warn: guard showsWarnings else { return false }
			case .log, .info, .debug: guard showsLogs else { return false }
			case .input, .result, .system: break
			}
			guard text.isEmpty == false else { return true }
			return entry.text.localizedCaseInsensitiveContains(text)
		}
	}

	public enum NetworkFilter: String, CaseIterable, Identifiable, Sendable {
		case all
		case fetch
		case document
		case assets
		case failed

		public var id: String { rawValue }

		public var title: String {
			switch self {
			case .all: "All"
			case .fetch: "Fetch/XHR"
			case .document: "Doc"
			case .assets: "Assets"
			case .failed: "Failed"
			}
		}

		func includes(_ entry: DeveloperNetworkEntry) -> Bool {
			switch self {
			case .all: true
			case .fetch: entry.kind == .fetch || entry.kind == .xhr
			case .document: entry.kind == .document
			case .assets: [.script, .stylesheet, .image, .font, .media].contains(entry.kind)
			case .failed: entry.isFailure
			}
		}
	}

	public static let maxConsoleEntries = 1000
	public static let maxNetworkEntries = 500

	// Presentation
	public var isPanelPresented = false {
		didSet { updatePolling() }
	}

	public var selectedTab: DeveloperOverlayTab = .console
	/// Whether the overlay chrome (the HUD capsule) is shown at all. Bound to the experiment toggle.
	public var isEnabled = true {
		didSet {
			if isEnabled == false {
				isPanelPresented = false
				if isPicking { stopPicking() }
				viewportMode = .responsive
			}
			updatePolling()
		}
	}

	// Data
	public private(set) var consoleEntries: [DeveloperConsoleEntry] = []
	public private(set) var networkEntries: [DeveloperNetworkEntry] = []
	public private(set) var inspectedElement: DeveloperInspectedElement?
	public private(set) var isPicking = false
	public private(set) var pageURL = ""
	public private(set) var pageTitle = ""
	public private(set) var pageViewport: DeveloperOverlayPayload.Viewport?
	/// The page's accent color (CSS), used to tint the glass like Arc tints its chrome per site.
	public private(set) var pageThemeColor: String?
	/// Short confirmation ("Copied selector") that springs in under the HUD.
	public private(set) var transientMessage: String?
	@ObservationIgnored private var transientTask: Task<Void, Never>?
	public private(set) var lastError: String?
	/// Errors seen since the console tab was last viewed; drives the badge on the HUD capsule.
	public private(set) var unseenErrorCount = 0

	public var consoleFilter = ConsoleFilter()
	public var networkFilter: NetworkFilter = .all
	/// Keep logs across navigations (inserting a separator) instead of clearing them.
	public var preservesLog = true

	// Viewport
	public var viewportMode: DeveloperViewportMode = .responsive
	/// Last custom size dragged with the stage handles.
	public var customViewportSize: CGSize?

	// Polling
	@ObservationIgnored public var bridge: DeveloperOverlayPageBridge {
		didSet { resetForNewPage(clear: true) }
	}

	/// Diagnostic line for every poll result, e.g. for launch-time smoke tests reading stdout.
	@ObservationIgnored public var onPollDiagnostic: ((String) -> Void)?
	@ObservationIgnored public var activePollInterval: Duration = .milliseconds(400)
	@ObservationIgnored public var idlePollInterval: Duration = .milliseconds(1500)
	@ObservationIgnored private var revision = 0
	@ObservationIgnored private var pageIdentity: AnyHashable?
	@ObservationIgnored private var pollTask: Task<Void, Never>?
	@ObservationIgnored private var isPollInFlight = false
	/// Set when `pollNow()` lands while a poll is running: that poll may have drained the page just
	/// before the change we care about (a picked element, an eval's logs), so poll again right after.
	@ObservationIgnored private var isPollRequeued = false
	@ObservationIgnored private var localSequence = 0
	@ObservationIgnored private var hasInstalledInCurrentDocument = false

	public init(bridge: DeveloperOverlayPageBridge = .disconnected) {
		self.bridge = bridge
	}

	// MARK: Derived

	public var filteredConsoleEntries: [DeveloperConsoleEntry] {
		consoleEntries.filter(consoleFilter.includes)
	}

	public var filteredNetworkEntries: [DeveloperNetworkEntry] {
		networkEntries.filter(networkFilter.includes)
	}

	public var errorCount: Int {
		consoleEntries.reduce(0) { $0 + ($1.level == .error ? $1.repeatCount : 0) }
	}

	public var warningCount: Int {
		consoleEntries.reduce(0) { $0 + ($1.level == .warn ? $1.repeatCount : 0) }
	}

	public var failedRequestCount: Int {
		networkEntries.count(where: \.isFailure)
	}

	public var totalTransferSize: Int {
		networkEntries.reduce(0) { $0 + ($1.transferSize ?? 0) }
	}

	/// Timeline span used to draw waterfall bars, in ms.
	public var networkTimelineBounds: ClosedRange<Double> {
		guard let first = networkEntries.map(\.startTime).min() else { return 0...1 }
		let last = networkEntries.map { $0.startTime + ($0.duration ?? 0) }.max() ?? first + 1
		return first...max(first + 1, last)
	}

	// MARK: Panel

	public func togglePanel(tab: DeveloperOverlayTab? = nil) {
		if let tab, isPanelPresented, selectedTab != tab {
			select(tab)
			return
		}
		if let tab {
			select(tab)
		}
		isPanelPresented.toggle()
		if isPanelPresented, selectedTab == .console {
			unseenErrorCount = 0
		}
	}

	public func select(_ tab: DeveloperOverlayTab) {
		selectedTab = tab
		if tab == .console {
			unseenErrorCount = 0
		}
	}

	public func clearConsole() {
		consoleEntries.removeAll()
		unseenErrorCount = 0
	}

	public func clearNetwork() {
		networkEntries.removeAll()
	}

	// MARK: Feedback

	/// Copies `text` and shows a brief confirmation.
	public func copy(_ text: String, label: String) {
		NSPasteboard.general.clearContents()
		NSPasteboard.general.setString(text, forType: .string)
		showTransient("Copied \(label)")
	}

	public func showTransient(_ message: String) {
		transientTask?.cancel()
		transientMessage = message
		transientTask = Task { [weak self] in
			try? await Task.sleep(for: .seconds(1.4))
			guard Task.isCancelled == false else { return }
			self?.transientMessage = nil
		}
	}

	// MARK: Inspect

	public func toggleInspect() {
		isPicking ? stopPicking() : startPicking()
	}

	public func startPicking() {
		guard isEnabled else { return }
		isPicking = true
		updatePolling()
		run(DeveloperOverlayAgentScript.startPicking)
	}

	public func stopPicking() {
		isPicking = false
		updatePolling()
		run(DeveloperOverlayAgentScript.stopPicking)
	}

	/// Inspects the first element matching a CSS selector (scripting / automation).
	public func inspect(selector: String) {
		bridge.evaluate(DeveloperOverlayAgentScript.inspect(selector: selector)) { [weak self] result, error in
			guard let self else { return }
			self.onPollDiagnostic?("inspect \(selector) -> \(result ?? "nil") error=\(error ?? "-")")
			self.pollNow()
		}
	}

	/// Runs arbitrary script in the page without logging it (automation hooks such as navigation).
	public func runInPage(_ script: String) {
		run(script)
	}

	public func clearInspectedElement() {
		inspectedElement = nil
		run(DeveloperOverlayAgentScript.clearPicked)
	}

	// MARK: Console prompt

	public func evaluate(_ source: String) {
		let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
		guard trimmed.isEmpty == false else { return }
		appendLocal(level: .input, text: trimmed)
		bridge.evaluate(DeveloperOverlayAgentScript.evaluate(trimmed)) { [weak self] result, error in
			guard let self else { return }
			let parsed = DeveloperEvaluationResult.parse(result: result, error: error)
			if parsed.isBlockedByCSP {
				self.onPollDiagnostic?("eval \(trimmed) -> blocked by CSP, retrying inline")
				self.evaluateInline(trimmed)
				return
			}
			self.finishEvaluation(trimmed, parsed)
		}
	}

	/// CSP-safe retry: the source is inlined as an expression, so statements fail to parse and the
	/// page never answers. Say why instead of showing a bare timeout.
	private func evaluateInline(_ source: String) {
		bridge.evaluate(DeveloperOverlayAgentScript.evaluateInline(source)) { [weak self] result, error in
			guard let self else { return }
			var parsed = DeveloperEvaluationResult.parse(result: result, error: error)
			if error != nil {
				parsed = DeveloperEvaluationResult(
					ok: false,
					text: "This page's security policy blocks eval, so only single expressions can run here."
				)
			}
			self.finishEvaluation(source, parsed)
		}
	}

	private func finishEvaluation(_ source: String, _ parsed: DeveloperEvaluationResult) {
		onPollDiagnostic?("eval \(source) -> ok=\(parsed.ok) \(parsed.text)")
		appendLocal(level: parsed.ok ? .result : .error, text: parsed.text)
		pollNow()
	}

	// MARK: Viewport

	public func setViewport(_ preset: DeveloperViewportPreset?) {
		guard let preset else {
			viewportMode = .responsive
			return
		}
		if viewportMode.preset == preset {
			viewportMode = .responsive
			return
		}
		viewportMode = .preset(preset, viewportMode.preset == nil ? .portrait : viewportMode.orientation)
	}

	public func rotateViewport() {
		guard case let .preset(preset, orientation) = viewportMode, preset.supportsRotation else { return }
		viewportMode = .preset(preset, orientation.toggled)
	}

	/// Called by the stage while the user drags a resize handle.
	public func setCustomViewportSize(_ size: CGSize) {
		let rounded = CGSize(width: size.width.rounded(), height: size.height.rounded())
		customViewportSize = rounded
		viewportMode = .preset(.custom(size: rounded), .portrait)
	}

	/// Cycles responsive → each built-in preset → responsive (⌥⌘M).
	public func cycleViewport() {
		let presets = DeveloperViewportPreset.builtIn
		guard let current = viewportMode.preset, let index = presets.firstIndex(of: current) else {
			viewportMode = .preset(presets[0], .portrait)
			return
		}
		let next = presets.index(after: index)
		viewportMode = next < presets.endIndex ? .preset(presets[next], viewportMode.orientation) : .responsive
	}

	// MARK: Polling

	public func pollNow() {
		Task { await self.pollOnce() }
	}

	private var shouldPoll: Bool {
		isEnabled
	}

	private var currentPollInterval: Duration {
		isPanelPresented || isPicking ? activePollInterval : idlePollInterval
	}

	private func updatePolling() {
		guard shouldPoll else {
			pollTask?.cancel()
			pollTask = nil
			return
		}
		guard pollTask == nil else { return }
		pollTask = Task { [weak self] in
			while Task.isCancelled == false {
				// Re-resolve `self` each tick so the loop never keeps the model alive on its own.
				guard let interval = await self?.pollAndNextInterval() else { return }
				try? await Task.sleep(for: interval)
			}
		}
	}

	private func pollAndNextInterval() async -> Duration {
		await pollOnce()
		return currentPollInterval
	}

	func pollOnce() async {
		guard isPollInFlight == false else {
			isPollRequeued = true
			return
		}
		let identity = bridge.currentPageIdentity()
		if identity != pageIdentity {
			pageIdentity = identity
			resetForNewPage(clear: true)
		}
		guard identity != nil, bridge.isPageLoading() == false else { return }

		isPollInFlight = true
		defer {
			isPollInFlight = false
			if isPollRequeued {
				isPollRequeued = false
				pollNow()
			}
		}
		let script = DeveloperOverlayAgentScript.poll(since: revision)
		let (result, error) = await withCheckedContinuation { continuation in
			bridge.evaluate(script) { result, error in
				continuation.resume(returning: (result, error))
			}
		}
		// The tab may have changed while we waited.
		guard bridge.currentPageIdentity() == identity else { return }
		apply(DeveloperOverlayPayload.parsePoll(result: result, error: error))
	}

	func apply(_ result: DeveloperOverlayPayload.PollResult) {
		if let onPollDiagnostic {
			switch result {
			case let .payload(payload):
				onPollDiagnostic(
					"poll rev=\(payload.revision) console+=\(payload.console.count) network+=\(payload.network.count) "
						+ "picked=\(payload.picked?.value?.selector ?? "-") picking=\(payload.isPicking) "
						+ "theme=\(payload.themeColor ?? "-") vis=\(payload.visibility ?? "-") url=\(payload.url) "
						+ "totals console=\(consoleEntries.count) network=\(networkEntries.count)"
				)
			case .agentMissing:
				onPollDiagnostic("poll agent-missing (installing)")
			case let .failure(message):
				onPollDiagnostic("poll failure: \(message)")
			}
		}
		switch result {
		case let .payload(payload):
			lastError = nil
			if payload.revision < revision {
				// Same agent version but a fresh document: the page navigated between polls.
				handleNavigation()
			}
			merge(payload)
		case .agentMissing:
			if hasInstalledInCurrentDocument || revision > 0 {
				handleNavigation()
			}
			install()
		case let .failure(message):
			lastError = message
		}
	}

	private func install() {
		hasInstalledInCurrentDocument = true
		bridge.evaluate(DeveloperOverlayAgentScript.install) { [weak self] _, error in
			guard let self else { return }
			if let error, error.isEmpty == false {
				self.lastError = error
			}
		}
	}

	private func handleNavigation() {
		revision = 0
		hasInstalledInCurrentDocument = false
		inspectedElement = nil
		isPicking = false
		networkEntries.removeAll()
		if preservesLog {
			if consoleEntries.last?.level != .system {
				appendLocal(level: .system, text: "Navigated")
			}
		}
		else {
			consoleEntries.removeAll()
			unseenErrorCount = 0
		}
	}

	private func resetForNewPage(clear: Bool) {
		revision = 0
		hasInstalledInCurrentDocument = false
		inspectedElement = nil
		isPicking = false
		pageURL = ""
		pageTitle = ""
		pageViewport = nil
		pageThemeColor = nil
		if clear {
			consoleEntries.removeAll()
			networkEntries.removeAll()
			unseenErrorCount = 0
		}
	}

	func merge(_ payload: DeveloperOverlayPayload) {
		revision = max(revision, payload.revision)
		pageURL = payload.url
		pageTitle = payload.title
		pageViewport = payload.viewport
		if pageThemeColor != payload.themeColor {
			pageThemeColor = payload.themeColor
		}
		if isPicking != payload.isPicking {
			isPicking = payload.isPicking
		}
		if let picked = payload.picked {
			inspectedElement = picked.value
			if picked.value != nil {
				selectedTab = .element
				isPanelPresented = true
			}
		}

		for entry in payload.console {
			appendConsole(entry)
		}
		if consoleEntries.count > Self.maxConsoleEntries {
			consoleEntries.removeFirst(consoleEntries.count - Self.maxConsoleEntries)
		}

		if payload.network.isEmpty == false {
			var indexByID = [String: Int]()
			for (index, entry) in networkEntries.enumerated() {
				indexByID[entry.id] = index
			}
			for entry in payload.network {
				if let index = indexByID[entry.id] {
					networkEntries[index] = entry
				}
				else {
					indexByID[entry.id] = networkEntries.count
					networkEntries.append(entry)
				}
			}
			if networkEntries.count > Self.maxNetworkEntries {
				networkEntries.removeFirst(networkEntries.count - Self.maxNetworkEntries)
			}
		}
	}

	private func appendConsole(_ entry: DeveloperConsoleEntry) {
		guard consoleEntries.contains(where: { $0.id == entry.id }) == false else { return }
		if entry.level == .error, isPanelPresented == false || selectedTab != .console {
			unseenErrorCount += 1
		}
		if var last = consoleEntries.last,
		   last.level == entry.level,
		   last.text == entry.text,
		   last.source == entry.source,
		   last.level != .input, last.level != .result {
			last.repeatCount += 1
			last.timestamp = entry.timestamp
			consoleEntries[consoleEntries.count - 1] = last
			return
		}
		consoleEntries.append(entry)
	}

	private func appendLocal(level: DeveloperConsoleEntry.Level, text: String) {
		localSequence += 1
		consoleEntries.append(DeveloperConsoleEntry(id: "local-\(localSequence)", level: level, text: text))
	}

	private func run(_ script: String) {
		bridge.evaluate(script) { [weak self] _, _ in
			self?.pollNow()
		}
	}
}

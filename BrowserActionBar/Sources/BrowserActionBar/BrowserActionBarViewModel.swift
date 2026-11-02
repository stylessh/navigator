import Foundation
import Observation

public enum BrowserActionBarMode: Equatable, Sendable {
	case currentTab
	case newTab
}

public enum BrowserActionBarQueryIntent: Equatable, Sendable {
	case empty
	case url(String)
	case search(String)
}

@MainActor
@Observable
public final class BrowserActionBarViewModel {
	public private(set) var isPresented = false
	public private(set) var mode: BrowserActionBarMode = .currentTab
	public private(set) var presentationSeed = UUID()
	public private(set) var query = ""
	public private(set) var selectedValue: String?
	public private(set) var selectedItemID: String?
	public private(set) var queryIntent: BrowserActionBarQueryIntent = .empty
	public var onStateChange: (() -> Void)?

	// MARK: Command bar state

	/// When false the bar behaves exactly like the original single-line location field.
	public var isCommandBarEnabled = false {
		didSet {
			guard oldValue != isCommandBarEnabled else { return }
			refreshResults(resetHighlight: true)
			notifyStateChange()
		}
	}

	public var dataSource = CommandBarDataSource.empty
	/// Called after the bar opens a URL, so the host can record it in its visit log.
	public var onDidOpenURL: ((String) -> Void)?
	/// Called for inline answers ("Copy"). The view wires this to the pasteboard.
	public var onCopy: ((String) -> Void)?

	public private(set) var scope: CommandBarScope = .all
	public private(set) var siteSearch: CommandBarSiteSearch?
	public private(set) var sections = [CommandBarSection]()
	public private(set) var highlightedItemID: String?
	/// Changes whenever the view model rewrites the query (prefix → scope chip, site search),
	/// so the view knows to push the new text into the field even while editing.
	public private(set) var queryReplacementSeed = UUID()
	private var pristineQuery: String?
	private var lastResultsRefreshAt = Date.distantPast
	private let resultsBuilder = CommandBarResultsBuilder()

	private let onOpenCurrentTab: (String) -> Void
	private let onOpenNewTab: (String) -> Void

	public init(
		onOpenCurrentTab: @escaping (String) -> Void,
		onOpenNewTab: @escaping (String) -> Void
	) {
		self.onOpenCurrentTab = onOpenCurrentTab
		self.onOpenNewTab = onOpenNewTab
	}

	public var normalizedQuery: String? {
		Self.normalize(query)
	}

	public var placeholder: String? {
		if isCommandBarEnabled {
			if let siteSearch {
				return "Search \(siteSearch.name)"
			}
			switch scope {
			case .all:
				break
			case .tabs:
				return "Search open tabs"
			case .history:
				return "Search history"
			case .commands:
				return "Run a command"
			}
			if mode == .newTab {
				return "Search or enter address · @ tabs · # history · > commands"
			}
		}
		switch mode {
		case .currentTab:
			return nil
		case .newTab:
			return localized(.placeholderNewTab)
		}
	}

	public func updateQuery(_ query: String) {
		guard self.query != query else { return }
		self.query = query
		if isCommandBarEnabled {
			applyInlineScopeTriggers()
		}
		syncQueryIntent()
		if isCommandBarEnabled {
			refreshResults(resetHighlight: true)
		}

		let normalizedValue = Self.normalize(self.query)
		if selectedValue != normalizedValue {
			selectedValue = normalizedValue
			selectedItemID = normalizedValue
		}

		notifyStateChange()
	}

	public func selectValue(_ value: String?) {
		let normalizedValue = value.flatMap(Self.normalize)
		guard selectedValue != normalizedValue || selectedItemID != normalizedValue else { return }
		selectedValue = normalizedValue
		selectedItemID = normalizedValue
		if query != (normalizedValue ?? "") {
			query = normalizedValue ?? ""
		}
		syncQueryIntent()
		notifyStateChange()
	}

	public func presentCurrentTab(url: String) {
		guard !(isPresented && mode == .currentTab) else {
			dismiss()
			return
		}
		present(mode: .currentTab, query: url)
	}

	public func presentNewTab() {
		guard !(isPresented && mode == .newTab) else {
			dismiss()
			return
		}
		present(mode: .newTab, query: "")
	}

	public func dismiss() {
		guard isPresented else { return }
		isPresented = false
		notifyStateChange()
	}

	public func performPrimaryAction(with value: String) {
		guard let normalizedValue = Self.normalize(value) else { return }
		let resolvedNavigationURL = Self.resolvedNavigationURL(from: normalizedValue)

		isPresented = false
		query = normalizedValue
		selectedValue = normalizedValue
		selectedItemID = normalizedValue
		queryIntent = Self.resolveQueryIntent(from: normalizedValue)
		notifyStateChange()

		switch mode {
		case .currentTab:
			onOpenCurrentTab(resolvedNavigationURL)
		case .newTab:
			onOpenNewTab(resolvedNavigationURL)
		}
	}

	private func present(mode: BrowserActionBarMode, query: String, scope: CommandBarScope = .all) {
		let normalizedValue = Self.normalize(query)

		self.scope = scope
		siteSearch = nil
		pristineQuery = Self.normalize(query)
		self.mode = mode
		self.query = query
		selectedValue = normalizedValue
		selectedItemID = normalizedValue
		queryIntent = Self.resolveQueryIntent(from: query)
		presentationSeed = UUID()
		isPresented = true
		refreshResults(resetHighlight: true)

		notifyStateChange()
	}

	// MARK: - Command bar

	/// Opens the bar as a command palette (⌘K). URLs open in a new tab; tabs/commands act in place.
	public func presentCommandBar(scope: CommandBarScope = .all) {
		guard !(isPresented && mode == .newTab && self.scope == scope) else {
			dismiss()
			return
		}
		present(mode: .newTab, query: "", scope: scope)
	}

	public var flatItems: [CommandBarItem] {
		sections.flatMap(\.items)
	}

	public var highlightedItem: CommandBarItem? {
		guard let highlightedItemID else { return nil }
		return flatItems.first { $0.id == highlightedItemID }
	}

	/// Re-query the data source without moving the highlight, e.g. after a tab title changes.
	public func reloadResults() {
		guard isPresented, isCommandBarEnabled else { return }
		refreshResults(resetHighlight: false)
		notifyStateChange()
	}

	public func moveHighlight(by step: Int) {
		let items = flatItems
		guard !items.isEmpty else { return }
		let currentIndex = highlightedItemID.flatMap { id in items.firstIndex { $0.id == id } } ?? -1
		var nextIndex = currentIndex + step
		if nextIndex < 0 { nextIndex = items.count - 1 }
		if nextIndex >= items.count { nextIndex = 0 }
		highlightedItemID = items[nextIndex].id
		notifyStateChange()
	}

	public func moveHighlightToSection(by step: Int) {
		let starts = sections.compactMap(\.items.first?.id)
		guard !starts.isEmpty else { return }
		let currentSection = sections.firstIndex { section in
			section.items.contains { $0.id == highlightedItemID }
		} ?? 0
		let next = min(max(currentSection + step, 0), starts.count - 1)
		highlightedItemID = starts[next]
		notifyStateChange()
	}

	/// Pointer hover. Ignored right after the results change, so rows sliding under a resting
	/// cursor don't steal the highlight while the person types.
	public func hoverHighlight(itemID: String) {
		guard Date().timeIntervalSince(lastResultsRefreshAt) > 0.3 else { return }
		highlight(itemID: itemID)
	}

	public func highlight(itemID: String) {
		guard highlightedItemID != itemID, flatItems.contains(where: { $0.id == itemID }) else { return }
		highlightedItemID = itemID
		notifyStateChange()
	}

	/// ↩ in the field. Returns false when there is nothing to activate (caller falls back to the plain URL path).
	@discardableResult
	public func activateHighlighted(forceNewTab: Bool = false) -> Bool {
		guard isCommandBarEnabled, let item = highlightedItem else { return false }
		activate(item, forceNewTab: forceNewTab)
		return true
	}

	public func activate(_ item: CommandBarItem, forceNewTab: Bool = false) {
		switch item.action {
		case let .open(url):
			isPresented = false
			notifyStateChange()
			if forceNewTab || mode == .newTab {
				onOpenNewTab(url)
			}
			else {
				onOpenCurrentTab(url)
			}
			onDidOpenURL?(url)
		case let .switchToTab(id):
			isPresented = false
			notifyStateChange()
			dataSource.switchToTab(id)
		case let .run(command):
			isPresented = false
			notifyStateChange()
			// Let the panel resign key before the command runs so focus lands back in the window.
			Task { @MainActor in
				command.perform()
			}
		case let .copy(value):
			onCopy?(value)
			isPresented = false
			notifyStateChange()
		case let .enterSiteSearch(siteSearch):
			enterSiteSearch(siteSearch, remainingQuery: "")
		}
	}

	/// ⇥ in the field: accept a site-search suggestion, or complete the highlighted row's text.
	@discardableResult
	public func acceptCompletion() -> Bool {
		guard isCommandBarEnabled, siteSearch == nil else { return false }
		if let siteItem = flatItems.first(where: { $0.kind == .siteSearch }),
		   case let .enterSiteSearch(siteSearch) = siteItem.action {
			enterSiteSearch(siteSearch, remainingQuery: "")
			return true
		}
		guard let item = highlightedItem else { return false }
		let completion: String? = switch item.action {
		case let .open(url) where item.kind == .history || item.kind == .navigate:
			CommandBarURLResolver.displayURL(url)
		default:
			nil
		}
		guard let completion, completion != query else { return false }
		replaceQuery(with: completion)
		return true
	}

	/// ⌫ on an empty field: leave the current scope/site search. Returns true if it consumed the key.
	@discardableResult
	public func popScope() -> Bool {
		guard isCommandBarEnabled, query.isEmpty else { return false }
		if siteSearch != nil {
			siteSearch = nil
		}
		else if scope != .all {
			scope = .all
		}
		else {
			return false
		}
		refreshResults(resetHighlight: true)
		queryReplacementSeed = UUID()
		notifyStateChange()
		return true
	}

	private func enterSiteSearch(_ siteSearch: CommandBarSiteSearch, remainingQuery: String) {
		self.siteSearch = siteSearch
		scope = .all
		replaceQuery(with: remainingQuery)
	}

	private func replaceQuery(with value: String) {
		query = value
		pristineQuery = nil
		let normalizedValue = Self.normalize(value)
		selectedValue = normalizedValue
		selectedItemID = normalizedValue
		syncQueryIntent()
		refreshResults(resetHighlight: true)
		queryReplacementSeed = UUID()
		notifyStateChange()
	}

	/// `@foo` → tabs scope, `#foo` → history, `>foo` → commands, `yt foo` → YouTube search.
	private func applyInlineScopeTriggers() {
		guard scope == .all, siteSearch == nil, let first = query.first else { return }

		if let nextScope = CommandBarScope.scope(forPrefix: first) {
			scope = nextScope
			query = String(query.dropFirst())
			queryReplacementSeed = UUID()
			return
		}

		if let spaceIndex = query.firstIndex(of: " ") {
			let keyword = query[..<spaceIndex].lowercased()
			if let match = dataSource.siteSearches().first(where: { $0.keyword == keyword }) {
				siteSearch = match
				query = String(query[query.index(after: spaceIndex)...])
				queryReplacementSeed = UUID()
			}
		}
	}

	private func refreshResults(resetHighlight: Bool) {
		guard isCommandBarEnabled, isPresented else {
			sections = []
			highlightedItemID = nil
			return
		}

		let isPristine = pristineQuery != nil && Self.normalize(query) == pristineQuery
		if !isPristine {
			pristineQuery = nil
		}

		let input = CommandBarResultsBuilder.Input(
			query: query,
			scope: scope,
			siteSearch: siteSearch,
			isPristine: isPristine,
			tabs: scope == .all || scope == .tabs ? dataSource.tabs() : [],
			history: scope == .all || scope == .history ? dataSource.history() : [],
			commands: scope == .all || scope == .commands ? dataSource.commands() : [],
			siteSearches: dataSource.siteSearches()
		)
		sections = resultsBuilder.sections(for: input)
		lastResultsRefreshAt = Date()

		let items = flatItems
		if !resetHighlight, let highlightedItemID, items.contains(where: { $0.id == highlightedItemID }) {
			return
		}
		// In the zero state nothing is highlighted, so ↩ keeps its old meaning (reload the URL as typed).
		let isZeroState = isPristine || Self.normalize(query) == nil
		highlightedItemID = isZeroState && siteSearch == nil ? nil : items.first?.id
	}

	private func syncQueryIntent() {
		queryIntent = Self.resolveQueryIntent(from: query)
	}

	private func notifyStateChange() {
		onStateChange?()
	}

	private func localized(_ key: BrowserActionBarLocalizationKey) -> String {
		Self.localized(key)
	}

	private static func localized(_ key: BrowserActionBarLocalizationKey) -> String {
		String(localized: key.resource)
	}

	private static func normalize(_ value: String) -> String? {
		let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
		return trimmed.isEmpty ? nil : trimmed
	}

	private static func resolveQueryIntent(from value: String) -> BrowserActionBarQueryIntent {
		guard let normalizedValue = normalize(value) else { return .empty }
		if let resolvedURL = CommandBarURLResolver.resolvedURL(from: normalizedValue) {
			return .url(resolvedURL)
		}
		return .search(CommandBarURLResolver.searchURL(for: normalizedValue))
	}

	private static func resolvedNavigationURL(from normalizedValue: String) -> String {
		CommandBarURLResolver.resolvedURL(from: normalizedValue) ?? CommandBarURLResolver.searchURL(for: normalizedValue)
	}
}

private enum BrowserActionBarLocalizationKey: String {
	case placeholderNewTab = "browser.actionBar.placeholder.newTab"
}

private extension BrowserActionBarLocalizationKey {
	var resource: LocalizedStringResource {
		LocalizedStringResource(String.LocalizationValue(rawValue), bundle: .module)
	}
}

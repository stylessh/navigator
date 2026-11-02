import Foundation

/// Pure ranking + grouping for the command bar. No UI, no app state: everything comes in as values,
/// so it can be unit tested and run on every keystroke.
public struct CommandBarResultsBuilder: Sendable {
	public struct Input: Sendable {
		public var query: String
		public var scope: CommandBarScope
		public var siteSearch: CommandBarSiteSearch?
		/// True when the field still shows the text it was opened with (e.g. the current URL for ⌘L).
		public var isPristine: Bool
		public var tabs: [CommandBarTab]
		public var history: [CommandBarHistoryEntry]
		public var commands: [CommandBarCommand]
		public var siteSearches: [CommandBarSiteSearch]
		public var now: Date

		public init(
			query: String,
			scope: CommandBarScope = .all,
			siteSearch: CommandBarSiteSearch? = nil,
			isPristine: Bool = false,
			tabs: [CommandBarTab] = [],
			history: [CommandBarHistoryEntry] = [],
			commands: [CommandBarCommand] = [],
			siteSearches: [CommandBarSiteSearch] = CommandBarSiteSearch.builtIn,
			now: Date = Date()
		) {
			self.query = query
			self.scope = scope
			self.siteSearch = siteSearch
			self.isPristine = isPristine
			self.tabs = tabs
			self.history = history
			self.commands = commands
			self.siteSearches = siteSearches
			self.now = now
		}
	}

	public enum Limits {
		public static let tabsInAll = 4
		public static let historyInAll = 5
		public static let commandsInAll = 3
		public static let scoped = 40
		public static let suggestionsWhenEmpty = 6
	}

	/// Results below this fuzzy score are treated as noise.
	static let minimumScore = 0.02

	public init() {}

	public func sections(for input: Input) -> [CommandBarSection] {
		let query = input.query.trimmingCharacters(in: .whitespacesAndNewlines)

		if let siteSearch = input.siteSearch {
			return siteSearchSections(siteSearch: siteSearch, query: query)
		}

		switch input.scope {
		case .all:
			return allSections(input: input, query: input.isPristine ? "" : query)
		case .tabs:
			return compact([section("tabs", nil, tabItems(input: input, query: query, limit: Limits.scoped))])
		case .history:
			return compact([section("history", nil, historyItems(input: input, query: query, limit: Limits.scoped))])
		case .commands:
			return compact([section("commands", nil, commandItems(input: input, query: query, limit: Limits.scoped))])
		}
	}

	// MARK: - Sections

	private func allSections(input: Input, query: String) -> [CommandBarSection] {
		guard !query.isEmpty else {
			// Zero-state: what you were just doing, plus a couple of handy commands.
			let recentHistory = historyItems(input: input, query: "", limit: Limits.suggestionsWhenEmpty)
			let tabs = tabItems(input: input, query: "", limit: Limits.tabsInAll)
			return compact([
				section("tabs", "Open tabs", tabs),
				section("history", "Recently visited", recentHistory),
			])
		}

		var top = [CommandBarItem]()
		if let value = CommandBarCalculator.evaluate(query) {
			let formatted = CommandBarCalculator.format(value)
			top.append(CommandBarItem(
				id: "answer:\(query)",
				kind: .answer,
				title: "= \(formatted)",
				subtitle: query,
				symbolName: "equal.circle",
				accessory: "Copy",
				action: .copy(formatted),
				score: 1
			))
		}
		top.append(primaryItem(for: query))
		if let siteSearch = matchingSiteSearch(for: query, in: input.siteSearches) {
			top.append(CommandBarItem(
				id: "site:\(siteSearch.keyword)",
				kind: .siteSearch,
				title: "Search \(siteSearch.name)",
				subtitle: nil,
				symbolName: siteSearch.symbolName,
				accessory: "⇥",
				action: .enterSiteSearch(siteSearch),
				score: 0.9
			))
		}

		return compact([
			section("top", nil, top),
			section("tabs", "Switch to tab", tabItems(input: input, query: query, limit: Limits.tabsInAll)),
			section("history", "History", historyItems(input: input, query: query, limit: Limits.historyInAll)),
			section("commands", "Commands", commandItems(input: input, query: query, limit: Limits.commandsInAll)),
		])
	}

	private func siteSearchSections(siteSearch: CommandBarSiteSearch, query: String) -> [CommandBarSection] {
		guard !query.isEmpty else { return [] }
		let item = CommandBarItem(
			id: "site-query:\(siteSearch.keyword):\(query)",
			kind: .search,
			title: query,
			subtitle: "Search \(siteSearch.name)",
			symbolName: siteSearch.symbolName,
			accessory: "↩",
			action: .open(url: siteSearch.url(for: query)),
			score: 1
		)
		return [CommandBarSection(id: "site", title: nil, items: [item])]
	}

	// MARK: - Items

	public func primaryItem(for query: String) -> CommandBarItem {
		if let url = CommandBarURLResolver.resolvedURL(from: query) {
			return CommandBarItem(
				id: "navigate:\(url)",
				kind: .navigate,
				title: CommandBarURLResolver.displayURL(url),
				subtitle: "Open page",
				symbolName: "globe",
				accessory: "↩",
				action: .open(url: url),
				score: 1
			)
		}
		return CommandBarItem(
			id: "search:\(query)",
			kind: .search,
			title: query,
			subtitle: "Search Google",
			symbolName: "magnifyingglass",
			accessory: "↩",
			action: .open(url: CommandBarURLResolver.searchURL(for: query)),
			score: 1
		)
	}

	func tabItems(input: Input, query: String, limit: Int) -> [CommandBarItem] {
		let scored: [(CommandBarTab, Double)] = input.tabs.compactMap { tab in
			guard !tab.isSelected || !query.isEmpty else { return nil }
			let score = query.isEmpty
				? 1
				: max(
					CommandBarScorer.score(tab.title, query: query),
					CommandBarScorer.score(CommandBarURLResolver.displayURL(tab.url), query: query) * 0.95
				)
			return score > Self.minimumScore ? (tab, score) : nil
		}
		return scored
			.sorted { $0.1 > $1.1 }
			.prefix(limit)
			.map { tab, score in
				CommandBarItem(
					id: "tab:\(tab.id.uuidString)",
					kind: .tab,
					title: tab.title.isEmpty ? CommandBarURLResolver.displayURL(tab.url) : tab.title,
					subtitle: [CommandBarURLResolver.displayURL(tab.url), tab.spaceName].compactMap { $0 }.joined(separator: " · "),
					symbolName: tab.isPinned ? "pin" : "square.on.square",
					iconURL: tab.faviconURL,
					accessory: tab.isSelected ? "Current" : "Switch",
					action: .switchToTab(id: tab.id),
					score: score
				)
			}
	}

	func historyItems(input: Input, query: String, limit: Int) -> [CommandBarItem] {
		let openURLs = Set(input.tabs.map { CommandBarURLResolver.normalizedKey($0.url) })
		var seen = Set<String>()
		var scored = [(CommandBarHistoryEntry, Double)]()

		for entry in input.history {
			let key = CommandBarURLResolver.normalizedKey(entry.url)
			guard !openURLs.contains(key), seen.insert(key).inserted else { continue }
			let fuzzy: Double = if query.isEmpty {
				1
			}
			else {
				max(
					CommandBarScorer.score(entry.title ?? "", query: query),
					CommandBarScorer.score(CommandBarURLResolver.displayURL(entry.url), query: query)
				)
			}
			guard fuzzy > Self.minimumScore else { continue }
			scored.append((entry, fuzzy * frecency(entry, now: input.now)))
		}

		return scored
			.sorted { $0.1 > $1.1 }
			.prefix(limit)
			.map { entry, score in
				let display = CommandBarURLResolver.displayURL(entry.url)
				let title = entry.title.flatMap { $0.isEmpty ? nil : $0 } ?? display
				return CommandBarItem(
					id: "history:\(entry.url)",
					kind: .history,
					title: title,
					subtitle: title == display ? nil : display,
					symbolName: "clock",
					accessory: entry.lastVisitedAt.map { relativeAge(of: $0, now: input.now) },
					action: .open(url: entry.url),
					score: score
				)
			}
	}

	func commandItems(input: Input, query: String, limit: Int) -> [CommandBarItem] {
		let scored: [(CommandBarCommand, Double)] = input.commands.enumerated().compactMap { offset, command in
			// Preserve declaration order when there is no query.
			let score = query.isEmpty
				? 1 - Double(offset) * 0.0001
				: CommandBarScorer.score(command.title, query: query, keywords: command.keywords)
			return score > Self.minimumScore ? (command, score) : nil
		}
		return scored
			.sorted { $0.1 > $1.1 }
			.prefix(limit)
			.map { command, score in
				CommandBarItem(
					id: "command:\(command.id)",
					kind: .command,
					title: command.title,
					subtitle: nil,
					symbolName: command.symbolName,
					accessory: command.shortcut,
					action: .run(command),
					score: score
				)
			}
	}

	// MARK: - Helpers

	/// Suggests a site search when the query is (a prefix of) a site keyword, e.g. "yt".
	func matchingSiteSearch(for query: String, in siteSearches: [CommandBarSiteSearch]) -> CommandBarSiteSearch? {
		let lowered = query.lowercased()
		guard !lowered.contains(" ") else { return nil }
		return siteSearches.first { $0.keyword == lowered }
			?? siteSearches.first { lowered.count >= 2 && $0.name.lowercased().hasPrefix(lowered) }
	}

	/// Boost often- and recently-visited pages. Returns roughly 0.6...1.4.
	func frecency(_ entry: CommandBarHistoryEntry, now: Date) -> Double {
		let visits = 1 + log(Double(max(entry.visitCount, 1))) * 0.08
		guard let visitedAt = entry.lastVisitedAt else { return 0.7 * visits }
		let age = now.timeIntervalSince(visitedAt)
		let recency: Double = switch age {
		case ..<(60 * 60 * 4): 1.0
		case ..<(60 * 60 * 24): 0.95
		case ..<(60 * 60 * 24 * 7): 0.85
		case ..<(60 * 60 * 24 * 30): 0.75
		default: 0.6
		}
		return recency * visits
	}

	private func relativeAge(of date: Date, now: Date) -> String {
		let seconds = max(0, now.timeIntervalSince(date))
		switch seconds {
		case ..<60: return "now"
		case ..<3600: return "\(Int(seconds / 60))m"
		case ..<86400: return "\(Int(seconds / 3600))h"
		case ..<(86400 * 30): return "\(Int(seconds / 86400))d"
		default: return "\(Int(seconds / (86400 * 30)))mo"
		}
	}

	private func section(_ id: String, _ title: String?, _ items: [CommandBarItem]) -> CommandBarSection {
		CommandBarSection(id: id, title: title, items: items)
	}

	private func compact(_ sections: [CommandBarSection]) -> [CommandBarSection] {
		sections.filter { !$0.items.isEmpty }
	}
}

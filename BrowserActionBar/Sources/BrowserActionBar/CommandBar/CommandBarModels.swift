import Foundation

/// Which slice of the world the command bar is searching.
public enum CommandBarScope: String, CaseIterable, Equatable, Sendable {
	case all
	case tabs
	case history
	case commands

	/// Typing this prefix as the first character switches into the scope.
	public var prefix: Character? {
		switch self {
		case .all: nil
		case .tabs: "@"
		case .history: "#"
		case .commands: ">"
		}
	}

	public var title: String {
		switch self {
		case .all: "Search"
		case .tabs: "Tabs"
		case .history: "History"
		case .commands: "Commands"
		}
	}

	public var symbolName: String {
		switch self {
		case .all: "magnifyingglass"
		case .tabs: "square.on.square"
		case .history: "clock.arrow.circlepath"
		case .commands: "command"
		}
	}

	public static func scope(forPrefix character: Character) -> CommandBarScope? {
		allCases.first { $0.prefix == character }
	}
}

/// An open tab, as the command bar sees it.
public struct CommandBarTab: Equatable, Sendable, Identifiable {
	public let id: UUID
	public let title: String
	public let url: String
	public let isPinned: Bool
	public let isSelected: Bool
	public let spaceName: String?
	public let faviconURL: String?

	public init(
		id: UUID,
		title: String,
		url: String,
		isPinned: Bool,
		isSelected: Bool,
		spaceName: String? = nil,
		faviconURL: String? = nil
	) {
		self.id = id
		self.faviconURL = faviconURL
		self.title = title
		self.url = url
		self.isPinned = isPinned
		self.isSelected = isSelected
		self.spaceName = spaceName
	}
}

/// A page the person has visited (from imported history, tab back/forward lists, or the bar's own log).
public struct CommandBarHistoryEntry: Equatable, Sendable {
	public let url: String
	public let title: String?
	public let lastVisitedAt: Date?
	public let visitCount: Int

	public init(url: String, title: String?, lastVisitedAt: Date?, visitCount: Int = 1) {
		self.url = url
		self.title = title
		self.lastVisitedAt = lastVisitedAt
		self.visitCount = visitCount
	}
}

/// A browser command, e.g. "Reload page" or "New space".
public struct CommandBarCommand: Sendable, Identifiable {
	public let id: String
	public let title: String
	public let symbolName: String
	public let keywords: [String]
	public let shortcut: String?
	public let perform: @MainActor @Sendable () -> Void

	public init(
		id: String,
		title: String,
		symbolName: String,
		keywords: [String] = [],
		shortcut: String? = nil,
		perform: @escaping @MainActor @Sendable () -> Void
	) {
		self.id = id
		self.title = title
		self.symbolName = symbolName
		self.keywords = keywords
		self.shortcut = shortcut
		self.perform = perform
	}
}

/// A keyword that scopes a search to one site, e.g. `yt` + Tab → YouTube.
public struct CommandBarSiteSearch: Equatable, Sendable, Identifiable {
	public var id: String { keyword }
	public let keyword: String
	public let name: String
	public let symbolName: String
	/// URL template where `%s` is replaced by the percent-encoded query.
	public let template: String

	public init(keyword: String, name: String, symbolName: String, template: String) {
		self.keyword = keyword
		self.name = name
		self.symbolName = symbolName
		self.template = template
	}

	public func url(for query: String) -> String {
		let encoded = query.addingPercentEncoding(withAllowedCharacters: .commandBarQueryAllowed) ?? query
		return template.replacingOccurrences(of: "%s", with: encoded)
	}

	public static let builtIn: [CommandBarSiteSearch] = [
		.init(keyword: "g", name: "Google", symbolName: "magnifyingglass", template: "https://www.google.com/search?q=%s"),
		.init(keyword: "yt", name: "YouTube", symbolName: "play.rectangle", template: "https://www.youtube.com/results?search_query=%s"),
		.init(keyword: "gh", name: "GitHub", symbolName: "chevron.left.forwardslash.chevron.right", template: "https://github.com/search?q=%s"),
		.init(keyword: "w", name: "Wikipedia", symbolName: "book", template: "https://en.wikipedia.org/w/index.php?search=%s"),
		.init(keyword: "mdn", name: "MDN", symbolName: "doc.text", template: "https://developer.mozilla.org/search?q=%s"),
		.init(keyword: "npm", name: "npm", symbolName: "shippingbox", template: "https://www.npmjs.com/search?q=%s"),
		.init(keyword: "maps", name: "Maps", symbolName: "map", template: "https://www.google.com/maps/search/%s"),
		.init(keyword: "ddg", name: "DuckDuckGo", symbolName: "magnifyingglass.circle", template: "https://duckduckgo.com/?q=%s"),
	]
}

extension CharacterSet {
	static let commandBarQueryAllowed: CharacterSet = {
		var set = CharacterSet.urlQueryAllowed
		set.remove(charactersIn: "&+=?#/")
		return set
	}()
}

/// What happens when a row is chosen.
public enum CommandBarAction: Sendable {
	/// Navigate to a URL. Respects the current mode (current tab vs. new tab); ⌘↩ forces a new tab.
	case open(url: String)
	case switchToTab(id: UUID)
	case run(CommandBarCommand)
	case copy(String)
	case enterSiteSearch(CommandBarSiteSearch)
}

public enum CommandBarItemKind: String, Equatable, Sendable {
	case navigate
	case search
	case siteSearch
	case tab
	case history
	case command
	case answer
}

/// One row in the results list.
public struct CommandBarItem: Identifiable, Sendable {
	public let id: String
	public let kind: CommandBarItemKind
	public let title: String
	public let subtitle: String?
	public let symbolName: String
	/// Remote icon (favicon) shown instead of the symbol when it loads.
	public let iconURL: String?
	/// Optional trailing hint, e.g. a keyboard shortcut or "Switch to tab".
	public let accessory: String?
	public let action: CommandBarAction
	public let score: Double

	public init(
		id: String,
		kind: CommandBarItemKind,
		title: String,
		subtitle: String? = nil,
		symbolName: String,
		iconURL: String? = nil,
		accessory: String? = nil,
		action: CommandBarAction,
		score: Double
	) {
		self.id = id
		self.kind = kind
		self.title = title
		self.subtitle = subtitle
		self.symbolName = symbolName
		self.iconURL = iconURL
		self.accessory = accessory
		self.action = action
		self.score = score
	}
}

public struct CommandBarSection: Identifiable, Sendable {
	public let id: String
	public let title: String?
	public let items: [CommandBarItem]

	public init(id: String, title: String?, items: [CommandBarItem]) {
		self.id = id
		self.title = title
		self.items = items
	}
}

/// Everything the bar needs from the host app, provided lazily on each query.
@MainActor
public struct CommandBarDataSource {
	public var tabs: () -> [CommandBarTab]
	public var history: () -> [CommandBarHistoryEntry]
	public var commands: () -> [CommandBarCommand]
	public var siteSearches: () -> [CommandBarSiteSearch]
	public var switchToTab: (UUID) -> Void

	public init(
		tabs: @escaping () -> [CommandBarTab] = { [] },
		history: @escaping () -> [CommandBarHistoryEntry] = { [] },
		commands: @escaping () -> [CommandBarCommand] = { [] },
		siteSearches: @escaping () -> [CommandBarSiteSearch] = { CommandBarSiteSearch.builtIn },
		switchToTab: @escaping (UUID) -> Void = { _ in }
	) {
		self.tabs = tabs
		self.history = history
		self.commands = commands
		self.siteSearches = siteSearches
		self.switchToTab = switchToTab
	}

	public static let empty = CommandBarDataSource()
}

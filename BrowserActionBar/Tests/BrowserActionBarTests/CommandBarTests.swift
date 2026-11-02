@testable import BrowserActionBar
import Foundation
import XCTest

final class CommandBarScorerTests: XCTestCase {
	func testEmptyQueryMatchesEverything() {
		XCTAssertEqual(CommandBarScorer.score("Anything", query: ""), 1)
	}

	func testNonMatchScoresZero() {
		XCTAssertEqual(CommandBarScorer.score("GitHub", query: "xyz"), 0)
	}

	func testExactMatchBeatsPrefixBeatsScattered() {
		let exact = CommandBarScorer.score("reload", query: "reload")
		let prefix = CommandBarScorer.score("reload page", query: "reload")
		let scattered = CommandBarScorer.score("reopen closed tab and load", query: "reload")
		XCTAssertGreaterThan(exact, prefix)
		XCTAssertGreaterThan(prefix, scattered)
	}

	func testWordStartsBeatMidWordMatches() {
		let wordStart = CommandBarScorer.score("New Space", query: "ns")
		let midWord = CommandBarScorer.score("Lens", query: "ns")
		XCTAssertGreaterThan(wordStart, midWord)
	}

	func testKeywordsAreSearchable() {
		XCTAssertEqual(CommandBarScorer.score("Reload page", query: "refresh"), 0)
		XCTAssertGreaterThan(CommandBarScorer.score("Reload page", query: "refresh", keywords: ["refresh"]), 0)
	}

	func testCaseInsensitive() {
		XCTAssertGreaterThan(CommandBarScorer.score("GitHub", query: "github"), 0.9)
	}
}

final class CommandBarCalculatorTests: XCTestCase {
	func testArithmetic() {
		XCTAssertEqual(CommandBarCalculator.evaluate("24*7"), 168)
		XCTAssertEqual(CommandBarCalculator.evaluate("2 + 3 * 4"), 14)
		XCTAssertEqual(CommandBarCalculator.evaluate("(2 + 3) * 4"), 20)
		XCTAssertEqual(CommandBarCalculator.evaluate("2^10"), 1024)
		XCTAssertEqual(CommandBarCalculator.evaluate("-3 + 5"), 2)
		XCTAssertEqual(CommandBarCalculator.evaluate("10 % 4"), 2)
		XCTAssertEqual(CommandBarCalculator.evaluate("1,000 x 3"), 3000)
	}

	func testRejectsNonMath() {
		XCTAssertNil(CommandBarCalculator.evaluate("42"))
		XCTAssertNil(CommandBarCalculator.evaluate("github.com"))
		XCTAssertNil(CommandBarCalculator.evaluate("hello world"))
		XCTAssertNil(CommandBarCalculator.evaluate("1/0"))
		XCTAssertNil(CommandBarCalculator.evaluate("(1+2"))
		XCTAssertNil(CommandBarCalculator.evaluate("2 +"))
	}
}

final class CommandBarResultsBuilderTests: XCTestCase {
	private let builder = CommandBarResultsBuilder()
	private let now = Date(timeIntervalSince1970: 1_800_000_000)

	private func tab(_ title: String, _ url: String, selected: Bool = false) -> CommandBarTab {
		CommandBarTab(id: UUID(), title: title, url: url, isPinned: false, isSelected: selected)
	}

	func testTypedURLComesFirst() {
		let sections = builder.sections(for: .init(query: "example.com", now: now))
		let first = sections.first?.items.first
		XCTAssertEqual(first?.kind, .navigate)
		guard case let .open(url)? = first?.action else { return XCTFail("expected open") }
		XCTAssertEqual(url, "https://example.com")
	}

	func testSearchFallback() {
		let first = builder.sections(for: .init(query: "swift concurrency", now: now)).first?.items.first
		XCTAssertEqual(first?.kind, .search)
	}

	func testCalculatorAnswerIsOnTop() {
		let first = builder.sections(for: .init(query: "12*12", now: now)).first?.items.first
		XCTAssertEqual(first?.kind, .answer)
		XCTAssertEqual(first?.title, "= 144")
	}

	func testMatchingTabsAppearAsSwitchTargets() {
		let input = CommandBarResultsBuilder.Input(
			query: "git",
			tabs: [tab("GitHub", "https://github.com"), tab("Linear", "https://linear.app")],
			now: now
		)
		let tabs = builder.sections(for: input).first { $0.id == "tabs" }?.items ?? []
		XCTAssertEqual(tabs.map(\.title), ["GitHub"])
	}

	func testHistoryDedupesAgainstOpenTabs() {
		let input = CommandBarResultsBuilder.Input(
			query: "git",
			tabs: [tab("GitHub", "https://github.com/")],
			history: [
				CommandBarHistoryEntry(url: "https://github.com", title: "GitHub", lastVisitedAt: now),
				CommandBarHistoryEntry(url: "https://gitlab.com", title: "GitLab", lastVisitedAt: now),
			],
			now: now
		)
		let history = builder.sections(for: input).first { $0.id == "history" }?.items ?? []
		XCTAssertEqual(history.map(\.title), ["GitLab"])
	}

	func testRecentHistoryOutranksStaleHistory() {
		let input = CommandBarResultsBuilder.Input(
			query: "docs",
			scope: .history,
			history: [
				CommandBarHistoryEntry(url: "https://old.example/docs", title: "Docs", lastVisitedAt: now.addingTimeInterval(-86400 * 90)),
				CommandBarHistoryEntry(url: "https://new.example/docs", title: "Docs", lastVisitedAt: now.addingTimeInterval(-60)),
			],
			now: now
		)
		let items = builder.sections(for: input).first?.items ?? []
		XCTAssertEqual(items.first?.subtitle, "new.example/docs")
	}

	func testCommandsScopeOnlyShowsCommands() {
		let input = CommandBarResultsBuilder.Input(
			query: "rel",
			scope: .commands,
			tabs: [tab("Release notes", "https://example.com/release")],
			commands: [CommandBarCommand(id: "reload", title: "Reload page", symbolName: "arrow.clockwise") {}],
			now: now
		)
		let sections = builder.sections(for: input)
		XCTAssertEqual(sections.count, 1)
		XCTAssertEqual(sections.first?.items.map(\.kind), [.command])
	}

	func testSiteKeywordSuggestsSiteSearch() {
		let items = builder.sections(for: .init(query: "yt", now: now)).first?.items ?? []
		XCTAssertTrue(items.contains { $0.kind == .siteSearch && $0.title == "Search YouTube" })
	}

	func testSiteSearchBuildsTemplateURL() {
		let youtube = CommandBarSiteSearch.builtIn.first { $0.keyword == "yt" }!
		let items = builder.sections(for: .init(query: "lofi beats", siteSearch: youtube, now: now)).first?.items ?? []
		guard case let .open(url)? = items.first?.action else { return XCTFail("expected open") }
		XCTAssertEqual(url, "https://www.youtube.com/results?search_query=lofi%20beats")
	}

	func testPristineQueryShowsZeroState() {
		let input = CommandBarResultsBuilder.Input(
			query: "https://navigator.zip",
			isPristine: true,
			tabs: [tab("Current", "https://navigator.zip", selected: true), tab("Other", "https://other.dev")],
			now: now
		)
		let sections = builder.sections(for: input)
		XCTAssertEqual(sections.first?.id, "tabs")
		XCTAssertEqual(sections.first?.items.map(\.title), ["Other"])
	}
}

@MainActor
final class CommandBarViewModelTests: XCTestCase {
	private func makeViewModel(
		openedCurrent: @escaping (String) -> Void = { _ in },
		openedNew: @escaping (String) -> Void = { _ in }
	) -> BrowserActionBarViewModel {
		let viewModel = BrowserActionBarViewModel(onOpenCurrentTab: openedCurrent, onOpenNewTab: openedNew)
		viewModel.isCommandBarEnabled = true
		return viewModel
	}

	func testPrefixSwitchesScope() {
		let viewModel = makeViewModel()
		viewModel.presentCommandBar()
		viewModel.updateQuery(">rel")
		XCTAssertEqual(viewModel.scope, .commands)
		XCTAssertEqual(viewModel.query, "rel")
	}

	func testBackspaceOnEmptyQueryPopsScope() {
		let viewModel = makeViewModel()
		viewModel.presentCommandBar()
		viewModel.updateQuery("@")
		XCTAssertEqual(viewModel.scope, .tabs)
		XCTAssertTrue(viewModel.popScope())
		XCTAssertEqual(viewModel.scope, .all)
		XCTAssertFalse(viewModel.popScope())
	}

	func testSiteKeywordWithSpaceEntersSiteSearch() {
		let viewModel = makeViewModel()
		viewModel.presentCommandBar()
		viewModel.updateQuery("gh swift")
		XCTAssertEqual(viewModel.siteSearch?.keyword, "gh")
		XCTAssertEqual(viewModel.query, "swift")
	}

	func testTabAcceptsSiteSearchSuggestion() {
		let viewModel = makeViewModel()
		viewModel.presentCommandBar()
		viewModel.updateQuery("yt")
		XCTAssertTrue(viewModel.acceptCompletion())
		XCTAssertEqual(viewModel.siteSearch?.keyword, "yt")
		XCTAssertEqual(viewModel.query, "")
	}

	func testArrowKeysWrap() {
		let viewModel = makeViewModel()
		viewModel.presentCommandBar()
		viewModel.updateQuery("yt")
		let ids = viewModel.flatItems.map(\.id)
		XCTAssertGreaterThan(ids.count, 1)
		XCTAssertEqual(viewModel.highlightedItemID, ids.first)
		viewModel.moveHighlight(by: -1)
		XCTAssertEqual(viewModel.highlightedItemID, ids.last)
		viewModel.moveHighlight(by: 1)
		XCTAssertEqual(viewModel.highlightedItemID, ids.first)
	}

	func testReturnOpensHighlightedURLInNewTabFromCommandBar() {
		var opened = [String]()
		let viewModel = makeViewModel(openedNew: { opened.append($0) })
		viewModel.presentCommandBar()
		viewModel.updateQuery("example.com")
		XCTAssertTrue(viewModel.activateHighlighted())
		XCTAssertEqual(opened, ["https://example.com"])
		XCTAssertFalse(viewModel.isPresented)
	}

	func testCommandReturnForcesNewTabFromLocationBar() {
		var current = [String]()
		var new = [String]()
		let viewModel = makeViewModel(openedCurrent: { current.append($0) }, openedNew: { new.append($0) })
		viewModel.presentCurrentTab(url: "https://navigator.zip")
		viewModel.updateQuery("example.com")
		XCTAssertTrue(viewModel.activateHighlighted(forceNewTab: true))
		XCTAssertEqual(current, [])
		XCTAssertEqual(new, ["https://example.com"])
	}

	func testPristineLocationBarHasNoHighlightSoReturnReloads() {
		let viewModel = makeViewModel()
		viewModel.dataSource = CommandBarDataSource(tabs: {
			[CommandBarTab(id: UUID(), title: "Other", url: "https://other.dev", isPinned: false, isSelected: false)]
		})
		viewModel.presentCurrentTab(url: "https://navigator.zip")
		XCTAssertFalse(viewModel.flatItems.isEmpty)
		XCTAssertNil(viewModel.highlightedItemID)
		XCTAssertFalse(viewModel.activateHighlighted())
	}

	func testSwitchToTabCallsDataSource() {
		let tabID = UUID()
		var switched: UUID?
		let viewModel = makeViewModel()
		viewModel.dataSource = CommandBarDataSource(
			tabs: { [CommandBarTab(id: tabID, title: "Linear", url: "https://linear.app", isPinned: false, isSelected: false)] },
			switchToTab: { switched = $0 }
		)
		viewModel.presentCommandBar(scope: .tabs)
		viewModel.updateQuery("lin")
		XCTAssertTrue(viewModel.activateHighlighted())
		XCTAssertEqual(switched, tabID)
	}

	func testDisabledCommandBarKeepsClassicBehavior() {
		let viewModel = BrowserActionBarViewModel(onOpenCurrentTab: { _ in }, onOpenNewTab: { _ in })
		viewModel.presentNewTab()
		viewModel.updateQuery(">rel")
		XCTAssertEqual(viewModel.scope, .all)
		XCTAssertEqual(viewModel.query, ">rel")
		XCTAssertTrue(viewModel.sections.isEmpty)
	}
}

import AppKit
import BrowserActionBar
import BrowserSidebar
import Foundation
import ModelKit
import Vendors

// MARK: - Experiment flag

extension NavigatorExperiment {
	static let commandBar = NavigatorExperiment(
		id: "commandBar",
		title: "Command bar",
		summary: "⌘K opens a Spotlight-style bar that searches open tabs, history and commands. ⌘L and ⌘T use it too. Type @ for tabs, # for history, > for commands, or yt + Tab to search a site.",
		isEnabledByDefault: true
	)
}

// MARK: - Visit log

/// A lightweight, local visit log so the command bar can rank pages by frecency.
/// Navigator has no global history store yet; this records top-level URLs as tabs navigate.
nonisolated struct NavigatorCommandBarVisit: Codable, Equatable, Sendable {
	var url: String
	var title: String?
	var visitCount: Int
	var lastVisitedAt: Date
}

nonisolated struct NavigatorCommandBarVisitLog: Codable, Equatable, Sendable {
	static let maximumEntries = 1500
	static let empty = NavigatorCommandBarVisitLog(visits: [])

	var visits: [NavigatorCommandBarVisit]

	mutating func record(url: String, title: String?, at date: Date) {
		guard Self.isRecordable(url) else { return }
		let key = CommandBarURLResolver.normalizedKey(url)
		if let index = visits.firstIndex(where: { CommandBarURLResolver.normalizedKey($0.url) == key }) {
			var visit = visits.remove(at: index)
			visit.visitCount += 1
			visit.lastVisitedAt = date
			if let title, !title.isEmpty {
				visit.title = title
			}
			visits.insert(visit, at: 0)
		}
		else {
			visits.insert(
				NavigatorCommandBarVisit(url: url, title: title, visitCount: 1, lastVisitedAt: date),
				at: 0
			)
			if visits.count > Self.maximumEntries {
				visits.removeLast(visits.count - Self.maximumEntries)
			}
		}
	}

	/// Updates the title of the most recent visit without counting a new visit
	/// (titles usually arrive a moment after the URL commits).
	mutating func updateTitle(_ title: String, for url: String) {
		let key = CommandBarURLResolver.normalizedKey(url)
		guard !title.isEmpty,
		      let index = visits.firstIndex(where: { CommandBarURLResolver.normalizedKey($0.url) == key }) else { return }
		visits[index].title = title
	}

	static func isRecordable(_ url: String) -> Bool {
		url.hasPrefix("https://") || url.hasPrefix("http://")
	}
}

extension URL {
	nonisolated static var navigatorCommandBarVisitLog: Self {
		navigatorApplicationSupportFile(named: "NavigatorCommandBarVisitLog")
	}
}

extension SharedKey where Self == FileStorageKey<NavigatorCommandBarVisitLog> {
	nonisolated static var navigatorCommandBarVisitLog: Self {
		fileStorage(
			.navigatorCommandBarVisitLog,
			decode: { data in try JSONDecoder().decode(NavigatorCommandBarVisitLog.self, from: data) },
			encode: { value in try JSONEncoder().encode(value) }
		)
	}
}

extension SharedReaderKey where Self == FileStorageKey<NavigatorCommandBarVisitLog>.Default {
	nonisolated static var navigatorCommandBarVisitLog: Self {
		Self[.navigatorCommandBarVisitLog, default: .empty]
	}
}

// MARK: - Commands supplied by the app delegate (window-level actions)

struct NavigatorCommandBarHostActions: Sendable {
	var openNewWindow: @MainActor @Sendable () -> Void = {}
	var openSettings: @MainActor @Sendable () -> Void = {}
	var copyCurrentURL: @MainActor @Sendable () -> Void = {}
	var togglePin: @MainActor @Sendable () -> Void = {}
}

// MARK: - Data source

extension AppViewModel {
	var isCommandBarExperimentEnabled: Bool {
		NavigatorExperiments.shared.isEnabled(.commandBar)
	}

	/// Opens the command bar (⌘K). Falls back to the classic new-tab bar when the experiment is off.
	func presentCommandBar(scope: CommandBarScope = .all) {
		guard isCommandBarExperimentEnabled else {
			presentNewTabActionBar()
			return
		}
		browserActionBarViewModel.presentCommandBar(scope: scope)
	}

	func configureCommandBar() {
		let viewModel = browserActionBarViewModel
		viewModel.dataSource = CommandBarDataSource(
			tabs: { [weak self] in self?.commandBarTabs() ?? [] },
			history: { [weak self] in self?.commandBarHistory() ?? [] },
			commands: { [weak self] in self?.commandBarCommands() ?? [] },
			switchToTab: { [weak self] tabID in self?.switchToTabFromCommandBar(tabID) }
		)
	}

	private func commandBarTabs() -> [CommandBarTab] {
		let selectedTabID = sidebarViewModel.selectedTabID
		let currentSpaceName = spaces.first(where: { $0.id == activeSpaceID }).map(\.name)
		let activeTabs = sidebarViewModel.tabs.map { tab in
			CommandBarTab(
				id: tab.id,
				title: tab.displayTitle,
				url: tab.currentURL,
				isPinned: tab.isPinned,
				isSelected: tab.id == selectedTabID,
				spaceName: currentSpaceName.flatMap { $0.isEmpty ? nil : $0 },
				faviconURL: tab.faviconURL
			)
		}
		let activeIDs = Set(activeTabs.map(\.id))
		let spaceNames = Dictionary(spaces.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
		let otherSpaceTabs = storedTabsForCommandBar()
			.filter { !activeIDs.contains($0.id) && $0.spaceID != activeSpaceID }
			.map { tab in
				CommandBarTab(
					id: tab.id,
					title: tab.title ?? "",
					url: tab.url,
					isPinned: tab.isPinned,
					isSelected: false,
					spaceName: spaceNames[tab.spaceID].flatMap { $0.isEmpty ? "Other space" : $0 },
					faviconURL: tab.faviconURL
				)
			}
		return activeTabs + otherSpaceTabs
	}

	private func commandBarHistory() -> [CommandBarHistoryEntry] {
		var entries = commandBarVisitLog.visits.map { visit in
			CommandBarHistoryEntry(
				url: visit.url,
				title: visit.title,
				lastVisitedAt: visit.lastVisitedAt,
				visitCount: visit.visitCount
			)
		}
		// Back/forward lists of open tabs: no timestamps, but very relevant.
		for tab in sidebarViewModel.tabs {
			for entry in tab.historyEntries.reversed() where NavigatorCommandBarVisitLog.isRecordable(entry.url) {
				entries.append(CommandBarHistoryEntry(url: entry.url, title: entry.title, lastVisitedAt: nil))
			}
		}
		// Imported browser history (Chrome/Arc/Safari), newest first, capped to keep typing fast.
		let imported = importedHistoryForCommandBar()
		entries.append(contentsOf: imported)
		return entries
	}

	private func commandBarCommands() -> [CommandBarCommand] {
		let sidebar = sidebarViewModel
		let host = commandBarHostActions
		var commands: [CommandBarCommand] = [
			CommandBarCommand(id: "newTab", title: "New tab", symbolName: "plus.square", keywords: ["open"], shortcut: "⌘T") { [weak self] in
				self?.presentNewTabActionBar()
			},
			CommandBarCommand(id: "reload", title: "Reload page", symbolName: "arrow.clockwise", keywords: ["refresh"], shortcut: "⌘R") {
				sidebar.reload()
			},
			CommandBarCommand(id: "back", title: "Go back", symbolName: "chevron.backward", keywords: ["previous", "history"], shortcut: "⌘[") {
				sidebar.goBack()
			},
			CommandBarCommand(id: "forward", title: "Go forward", symbolName: "chevron.forward", keywords: ["next", "history"], shortcut: "⌘]") {
				sidebar.goForward()
			},
			CommandBarCommand(id: "closeTab", title: "Close tab", symbolName: "xmark.square", keywords: ["remove"], shortcut: "⌘W") {
				sidebar.closeSelectedTab()
			},
			CommandBarCommand(id: "reopenTab", title: "Reopen closed tab", symbolName: "arrow.uturn.backward.square", keywords: ["undo", "restore"], shortcut: "⇧⌘T") {
				sidebar.reopenLastClosedTab()
			},
			CommandBarCommand(id: "pinTab", title: "Pin or unpin tab", symbolName: "pin", keywords: ["favorite"], shortcut: "⌘P") {
				host.togglePin()
			},
			CommandBarCommand(id: "copyURL", title: "Copy page URL", symbolName: "link", keywords: ["share", "address"], shortcut: "⇧⌘C") {
				host.copyCurrentURL()
			},
			CommandBarCommand(id: "searchTabs", title: "Search open tabs", symbolName: "square.on.square", keywords: ["find", "switch"], shortcut: "@") { [weak self] in
				self?.presentCommandBar(scope: .tabs)
			},
			CommandBarCommand(id: "searchHistory", title: "Search history", symbolName: "clock.arrow.circlepath", keywords: ["find", "visited"], shortcut: "#") { [weak self] in
				self?.presentCommandBar(scope: .history)
			},
			CommandBarCommand(id: "newSpace", title: "New space", symbolName: "rectangle.stack.badge.plus", keywords: ["workspace", "profile"]) { [weak self] in
				self?.createSpace()
			},
			CommandBarCommand(id: "newWindow", title: "New window", symbolName: "macwindow.badge.plus", keywords: ["open"], shortcut: "⌘N") {
				host.openNewWindow()
			},
			CommandBarCommand(id: "settings", title: "Settings", symbolName: "gearshape", keywords: ["preferences", "experiments"], shortcut: "⌘,") {
				host.openSettings()
			},
		]

		for (index, space) in spaces.enumerated() where space.id != activeSpaceID {
			let name = space.name.isEmpty ? "Space \(index + 1)" : space.name
			let spaceID = space.id
			commands.append(
				CommandBarCommand(
					id: "space:\(spaceID)",
					title: "Switch to \(name)",
					symbolName: "rectangle.stack",
					keywords: ["space", "workspace"]
				) { [weak self] in
					self?.switchSpace(to: spaceID)
				}
			)
		}
		return commands
	}

	private func switchToTabFromCommandBar(_ tabID: UUID) {
		if sidebarViewModel.tabs.contains(where: { $0.id == tabID }) {
			sidebarViewModel.selectTab(id: tabID)
			return
		}
		// The tab lives in another space: switch there first, then select it.
		guard let spaceID = storedTabsForCommandBar().first(where: { $0.id == tabID })?.spaceID else { return }
		switchSpace(to: spaceID)
		sidebarViewModel.selectTab(id: tabID)
	}

	/// Called on every tab configuration change; records the selected tab's page in the visit log.
	func recordCommandBarVisitIfNeeded() {
		guard let tabID = sidebarViewModel.selectedTabID,
		      let tab = sidebarViewModel.tabs.first(where: { $0.id == tabID }) else { return }
		let url = tab.currentURL
		let title = tab.pageTitle
		let now = Date()
		if lastRecordedCommandBarURLByTab[tabID] == url {
			if let title {
				$commandBarVisitLog.withLock { $0.updateTitle(title, for: url) }
			}
			return
		}
		lastRecordedCommandBarURLByTab[tabID] = url
		$commandBarVisitLog.withLock { $0.record(url: url, title: title, at: now) }
	}
}

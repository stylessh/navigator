import Foundation
import Observation

/// Where an action can be surfaced. Hosts (toolbar, command bar, page menu) ask the registry
/// for the actions in their placement; the action itself never knows about the UI.
public enum NavigatorActionPlacement: String, Hashable, Sendable, Codable, CaseIterable {
	case toolbar
	case commandBar
	case pageMenu
}

/// Snapshot of the page an action would run against.
public struct NavigatorActionContext: Sendable, Equatable {
	public var url: URL?
	public var title: String?

	public init(url: URL?, title: String?) {
		self.url = url
		self.title = title
	}

	public var host: String? {
		SiteHost.normalized(url?.host)
	}

	public var isWebPage: Bool {
		guard let scheme = url?.scheme?.lowercased() else { return false }
		return scheme == "http" || scheme == "https"
	}
}

/// What an action may do to the browser. Implemented by BrowserView; keeps actions free of AppKit/CEF.
@MainActor
public protocol NavigatorActionPerformer: AnyObject {
	/// Evaluates `script` in the page's main frame and returns its string result (nil on error).
	func evaluateInPage(_ script: String) async -> String?
	func open(_ url: URL, inNewTab: Bool)
	func copyToPasteboard(_ string: String)
	func showToast(_ message: String, systemImage: String?)
	/// Starts the element picker; the picked selector is saved as a zap on the current site.
	func startZapPicker()
	func presentCustomizationPanel()
}

public struct NavigatorAction: Identifiable, Sendable {
	public typealias Perform = @MainActor @Sendable (NavigatorActionContext, any NavigatorActionPerformer) async -> Void

	public let id: String
	public var title: String
	public var subtitle: String?
	public var systemImage: String
	public var keywords: [String]
	public var placements: Set<NavigatorActionPlacement>
	/// Display-only hint such as "⌥⌘Z"; key handling stays with the host.
	public var shortcutHint: String?
	/// Where the action came from, shown in settings ("Built-in", or the user manifest's file name).
	public var source: String
	public var isAvailable: @Sendable (NavigatorActionContext) -> Bool
	public var perform: Perform

	public init(
		id: String,
		title: String,
		subtitle: String? = nil,
		systemImage: String,
		keywords: [String] = [],
		placements: Set<NavigatorActionPlacement>,
		shortcutHint: String? = nil,
		source: String = "Built-in",
		isAvailable: @escaping @Sendable (NavigatorActionContext) -> Bool = { $0.isWebPage },
		perform: @escaping Perform
	) {
		self.id = id
		self.title = title
		self.subtitle = subtitle
		self.systemImage = systemImage
		self.keywords = keywords
		self.placements = placements
		self.shortcutHint = shortcutHint
		self.source = source
		self.isAvailable = isAvailable
		self.perform = perform
	}

	/// Case-insensitive match against title, subtitle and keywords, for command-bar filtering.
	public func matches(query: String) -> Bool {
		let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
		guard needle.isEmpty == false else { return true }
		let haystack = ([title, subtitle ?? ""] + keywords).joined(separator: " ").lowercased()
		return needle.split(separator: " ").allSatisfy { haystack.contains($0) }
	}
}

/// The extension point other features use to add browser actions.
///
/// ```swift
/// registry.register(NavigatorAction(id: "my.action", title: "Do it", systemImage: "bolt",
///                                   placements: [.commandBar]) { context, performer in … })
/// let toolbarItems = registry.actions(for: .toolbar, context: context)
/// ```
@MainActor
@Observable
public final class NavigatorActionRegistry {
	public private(set) var actions: [NavigatorAction] = []
	/// Ids the user hid from the toolbar; the action stays available elsewhere.
	public var hiddenFromToolbar: Set<String> = []

	public init() {}

	public func register(_ action: NavigatorAction) {
		if let index = actions.firstIndex(where: { $0.id == action.id }) {
			actions[index] = action
		}
		else {
			actions.append(action)
		}
	}

	public func register(_ newActions: [NavigatorAction]) {
		newActions.forEach(register)
	}

	public func unregister(id: String) {
		actions.removeAll { $0.id == id }
	}

	/// Replaces every action from `source` (used when a user manifest folder reloads).
	public func replaceActions(fromSource source: String, with newActions: [NavigatorAction]) {
		actions.removeAll { $0.source == source }
		register(newActions)
	}

	public func actions(
		for placement: NavigatorActionPlacement,
		context: NavigatorActionContext,
		matching query: String = ""
	) -> [NavigatorAction] {
		actions.filter { action in
			action.placements.contains(placement)
				&& (placement != .toolbar || hiddenFromToolbar.contains(action.id) == false)
				&& action.isAvailable(context)
				&& action.matches(query: query)
		}
	}

	public func action(id: String) -> NavigatorAction? {
		actions.first { $0.id == id }
	}

	public func perform(
		id: String,
		context: NavigatorActionContext,
		performer: any NavigatorActionPerformer
	) async {
		guard let action = action(id: id), action.isAvailable(context) else { return }
		await action.perform(context, performer)
	}
}

import Foundation

public extension NavigatorExperiment {
	static let commandBar = NavigatorExperiment(
		id: "commandBar",
		title: "Command bar",
		summary: "⌘K opens a Spotlight-style bar that searches open tabs, history and commands. ⌘L and ⌘T use it too. Type @ for tabs, # for history, > for commands, or yt + Tab to search a site.",
		isEnabledByDefault: true
	)
}

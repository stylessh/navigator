import Foundation

public extension NavigatorExperiment {
	static let spatialTabOverview = NavigatorExperiment(
		id: "spatial.tabOverview",
		title: "Tab overview",
		summary: "Pinch in on the trackpad, or press ⌘⇧\\, to zoom out to a grid of every tab in the space.",
		isEnabledByDefault: true
	)

	static let spatialSplitPanes = NavigatorExperiment(
		id: "spatial.splitPanes",
		title: "Split panes",
		summary: "Show up to four tabs side by side. Drag a card onto another in the tab overview, or press ⌘⌥\\.",
		isEnabledByDefault: true
	)
}

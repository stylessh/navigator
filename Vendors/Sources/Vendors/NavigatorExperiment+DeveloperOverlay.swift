public extension NavigatorExperiment {
	static let developerOverlay = NavigatorExperiment(
		id: "developerOverlay",
		title: "Developer overlay",
		summary: "A glass console, network log and element inspector over the page, plus responsive viewport presets. ⌥⌘I toggles it.",
		isEnabledByDefault: true
	)
}

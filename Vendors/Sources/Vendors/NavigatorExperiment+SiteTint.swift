public extension NavigatorExperiment {
	static let siteTint = NavigatorExperiment(
		id: "siteTint",
		title: "Tint chrome to match each site",
		summary: "The toolbar glass and window background pick up the page's theme color, or the color behind the toolbar, and spring between sites.",
		isEnabledByDefault: true
	)
}

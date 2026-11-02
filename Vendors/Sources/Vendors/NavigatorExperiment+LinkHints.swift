public extension NavigatorExperiment {
	static let linkHints = NavigatorExperiment(
		id: "keyboard.linkHints",
		title: "Keyboard link hints",
		summary: "Press F to label every link and button, then type a label to click it. J/K scroll, GG/G jump to top/bottom, H/L go back/forward. Keys are ignored while typing in a field.",
		isEnabledByDefault: true
	)
}

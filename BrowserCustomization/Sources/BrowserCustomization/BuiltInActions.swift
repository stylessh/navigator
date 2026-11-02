import Foundation

public enum BuiltInActions {
	public static let zapElementID = "navigator.zapElement"
	public static let customizeSiteID = "navigator.customizeSite"
	public static let toggleSiteBoostID = "navigator.toggleSiteBoost"
	public static let copyCleanURLID = "navigator.copyCleanURL"

	@MainActor
	public static func make(store: BoostStore) -> [NavigatorAction] {
		var actions = [
			NavigatorAction(
				id: zapElementID,
				title: "Zap Element",
				subtitle: "Pick something on the page to hide it on this site",
				systemImage: "scope",
				keywords: ["hide", "remove", "block", "element", "picker"],
				placements: [.toolbar, .commandBar, .pageMenu],
				shortcutHint: "⌥⌘Z"
			) { _, performer in
				performer.startZapPicker()
			},
			NavigatorAction(
				id: customizeSiteID,
				title: "Customize This Site…",
				subtitle: "Styles, presets and hidden elements",
				systemImage: "paintbrush.pointed",
				keywords: ["boost", "css", "style", "theme", "customize"],
				placements: [.toolbar, .commandBar, .pageMenu],
				shortcutHint: "⌥⌘B"
			) { _, performer in
				performer.presentCustomizationPanel()
			},
			NavigatorAction(
				id: toggleSiteBoostID,
				title: "Toggle Site Boost",
				subtitle: "Turn this site's customizations on or off",
				systemImage: "power",
				keywords: ["boost", "disable", "enable", "original"],
				placements: [.commandBar, .pageMenu],
				isAvailable: { $0.isWebPage }
			) { [weak store] context, performer in
				guard let store, let url = context.url, let boost = store.siteBoost(for: url) else {
					performer.showToast("No customizations for this site yet", systemImage: "paintbrush.pointed")
					return
				}
				var updated = boost
				updated.isEnabled.toggle()
				store.save(updated)
				performer.showToast(
					updated.isEnabled ? "Boost on for \(updated.name)" : "Showing \(updated.name) as-is",
					systemImage: updated.isEnabled ? "paintbrush.pointed.fill" : "paintbrush.pointed"
				)
			},
			NavigatorAction(
				id: copyCleanURLID,
				title: "Copy Clean Link",
				subtitle: "Copies the URL without tracking parameters",
				systemImage: "link.badge.plus",
				keywords: ["copy", "url", "share", "utm", "tracking"],
				placements: [.commandBar, .pageMenu],
				shortcutHint: "⌥⇧⌘C"
			) { context, performer in
				guard let url = context.url else { return }
				let cleaned = CleanURL.clean(url)
				performer.copyToPasteboard(cleaned.absoluteString)
				performer.showToast(
					cleaned == url ? "Link copied" : "Clean link copied",
					systemImage: "link"
				)
			},
		]
		for preset in BoostPreset.all {
			actions.append(presetToggle(preset, store: store))
		}
		return actions
	}

	@MainActor
	private static func presetToggle(_ preset: BoostPreset, store: BoostStore) -> NavigatorAction {
		NavigatorAction(
			id: "navigator.preset.\(preset.id)",
			title: "\(preset.title) on This Site",
			subtitle: "Toggle the \(preset.title.lowercased()) preset",
			systemImage: preset.systemImage,
			keywords: ["boost", "preset", preset.id],
			placements: [.commandBar]
		) { [weak store] context, performer in
			guard let store, let url = context.url else { return }
			let updated = store.updateSiteBoost(for: url) { boost in
				if let index = boost.presets.firstIndex(of: preset.id) {
					boost.presets.remove(at: index)
				}
				else {
					boost.presets.append(preset.id)
					boost.isEnabled = true
				}
			}
			let isOn = updated?.presets.contains(preset.id) == true
			performer.showToast("\(preset.title) \(isOn ? "on" : "off")", systemImage: preset.systemImage)
		}
	}
}

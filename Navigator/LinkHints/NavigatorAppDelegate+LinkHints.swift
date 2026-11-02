import AppKit
import BrowserView
import Vendors

extension NavigatorAppDelegate {
	/// Adds "Show Link Hints" items to the View menu, creating the menu if needed.
	func installLinkHintsMenuItems(in mainMenu: NSMenu) {
		let viewMenu: NSMenu
		if let existing = mainMenu.items.first(where: { $0.submenu?.title == "View" })?.submenu {
			viewMenu = existing
			viewMenu.addItem(.separator())
		}
		else {
			viewMenu = NSMenu(title: "View")
			let item = NSMenuItem(title: "View", action: nil, keyEquivalent: "")
			mainMenu.addItem(item)
			mainMenu.setSubmenu(viewMenu, for: item)
		}

		let showItem = NSMenuItem(
			title: "Show Link Hints",
			action: #selector(showLinkHints(_:)),
			keyEquivalent: "f"
		)
		showItem.keyEquivalentModifierMask = [.command, .option]
		showItem.target = self
		viewMenu.addItem(showItem)

		let newTabItem = NSMenuItem(
			title: "Show Link Hints (Open in New Tab)",
			action: #selector(showLinkHintsInNewTab(_:)),
			keyEquivalent: "f"
		)
		newTabItem.keyEquivalentModifierMask = [.command, .option, .shift]
		newTabItem.target = self
		newTabItem.isAlternate = true
		viewMenu.addItem(newTabItem)
	}

	@objc func showLinkHints(_ sender: Any?) {
		beginLinkHintsInActiveWindow(openInNewTab: false)
	}

	@objc func showLinkHintsInNewTab(_ sender: Any?) {
		beginLinkHintsInActiveWindow(openInNewTab: true)
	}

	func beginLinkHintsInActiveWindow(openInNewTab: Bool) {
		guard let content = browserWindowContent(for: preferredBrowserWindow()) else { return }
		let browserViewController = Self.findBrowserViewController(in: content)
		browserViewController?.beginLinkHints(openInNewTab: openInNewTab)
	}

	private static func findBrowserViewController(in controller: NSViewController) -> BrowserViewController? {
		if let match = controller as? BrowserViewController {
			return match
		}
		for child in controller.children {
			if let match = findBrowserViewController(in: child) {
				return match
			}
		}
		return nil
	}
}

extension NavigatorAppDelegate: NSMenuItemValidation {
	func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
		if menuItem.action == #selector(showLinkHints(_:)) || menuItem.action == #selector(showLinkHintsInNewTab(_:)) {
			return NavigatorExperiments.shared.isEnabled(.linkHints)
		}
		return true
	}
}

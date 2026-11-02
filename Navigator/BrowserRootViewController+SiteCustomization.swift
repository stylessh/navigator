import AppKit
import BrowserView
import Foundation

/// Wires per-site customization (BrowserView/SiteCustomization) into the window chrome:
/// toasts, toolbar accessories from the action registry, and ⌥⌘Z / ⌥⌘B / ⌥⌘C.
extension BrowserRootViewController {
	private static let zapKeyCode: UInt16 = 6 // Z
	private static let customizeKeyCode: UInt16 = 11 // B
	private static let copyCleanLinkKeyCode: UInt16 = 8 // C

	func configureSiteCustomization() {
		let customization = browserViewController.siteCustomization
		let appViewModel = navigatorAppViewModel
		customization.toastHandler = { message, _ in
			appViewModel.presentToast(title: LocalizedStringResource(String.LocalizationValue(message)))
		}
		customization.onActionsChange = { [weak self] in
			self?.refreshSiteCustomizationAccessories()
		}
		refreshSiteCustomizationAccessories()
		installSiteCustomizationKeyMonitor()
	}

	func refreshSiteCustomizationAccessories() {
		let customization = browserViewController.siteCustomization
		setFloatingToolbarAccessories(customization.toolbarItems().map { item in
			BrowserFloatingToolbarAccessory(id: item.id, systemImage: item.systemImage, help: item.help) {
				customization.perform(actionID: item.id)
			}
		})
	}

	private func installSiteCustomizationKeyMonitor() {
		guard siteCustomizationKeyMonitor == nil else { return }
		siteCustomizationKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
			guard let self, event.window === self.view.window else { return event }
			let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
			guard modifiers == [.command, .option] else { return event }
			let customization = self.browserViewController.siteCustomization
			switch event.keyCode {
			case Self.zapKeyCode:
				customization.startZapPicker()
				return nil
			case Self.customizeKeyCode:
				customization.toggleCustomizationPanel()
				return nil
			case Self.copyCleanLinkKeyCode:
				customization.copyCleanLink()
				return nil
			default:
				return event
			}
		}
	}
}

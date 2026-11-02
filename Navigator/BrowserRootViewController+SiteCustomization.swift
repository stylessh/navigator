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
			// Copy plain values out of the event so nothing non-Sendable crosses into the isolated closure.
			let keyCode = event.keyCode
			let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
			let windowNumber = event.windowNumber
			let handled = MainActor.assumeIsolated {
				self?.handleSiteCustomizationKey(keyCode: keyCode, modifiers: modifiers, windowNumber: windowNumber) == true
			}
			return handled ? nil : event
		}
	}

	private func handleSiteCustomizationKey(
		keyCode: UInt16,
		modifiers: NSEvent.ModifierFlags,
		windowNumber: Int
	) -> Bool {
		guard windowNumber == view.window?.windowNumber else { return false }
		guard modifiers == [.command, .option] else { return false }
		let customization = browserViewController.siteCustomization
		switch keyCode {
		case Self.zapKeyCode:
			customization.startZapPicker()
		case Self.customizeKeyCode:
			customization.toggleCustomizationPanel()
		case Self.copyCleanLinkKeyCode:
			customization.copyCleanLink()
		default:
			return false
		}
		return true
	}
}

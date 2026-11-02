import AppKit
import BrowserRuntime
import BrowserView
import DeveloperOverlay
import Foundation
import Observation
import Vendors

/// Connects the `DeveloperOverlay` package to a browser window: feeds it the selected tab's page,
/// wraps the browser view in the viewport stage, and follows the Experiments toggle.
@MainActor
final class NavigatorDeveloperOverlay {
	let controller = DeveloperOverlayController()
	@Dependency(\.browserRuntime) private var browserRuntime

	var model: DeveloperOverlayModel {
		controller.model
	}

	/// Wraps the browser view in a viewport stage and points the overlay at the selected tab.
	/// Add the returned view where the browser view used to go.
	func makeStage(for browserViewController: BrowserViewController) -> NSView {
		let runtime = browserRuntime
		controller.model.bridge = DeveloperOverlayPageBridge(
			currentPageIdentity: { [weak browserViewController] in
				browserViewController?.hostedBrowser.map { AnyHashable($0) }
			},
			evaluate: { [weak browserViewController] script, completion in
				guard let browser = browserViewController?.hostedBrowser else {
					completion(nil, "No page")
					return
				}
				runtime.evaluateJavaScriptInRendererWithResult(browser, script: script, completion: completion)
			}
		)
		return controller.makeStage(wrapping: browserViewController.view)
	}

	/// Lays the overlay over `containerView`. Call before adding the floating toolbar so the toolbar
	/// stays on top.
	func installOverlay(in containerView: NSView) {
		controller.installOverlay(in: containerView)
		observeExperimentToggle()
	}

	/// Toolbar button that opens the panel; empty when the experiment is off.
	func toolbarAccessories() -> [BrowserFloatingToolbarAccessory] {
		guard NavigatorExperiments.shared.isEnabled(.developerOverlay) else { return [] }
		let model = controller.model
		return [
			BrowserFloatingToolbarAccessory(
				id: "developerOverlay",
				systemImage: "hammer",
				help: "Developer overlay (⌥⌘I)"
			) {
				model.togglePanel()
			},
		]
	}

	private func observeExperimentToggle() {
		controller.model.isEnabled = withObservationTracking {
			NavigatorExperiments.shared.isEnabled(.developerOverlay)
		} onChange: { [weak self] in
			Task { @MainActor [weak self] in
				self?.observeExperimentToggle()
			}
		}
	}
}

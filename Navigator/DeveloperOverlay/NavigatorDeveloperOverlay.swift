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
	private let pageChannel = NavigatorDeveloperOverlayPageChannel()
	@Dependency(\.browserRuntime) private var browserRuntime
	private weak var browserViewController: BrowserViewController?

	var model: DeveloperOverlayModel {
		controller.model
	}

	/// Wraps the browser view in a viewport stage and points the overlay at the selected tab.
	/// Add the returned view where the browser view used to go.
	func makeStage(
		for browserViewController: BrowserViewController,
		isPageLoading: @escaping @MainActor () -> Bool
	) -> NSView {
		let runtime = browserRuntime
		self.browserViewController = browserViewController
		controller.model.bridge = DeveloperOverlayPageBridge(
			currentPageIdentity: { [weak browserViewController] in
				browserViewController?.hostedBrowser.map { AnyHashable($0) }
			},
			evaluate: { [weak self, weak browserViewController] script, completion in
				guard let self, let browser = browserViewController?.hostedBrowser else {
					completion(nil, "No page")
					return
				}
				self.pageChannel.evaluate(script, in: browser, runtime: runtime, completion: completion)
			},
			isPageLoading: isPageLoading
		)
		return controller.makeStage(wrapping: browserViewController.view)
	}

	/// Lays the overlay over `containerView`. Call before adding the floating toolbar so the toolbar
	/// stays on top.
	func installOverlay(in containerView: NSView) {
		controller.installOverlay(in: containerView)
		observeExperimentToggle()
		#if DEBUG
			runLaunchScriptIfRequested(containerView: containerView)
		#endif
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

	#if DEBUG
		/// Hands-free smoke test driven by environment variables, so the overlay can be exercised on a
		/// build machine without synthesising input events. Each step logs to stdout with a
		/// `[DeveloperOverlay]` prefix.
		///
		/// - `NAVIGATOR_DEVOVERLAY_LOG=1`: log every poll result.
		/// - `NAVIGATOR_DEVOVERLAY_URL=<url>`: navigate the selected tab there after launch.
		/// - `NAVIGATOR_DEVOVERLAY_HEARTBEAT=1`: set `document.title` to "hb N" every 5 s (no prompt channel).
		/// - `NAVIGATOR_DEVOVERLAY_OPEN=console|network|element`: open the panel on that tab.
		/// - `NAVIGATOR_DEVOVERLAY_EVAL=<js>`: evaluate in the console prompt.
		/// - `NAVIGATOR_DEVOVERLAY_INSPECT=<css selector>`: inspect that element.
		/// - `NAVIGATOR_DEVOVERLAY_VIEWPORT=<preset id>[,<preset id>…]`: apply presets, 2 s apart
		///   (`responsive` returns to fill). Ids: iphone-se, iphone-16, iphone-16-pro-max, ipad-mini,
		///   ipad-pro-11, laptop-1280, desktop-1440.
		private func runLaunchScriptIfRequested(containerView: NSView) {
			let environment = ProcessInfo.processInfo.environment
			let keys = environment.keys.filter { $0.hasPrefix("NAVIGATOR_DEVOVERLAY_") }
			guard keys.isEmpty == false else { return }
			let model = controller.model
			let launch = Date()
			let log: @Sendable (String) -> Void = { message in
				let elapsed = String(format: "+%.1fs", Date().timeIntervalSince(launch))
				FileHandle.standardOutput.write(Data("[DeveloperOverlay] \(elapsed) \(message)\n".utf8))
			}
			// Window visibility changes (occlusion, display sleep) explain stalls in unattended runs.
			Task { @MainActor [weak containerView] in
				var lastVisible: Bool?
				while containerView != nil {
					if let window = containerView?.window {
						let visible = window.occlusionState.contains(.visible)
						if visible != lastVisible {
							log("window occlusion visible=\(visible)")
							lastVisible = visible
						}
					}
					try? await Task.sleep(for: .seconds(1))
				}
			}
			if environment["NAVIGATOR_DEVOVERLAY_LOG"] == "1" {
				model.onPollDiagnostic = log
			}
			// Heartbeat that bypasses the prompt channel: sets document.title every 5 s, so the
			// app's own titleChangeCallback log shows whether the page still runs injected scripts.
			if environment["NAVIGATOR_DEVOVERLAY_HEARTBEAT"] == "1" {
				Task { @MainActor [weak self] in
					var beat = 0
					while let self {
						try? await Task.sleep(for: .seconds(5))
						beat += 1
						if let browser = self.browserViewController?.hostedBrowser {
							log("heartbeat \(beat)")
							self.browserRuntime.evaluateJavaScriptWithResult(browser, script: "document.title = 'hb \(beat)'") { _, _ in }
						}
					}
				}
			}
			log("launch script: \(keys.sorted().joined(separator: ", "))")

			Task { @MainActor [weak containerView] in
				try? await Task.sleep(for: .seconds(4))
				if let url = environment["NAVIGATOR_DEVOVERLAY_URL"] {
					// Native load, like the address bar. A script-driven `location.assign` can be cancelled
					// by the overlay's own polls (they report back through `window.prompt`).
					log("navigate \(url)")
					if let browser = self.browserViewController?.hostedBrowser {
						self.browserRuntime.load(browser, url: url)
					}
					else {
						log("navigate skipped: no browser")
					}
					try? await Task.sleep(for: .seconds(6))
				}
				if let tabName = environment["NAVIGATOR_DEVOVERLAY_OPEN"],
				   let tab = DeveloperOverlayTab(rawValue: tabName) {
					log("open panel \(tab.rawValue)")
					model.togglePanel(tab: tab)
					try? await Task.sleep(for: .seconds(1))
				}
				if let source = environment["NAVIGATOR_DEVOVERLAY_EVAL"] {
					log("eval \(source)")
					model.evaluate(source)
					try? await Task.sleep(for: .seconds(1))
				}
				if let selector = environment["NAVIGATOR_DEVOVERLAY_INSPECT"] {
					log("inspect \(selector)")
					model.inspect(selector: selector)
					for _ in 0..<10 where model.inspectedElement == nil {
						try? await Task.sleep(for: .milliseconds(500))
					}
					log("inspected: \(model.inspectedElement.map { "\($0.selector) \(Int($0.rect.width))x\(Int($0.rect.height))" } ?? "none")")
				}
				if let presets = environment["NAVIGATOR_DEVOVERLAY_VIEWPORT"] {
					for id in presets.split(separator: ",").map(String.init) {
						if id == "responsive" {
							model.setViewport(nil)
						}
						else if let preset = DeveloperViewportPreset.builtIn.first(where: { $0.id == id }) {
							model.viewportMode = .preset(preset, .portrait)
						}
						else {
							log("unknown preset \(id)")
							continue
						}
						try? await Task.sleep(for: .seconds(2))
						let frame = containerView.flatMap { container in
							container.subviews.first { $0 is DeveloperViewportStageView }
								.map { ($0 as? DeveloperViewportStageView)?.contentView.frame ?? .zero }
						} ?? .zero
						log("viewport \(id) -> page frame \(Int(frame.width))x\(Int(frame.height))")
					}
				}
				log("summary console=\(model.consoleEntries.count) network=\(model.networkEntries.count) "
					+ "errors=\(model.errorCount) page=\(model.pageURL) theme=\(model.pageThemeColor ?? "-")")
				for entry in model.consoleEntries.suffix(8) {
					log("console [\(entry.level.rawValue)] \(entry.text.prefix(160))")
				}
				for entry in model.networkEntries.prefix(8) {
					log("network \(entry.kind.rawValue) \(entry.status.map(String.init) ?? "-") \(entry.url.prefix(120))")
				}
			}
		}
	#endif
}

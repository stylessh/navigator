import AppKit
import Carbon.HIToolbox
import Observation
import SwiftUI

/// Glue between the overlay and an AppKit window: hosts the SwiftUI overlay over the browser area,
/// drives the viewport stage from the model, and handles the keyboard shortcuts.
///
/// Shortcuts (only while this controller's window is key):
/// - ⌥⌘I  toggle the panel
/// - ⌥⌘J  console
/// - ⌥⌘C  inspect element
/// - ⌥⌘M  cycle viewport presets
/// - Esc   cancel inspect
@MainActor
public final class DeveloperOverlayController {
	public let model: DeveloperOverlayModel
	private let hitRegions = DeveloperOverlayHitRegions()
	private var hostingView: DeveloperOverlayHostingView?
	private weak var stage: DeveloperViewportStageView?
	private var keyMonitor: Any?

	/// Space kept clear at the bottom of the browser area for the floating toolbar.
	public var bottomInset: CGFloat = 84 {
		didSet { refreshRootView() }
	}

	public init(model: DeveloperOverlayModel = DeveloperOverlayModel()) {
		self.model = model
	}

	// MARK: Installation

	/// Wraps `browserView` in a viewport stage. Add the returned view where the browser view used to go.
	public func makeStage(wrapping browserView: NSView) -> DeveloperViewportStageView {
		let stage = DeveloperViewportStageView(contentView: browserView)
		stage.onCustomSizeChange = { [weak self] size in
			self?.model.setCustomViewportSize(size)
		}
		self.stage = stage
		observeViewportMode()
		return stage
	}

	/// Lays the overlay over `containerView` (full size). Call after the browser/stage is added so the
	/// overlay sits on top; anything added later (toolbar, toasts) stays above it.
	public func installOverlay(in containerView: NSView) {
		let hostingView = DeveloperOverlayHostingView(rootView: AnyView(EmptyView()), hitRegions: hitRegions)
		hostingView.translatesAutoresizingMaskIntoConstraints = false
		containerView.addSubview(hostingView)
		NSLayoutConstraint.activate([
			hostingView.topAnchor.constraint(equalTo: containerView.topAnchor),
			hostingView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
			hostingView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
			hostingView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),
		])
		self.hostingView = hostingView
		refreshRootView()
		startKeyMonitor()
	}

	public func uninstall() {
		stopKeyMonitor()
		hostingView?.removeFromSuperview()
		hostingView = nil
	}

	private func refreshRootView() {
		hostingView?.rootView = AnyView(
			DeveloperOverlayRootView(model: model, hitRegions: hitRegions, bottomInset: bottomInset)
		)
	}

	// MARK: Viewport

	private func observeViewportMode() {
		withObservationTracking {
			_ = model.viewportMode
		} onChange: { [weak self] in
			Task { @MainActor [weak self] in
				guard let self else { return }
				self.stage?.setMode(self.model.viewportMode, animated: true)
				self.observeViewportMode()
			}
		}
	}

	// MARK: Keyboard

	private func startKeyMonitor() {
		guard keyMonitor == nil else { return }
		keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
			let handled = MainActor.assumeIsolated {
				self?.handleKeyDown(event) ?? false
			}
			return handled ? nil : event
		}
	}

	private func stopKeyMonitor() {
		if let keyMonitor {
			NSEvent.removeMonitor(keyMonitor)
		}
		keyMonitor = nil
	}

	/// Returns true when the event was consumed.
	func handleKeyDown(_ event: NSEvent) -> Bool {
		guard model.isEnabled, let window = hostingView?.window, event.window === window else { return false }
		let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

		if event.keyCode == UInt16(kVK_Escape), modifiers.isEmpty, model.isPicking {
			model.stopPicking()
			return true
		}

		guard modifiers == [.command, .option] else { return false }
		switch Int(event.keyCode) {
		case kVK_ANSI_I:
			model.togglePanel()
		case kVK_ANSI_J:
			model.togglePanel(tab: .console)
		case kVK_ANSI_C:
			model.toggleInspect()
		case kVK_ANSI_M:
			model.cycleViewport()
		default:
			return false
		}
		return true
	}
}

/// Full-size host for the overlay that only claims clicks inside the glass shapes; everything
/// else falls through to the page.
@MainActor
final class DeveloperOverlayHostingView: NSHostingView<AnyView> {
	private let hitRegions: DeveloperOverlayHitRegions

	init(rootView: AnyView, hitRegions: DeveloperOverlayHitRegions) {
		self.hitRegions = hitRegions
		super.init(rootView: rootView)
		safeAreaRegions = []
	}

	@available(*, unavailable)
	required init(rootView: AnyView) {
		fatalError("init(rootView:) has not been implemented")
	}

	@available(*, unavailable)
	@MainActor required dynamic init?(coder aDecoder: NSCoder) {
		fatalError("init(coder:) has not been implemented")
	}

	override var mouseDownCanMoveWindow: Bool {
		false
	}

	override func hitTest(_ point: NSPoint) -> NSView? {
		guard let superview else { return nil }
		let local = convert(point, from: superview)
		// SwiftUI reports regions with a top-left origin.
		let swiftUIPoint = isFlipped ? local : CGPoint(x: local.x, y: bounds.height - local.y)
		guard hitRegions.contains(swiftUIPoint) else { return nil }
		return super.hitTest(point)
	}
}

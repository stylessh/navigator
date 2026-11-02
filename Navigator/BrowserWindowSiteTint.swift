import AppKit
import BrowserView
import Observation
import Vendors

/// Cross-fades the window background toward the selected page's tint with a spring.
///
/// The browser is edge to edge, so this mostly shows in the rounded corners, during page loads
/// and rubber-band overscroll, and through the floating toolbar's glass.
@MainActor
final class BrowserWindowSiteTint {
	static let animationKey = "navigator.siteTint.background"

	private weak var view: NSView?
	private let store: BrowserSiteTintStore

	init(view: NSView, store: BrowserSiteTintStore) {
		self.view = view
		self.store = store
		store.isDarkAppearance = Self.isDark(view.effectiveAppearance)
		store.onTintChange = { [weak self] _ in
			self?.apply(animated: true)
		}
		observeExperimentToggle()
	}

	private func observeExperimentToggle() {
		let isEnabled = withObservationTracking {
			NavigatorExperiments.shared.isEnabled(.siteTint)
		} onChange: { [weak self] in
			Task { @MainActor [weak self] in
				self?.observeExperimentToggle()
			}
		}
		store.isEnabled = isEnabled
	}

	func appearanceChanged() {
		guard let view else { return }
		store.isDarkAppearance = Self.isDark(view.effectiveAppearance)
		apply(animated: false)
	}

	/// Background color for the current tint, mixed into the stock window background.
	func resolvedBackgroundColor(base: NSColor) -> NSColor {
		guard let tint = store.currentTint,
		      let baseSRGB = base.usingColorSpace(.sRGB)
		else { return base }
		return baseSRGB.blended(
			withFraction: BrowserSiteTintStyle.windowWashOpacity,
			of: tint.color.nsColor
		) ?? base
	}

	func apply(animated: Bool) {
		guard let view, let layer = view.layer else { return }
		let base = WindowChromeStyler.resolvedBackgroundColor(for: view.effectiveAppearance)
		let target = resolvedBackgroundColor(base: base).cgColor
		let from = layer.presentation()?.backgroundColor ?? layer.backgroundColor

		CATransaction.begin()
		CATransaction.setDisableActions(true)
		layer.backgroundColor = target
		CATransaction.commit()

		guard animated, let from, NSWorkspace.shared.accessibilityDisplayShouldReduceMotion == false else {
			layer.removeAnimation(forKey: Self.animationKey)
			return
		}
		let spring = CASpringAnimation(keyPath: "backgroundColor")
		spring.mass = BrowserSiteTintStyle.springMass
		spring.stiffness = BrowserSiteTintStyle.springStiffness
		spring.damping = BrowserSiteTintStyle.springDamping
		spring.fromValue = from
		spring.toValue = target
		spring.duration = spring.settlingDuration
		layer.add(spring, forKey: Self.animationKey)
	}

	private static func isDark(_ appearance: NSAppearance) -> Bool {
		appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
	}
}

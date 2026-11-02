import AppKit
import QuartzCore
import Vendors

/// Shared spring vocabulary for the spatial layout experiments.
@MainActor
enum SpatialMotion {
	/// Overview zoom in/out: fast but with a hint of overshoot.
	static let zoom = Spring(dampingRatio: 0.84, response: 0.42)
	/// Grid reflow when cards are added, removed or filtered.
	static let reflow = Spring(dampingRatio: 0.9, response: 0.34)
	/// Hover lift and press feedback.
	static let lift = Spring(dampingRatio: 0.7, response: 0.26)
	/// Panes settling into a new split.
	static let split = Spring(dampingRatio: 0.82, response: 0.38)
	/// Drop zone highlight following the cursor.
	static let highlight = Spring(dampingRatio: 1, response: 0.18)

	static var prefersReducedMotion: Bool {
		NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
	}
}

/// Drives an NSView's frame with a Wave spring, retargeting smoothly when a
/// new target arrives mid-flight.
@MainActor
final class SpatialFrameSpring {
	private weak var view: NSView?
	private var animator: SpringAnimator<CGRect>?
	private(set) var target: CGRect

	init(view: NSView) {
		self.view = view
		target = view.frame
	}

	var isAnimating: Bool {
		animator != nil
	}

	func animate(to frame: CGRect, spring: Spring, completion: (@MainActor () -> Void)? = nil) {
		target = frame
		guard let view else { return }
		if SpatialMotion.prefersReducedMotion {
			stop()
			view.frame = frame
			completion?()
			return
		}
		let current = view.frame
		let velocity = animator?.velocity
		stop()
		let animator = SpringAnimator<CGRect>(spring: spring, value: current, target: frame)
		if let velocity {
			animator.velocity = velocity
		}
		animator.valueChanged = { [weak self] value in
			spatialPerformOnMain {
				self?.view?.frame = value
			}
		}
		animator.completion = { [weak self] event in
			spatialPerformOnMain {
				guard let self else { return }
				if case .finished = event {
					self.view?.frame = frame
					self.animator = nil
					completion?()
				}
			}
		}
		self.animator = animator
		animator.start()
	}

	func set(_ frame: CGRect) {
		stop()
		target = frame
		view?.frame = frame
	}

	func stop() {
		animator?.valueChanged = nil
		animator?.completion = nil
		animator?.stop()
		animator = nil
	}
}

/// Spring-driven scalar (alpha, scale, progress).
@MainActor
final class SpatialValueSpring {
	private var animator: SpringAnimator<CGFloat>?
	private(set) var value: CGFloat
	private let apply: @MainActor (CGFloat) -> Void

	init(initial: CGFloat, apply: @escaping @MainActor (CGFloat) -> Void) {
		value = initial
		self.apply = apply
		apply(initial)
	}

	func animate(to target: CGFloat, spring: Spring, completion: (@MainActor () -> Void)? = nil) {
		if SpatialMotion.prefersReducedMotion {
			set(target)
			completion?()
			return
		}
		let velocity = animator?.velocity
		stopAnimator()
		let animator = SpringAnimator<CGFloat>(spring: spring, value: value, target: target)
		if let velocity {
			animator.velocity = velocity
		}
		animator.valueChanged = { [weak self] next in
			spatialPerformOnMain {
				guard let self else { return }
				self.value = next
				self.apply(next)
			}
		}
		animator.completion = { [weak self] event in
			spatialPerformOnMain {
				guard let self else { return }
				if case .finished = event {
					self.value = target
					self.apply(target)
					self.animator = nil
					completion?()
				}
			}
		}
		self.animator = animator
		animator.start()
	}

	func set(_ next: CGFloat) {
		stopAnimator()
		value = next
		apply(next)
	}

	private func stopAnimator() {
		animator?.valueChanged = nil
		animator?.completion = nil
		animator?.stop()
		animator = nil
	}
}

func spatialPerformOnMain(_ action: @escaping @MainActor () -> Void) {
	if Thread.isMainThread {
		MainActor.assumeIsolated {
			action()
		}
	}
	else {
		DispatchQueue.main.sync {
			MainActor.assumeIsolated {
				action()
			}
		}
	}
}

/// Runs `action` on the main actor after `delay` seconds.
@MainActor
func spatialAfter(_ delay: TimeInterval, _ action: @escaping @MainActor () -> Void) {
	guard delay > 0 else {
		action()
		return
	}
	Task { @MainActor in
		try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
		action()
	}
}

extension NSView {
	/// Scales the view's layer around its visual center, regardless of the
	/// layer's anchor point (AppKit leaves layer-backed views anchored at 0,0).
	func spatialApplyScale(_ scale: CGFloat) {
		guard let layer else { return }
		let width = bounds.width
		let height = bounds.height
		var transform = CATransform3DIdentity
		transform = CATransform3DTranslate(transform, width / 2, height / 2, 0)
		transform = CATransform3DScale(transform, scale, scale, 1)
		transform = CATransform3DTranslate(transform, -width / 2, -height / 2, 0)
		CATransaction.begin()
		CATransaction.setDisableActions(true)
		layer.transform = transform
		CATransaction.commit()
	}
}

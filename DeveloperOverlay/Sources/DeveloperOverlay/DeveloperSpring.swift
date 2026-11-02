import AppKit
import Foundation
import QuartzCore

/// A critically-tunable damped spring, parameterised the same way as SwiftUI's
/// `.spring(response:dampingFraction:)`, so AppKit-driven motion (the viewport stage) feels
/// identical to the SwiftUI overlay.
public struct DeveloperSpring: Equatable, Sendable {
	public var response: Double
	public var dampingFraction: Double

	public init(response: Double, dampingFraction: Double) {
		self.response = max(0.01, response)
		self.dampingFraction = max(0, dampingFraction)
	}

	/// Shape changes: viewport resizes, panel open/close.
	public static let morph = DeveloperSpring(response: 0.4, dampingFraction: 0.82)
	/// Small, snappy feedback.
	public static let snappy = DeveloperSpring(response: 0.24, dampingFraction: 0.86)

	var stiffness: Double {
		let omega = 2 * Double.pi / response
		return omega * omega
	}

	var damping: Double {
		4 * Double.pi * dampingFraction / response
	}

	/// Advances one value by `dt` seconds using semi-implicit Euler integration with sub-steps,
	/// which stays stable at display-link rates.
	public func step(
		value: Double,
		velocity: Double,
		target: Double,
		dt: Double
	) -> (value: Double, velocity: Double) {
		var value = value
		var velocity = velocity
		let maxStep = 1.0 / 240.0
		var remaining = max(0, dt)
		while remaining > 0 {
			let h = min(maxStep, remaining)
			let force = -stiffness * (value - target) - damping * velocity
			velocity += force * h
			value += velocity * h
			remaining -= h
		}
		return (value, velocity)
	}

	public static func isSettled(value: Double, velocity: Double, target: Double, tolerance: Double = 0.5) -> Bool {
		abs(value - target) < tolerance && abs(velocity) < tolerance * 4
	}
}

/// Animates a `CGSize` toward a target with `DeveloperSpring`, ticking on the view's display link.
/// Retargeting mid-flight keeps the current velocity, so rapid preset changes chain smoothly.
@MainActor
final class DeveloperSpringSizeAnimator: NSObject {
	private(set) var value: CGSize
	private var velocity: CGSize = .zero
	private(set) var target: CGSize
	private var spring: DeveloperSpring
	private var displayLink: CADisplayLink?
	private var lastTimestamp: CFTimeInterval?
	private var completion: (() -> Void)?
	private weak var hostView: NSView?

	var onChange: ((CGSize) -> Void)?

	init(value: CGSize, spring: DeveloperSpring = .morph) {
		self.value = value
		target = value
		self.spring = spring
	}

	var isAnimating: Bool {
		displayLink != nil
	}

	func jump(to size: CGSize) {
		stop()
		value = size
		target = size
		velocity = .zero
		onChange?(size)
	}

	func animate(to size: CGSize, in view: NSView, spring: DeveloperSpring = .morph, completion: (() -> Void)? = nil) {
		target = size
		self.spring = spring
		self.completion = completion
		hostView = view
		guard NSWorkspace.shared.accessibilityDisplayShouldReduceMotion == false else {
			jump(to: size)
			finish()
			return
		}
		if displayLink == nil {
			let link = view.displayLink(target: self, selector: #selector(tick(_:)))
			link.add(to: .main, forMode: .common)
			displayLink = link
			lastTimestamp = nil
		}
	}

	func stop() {
		displayLink?.invalidate()
		displayLink = nil
		lastTimestamp = nil
	}

	@objc private func tick(_ link: CADisplayLink) {
		let now = link.timestamp
		let dt = lastTimestamp.map { min(1.0 / 30.0, now - $0) } ?? (1.0 / 120.0)
		lastTimestamp = now

		let width = spring.step(value: value.width, velocity: velocity.width, target: target.width, dt: dt)
		let height = spring.step(value: value.height, velocity: velocity.height, target: target.height, dt: dt)
		value = CGSize(width: width.value, height: height.value)
		velocity = CGSize(width: width.velocity, height: height.velocity)

		let settled = DeveloperSpring.isSettled(value: width.value, velocity: width.velocity, target: target.width)
			&& DeveloperSpring.isSettled(value: height.value, velocity: height.velocity, target: target.height)
		if settled {
			value = target
			velocity = .zero
			onChange?(value)
			stop()
			finish()
			return
		}
		onChange?(value)
	}

	private func finish() {
		let completion = completion
		self.completion = nil
		completion?()
	}
}

import CoreGraphics
import Foundation

/// Turns a stream of trackpad magnification deltas into an interactive progress
/// value for zooming out to (or back in from) the tab overview.
///
/// Pinching *in* (negative magnification) zooms out to the overview. Chromium never
/// zooms pages below 100% with a pinch, so this direction is free to claim.
public struct SpatialPinchInterpreter: Equatable, Sendable {
	public enum Direction: Equatable, Sendable {
		/// From the page out to the overview (fingers pinch together).
		case zoomOut
		/// From the overview back into a tab (fingers spread apart).
		case zoomIn
	}

	public enum Outcome: Equatable, Sendable {
		case commit
		case cancel
	}

	public let direction: Direction
	/// Accumulated magnification needed to reach progress 1.
	public var fullTravel: CGFloat
	/// Progress past which a release commits.
	public var commitThreshold: CGFloat
	/// Per-event velocity (magnification/second) that commits regardless of progress.
	public var flickVelocity: CGFloat

	public private(set) var accumulated: CGFloat = 0
	public private(set) var velocity: CGFloat = 0
	private var lastTimestamp: TimeInterval?

	public init(
		direction: Direction,
		fullTravel: CGFloat = 0.45,
		commitThreshold: CGFloat = 0.35,
		flickVelocity: CGFloat = 1.6
	) {
		self.direction = direction
		self.fullTravel = fullTravel
		self.commitThreshold = commitThreshold
		self.flickVelocity = flickVelocity
	}

	/// 0...1, signed so that movement in the gesture's direction is positive.
	public var progress: CGFloat {
		min(max(signedTravel / fullTravel, 0), 1)
	}

	/// Progress that may overshoot slightly, for rubber-banding visuals.
	public var rubberBandedProgress: CGFloat {
		let raw = signedTravel / fullTravel
		if raw <= 1 { return max(raw, 0) }
		let excess = raw - 1
		return 1 + excess / (1 + excess * 4)
	}

	private var signedTravel: CGFloat {
		direction == .zoomOut ? -accumulated : accumulated
	}

	public mutating func update(magnificationDelta: CGFloat, timestamp: TimeInterval) {
		guard magnificationDelta.isFinite else { return }
		accumulated += magnificationDelta
		if let lastTimestamp, timestamp > lastTimestamp {
			let instantaneous = magnificationDelta / CGFloat(timestamp - lastTimestamp)
			velocity = velocity * 0.6 + instantaneous * 0.4
		}
		lastTimestamp = timestamp
	}

	public func outcome() -> Outcome {
		let signedVelocity = direction == .zoomOut ? -velocity : velocity
		if signedVelocity > flickVelocity, progress > 0.05 { return .commit }
		if signedVelocity < -flickVelocity { return .cancel }
		return progress >= commitThreshold ? .commit : .cancel
	}

	/// Whether a pinch that has just begun is going in our direction (used to decide
	/// whether to claim the gesture or let the page have it).
	public static func claims(direction: Direction, firstDelta: CGFloat) -> Bool {
		switch direction {
		case .zoomOut: firstDelta < 0
		case .zoomIn: firstDelta > 0
		}
	}
}

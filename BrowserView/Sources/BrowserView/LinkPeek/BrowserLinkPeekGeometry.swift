import AppKit
import QuartzCore

/// Experiment: Link Peek. Pure layout and gesture math, so it can be unit tested without a window.
enum BrowserLinkPeekGeometry {
	/// The card takes this fraction of the page in both dimensions, so it keeps the page's aspect ratio
	/// and the promote animation can scale it up uniformly to fill the page.
	static let cardFraction: CGFloat = 0.72
	static let minimumCardSize = CGSize(width: 360, height: 280)
	static let headerHeight: CGFloat = 40
	static let contentInset: CGFloat = 8
	static let cardCornerRadius: CGFloat = 26
	static var contentCornerRadius: CGFloat { cardCornerRadius - contentInset }

	/// Upward drag distance, as a fraction of the card height, past which releasing promotes the card.
	static let promoteDistanceFraction: CGFloat = 0.22
	/// Downward drag distance, as a fraction of the card height, past which releasing dismisses the card.
	static let dismissDistanceFraction: CGFloat = 0.28
	/// Flick speed, in points per second, that promotes or dismisses regardless of distance.
	static let flickVelocity: CGFloat = 900

	static func cardFrame(in bounds: CGRect) -> CGRect {
		guard bounds.width > 0, bounds.height > 0 else { return .zero }
		let width = min(bounds.width, max(minimumCardSize.width, (bounds.width * cardFraction).rounded()))
		let height = min(bounds.height, max(minimumCardSize.height, (bounds.height * cardFraction).rounded()))
		return CGRect(
			x: (bounds.midX - width / 2).rounded(),
			y: (bounds.midY - height / 2).rounded(),
			width: width,
			height: height
		)
	}

	/// A transform for a layer whose anchor point is its bottom-left corner (the AppKit default for
	/// layer-backed views): scales around the layer's center, then translates.
	static func transform(scale: CGFloat, translation: CGPoint, size: CGSize) -> CATransform3D {
		let scaleX = scale
		let scaleY = scale
		return transform(scaleX: scaleX, scaleY: scaleY, translation: translation, size: size)
	}

	static func transform(scaleX: CGFloat, scaleY: CGFloat, translation: CGPoint, size: CGSize) -> CATransform3D {
		var matrix = CATransform3DMakeTranslation(
			translation.x + size.width * (1 - scaleX) / 2,
			translation.y + size.height * (1 - scaleY) / 2,
			0
		)
		matrix = CATransform3DScale(matrix, scaleX, scaleY, 1)
		return matrix
	}

	/// The transform that makes `card` appear to occupy `target` (both in the same coordinate space).
	static func transform(from card: CGRect, to target: CGRect) -> CATransform3D {
		guard card.width > 0, card.height > 0 else { return CATransform3DIdentity }
		return transform(
			scaleX: target.width / card.width,
			scaleY: target.height / card.height,
			translation: CGPoint(x: target.midX - card.midX, y: target.midY - card.midY),
			size: card.size
		)
	}

	/// The transform that makes the card appear to grow out of the clicked link.
	static func originTransform(card: CGRect, linkRect: CGRect?) -> CATransform3D {
		guard let linkRect, linkRect.width > 0, linkRect.height > 0 else {
			return transform(scale: 0.86, translation: CGPoint(x: 0, y: -24), size: card.size)
		}
		let scale = min(max(linkRect.width / card.width, 0.12), 0.6)
		return transform(
			scale: scale,
			translation: CGPoint(x: linkRect.midX - card.midX, y: linkRect.midY - card.midY),
			size: card.size
		)
	}

	/// Rubber-band a drag offset so it follows the finger at first and resists the further it goes.
	static func rubberBand(_ offset: CGFloat, limit: CGFloat) -> CGFloat {
		guard limit > 0 else { return 0 }
		let magnitude = abs(offset)
		let damped = (1 - 1 / (magnitude * 0.55 / limit + 1)) * limit
		return offset < 0 ? -damped : damped
	}

	enum ReleaseOutcome: Equatable {
		case promote
		case dismiss
		case settle
	}

	/// - Parameters:
	///   - translation: vertical drag offset in points, positive is up.
	///   - velocity: vertical speed in points per second, positive is up.
	static func releaseOutcome(translation: CGFloat, velocity: CGFloat, cardHeight: CGFloat) -> ReleaseOutcome {
		guard cardHeight > 0 else { return .settle }
		if velocity >= flickVelocity, translation > 0 { return .promote }
		if velocity <= -flickVelocity, translation < 0 { return .dismiss }
		if translation >= cardHeight * promoteDistanceFraction { return .promote }
		if translation <= -cardHeight * dismissDistanceFraction { return .dismiss }
		return .settle
	}

	/// Progress toward the promote threshold, 0...1, used to drive the "release to open" hint.
	static func promoteProgress(translation: CGFloat, cardHeight: CGFloat) -> CGFloat {
		guard cardHeight > 0, translation > 0 else { return 0 }
		return min(1, translation / (cardHeight * promoteDistanceFraction))
	}

	/// Converts a viewport-normalized, top-left-origin rect into view coordinates.
	static func viewRect(for normalized: BrowserLinkPeekHitTest.NormalizedRect, in bounds: CGRect, isFlipped: Bool) -> CGRect {
		let width = CGFloat(normalized.w) * bounds.width
		let height = CGFloat(normalized.h) * bounds.height
		let x = bounds.minX + CGFloat(normalized.x) * bounds.width
		let topY = CGFloat(normalized.y) * bounds.height
		let y = isFlipped ? bounds.minY + topY : bounds.maxY - topY - height
		return CGRect(x: x, y: y, width: width, height: height)
	}

	/// Converts a point in view coordinates into a viewport-normalized, top-left-origin point.
	static func normalizedPoint(for point: CGPoint, in bounds: CGRect, isFlipped: Bool) -> CGPoint? {
		guard bounds.width > 0, bounds.height > 0 else { return nil }
		let fx = (point.x - bounds.minX) / bounds.width
		let fromTop = isFlipped ? point.y - bounds.minY : bounds.maxY - point.y
		let fy = fromTop / bounds.height
		guard (0 ... 1).contains(fx), (0 ... 1).contains(fy) else { return nil }
		return CGPoint(x: fx, y: fy)
	}
}

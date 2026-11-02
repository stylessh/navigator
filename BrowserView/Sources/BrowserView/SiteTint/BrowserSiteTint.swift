import Foundation

/// Where a resolved tint came from, so the UI (and debugging) can tell a brand color from a guess.
public enum BrowserSiteTintSource: String, Equatable, Sendable, Codable {
	case userOverride
	case themeColor
	case bottomEdge
	case topEdge
	case pageBackground
}

/// The tint the browser chrome should wear for the selected page.
public struct BrowserSiteTint: Equatable, Sendable {
	public var color: BrowserSiteTintColor
	public var source: BrowserSiteTintSource

	public init(color: BrowserSiteTintColor, source: BrowserSiteTintSource) {
		self.color = color
		self.source = source
	}
}

/// Per-host user choice, set by the per-site customization layer.
public enum BrowserSiteTintOverride: Equatable, Sendable, Codable {
	/// Always use this color for the host.
	case color(BrowserSiteTintColor)
	/// Never tint the chrome for the host.
	case disabled
}

/// What the page sampler found in the DOM.
public struct BrowserSiteTintSample: Equatable, Sendable {
	/// `<meta name="theme-color">`, honoring its `media` query.
	public var themeColor: BrowserSiteTintColor?
	/// Background of the element under the bottom-center of the viewport (behind the floating toolbar).
	public var bottomEdge: BrowserSiteTintColor?
	/// Background of the element under the top-center of the viewport (the page's header).
	public var topEdge: BrowserSiteTintColor?
	/// Resolved body or root background.
	public var pageBackground: BrowserSiteTintColor?

	public init(
		themeColor: BrowserSiteTintColor? = nil,
		bottomEdge: BrowserSiteTintColor? = nil,
		topEdge: BrowserSiteTintColor? = nil,
		pageBackground: BrowserSiteTintColor? = nil
	) {
		self.themeColor = themeColor
		self.bottomEdge = bottomEdge
		self.topEdge = topEdge
		self.pageBackground = pageBackground
	}

	public static let empty = BrowserSiteTintSample()
}

public enum BrowserSiteTintResolver {
	/// Resolve order: user override, then the site's declared theme-color, then sampled page colors.
	/// Neutral colors (plain white or black) are skipped so ordinary pages keep the stock glass.
	public static func resolve(
		sample: BrowserSiteTintSample?,
		override: BrowserSiteTintOverride?,
		isDarkAppearance: Bool
	) -> BrowserSiteTint? {
		switch override {
		case .disabled:
			return nil
		case let .color(color):
			return .init(color: color.adjusted(forDarkAppearance: isDarkAppearance), source: .userOverride)
		case nil:
			break
		}
		guard let sample else { return nil }
		let candidates: [(BrowserSiteTintColor?, BrowserSiteTintSource)] = [
			(sample.themeColor, .themeColor),
			(sample.bottomEdge, .bottomEdge),
			(sample.topEdge, .topEdge),
			(sample.pageBackground, .pageBackground),
		]
		for case let (color?, source) in candidates where color.isNeutral == false {
			return .init(color: color.adjusted(forDarkAppearance: isDarkAppearance), source: source)
		}
		return nil
	}
}

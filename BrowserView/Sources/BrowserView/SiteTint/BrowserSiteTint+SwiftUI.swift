import AppKit
import SwiftUI

public extension BrowserSiteTintColor {
	var nsColor: NSColor {
		NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
	}

	var swiftUIColor: Color {
		Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha)
	}
}

public enum BrowserSiteTintStyle {
	/// Opacity of the tint handed to Liquid Glass (macOS 26), which already mutes and
	/// vibrancy-adapts it, so it needs to be fairly strong to read at all.
	public static let glassTintOpacity: Double = 0.6
	/// Opacity of the color wash laid over the blur material on macOS 15.
	public static let glassWashOpacity: Double = 0.4
	/// Opacity of the window background tint behind web content.
	public static let windowWashOpacity: Double = 0.55
	/// One spring for every tint transition so toolbar and window move together. Critically
	/// damped: an underdamped spring on a color overshoots past the target hue and back.
	public static let animation: Animation = .spring(response: 0.55, dampingFraction: 1)
	/// The same spring for Core Animation: stiffness (2π / response)², damping 4π·ζ / response.
	public static let springMass: CGFloat = 1
	public static let springStiffness: CGFloat = 130.5
	public static let springDamping: CGFloat = 22.85
}

private struct BrowserSiteTintEnvironmentKey: EnvironmentKey {
	static let defaultValue: BrowserSiteTint? = nil
}

public extension EnvironmentValues {
	/// The selected page's tint, or nil for stock chrome.
	var browserSiteTint: BrowserSiteTint? {
		get { self[BrowserSiteTintEnvironmentKey.self] }
		set { self[BrowserSiteTintEnvironmentKey.self] = newValue }
	}
}

public extension View {
	/// Lays a spring-animated color wash from `\.browserSiteTint` inside `shape`.
	/// Put it directly on top of the glass background so the glass highlights stay visible.
	func siteTintWash<S: Shape>(in shape: S, opacity: Double = BrowserSiteTintStyle.glassWashOpacity) -> some View {
		modifier(BrowserSiteTintWashModifier(shape: shape, opacity: opacity))
	}

	/// Feeds the store's current tint into the environment for every chrome view below.
	func browserSiteTint(from store: BrowserSiteTintStore) -> some View {
		modifier(BrowserSiteTintEnvironmentModifier(store: store))
	}
}

private struct BrowserSiteTintEnvironmentModifier: ViewModifier {
	let store: BrowserSiteTintStore

	func body(content: Content) -> some View {
		content.environment(\.browserSiteTint, store.currentTint)
	}
}

private struct BrowserSiteTintWashModifier<S: Shape>: ViewModifier {
	@Environment(\.browserSiteTint) private var tint
	let shape: S
	let opacity: Double

	func body(content: Content) -> some View {
		content
			.background {
				shape
					.fill(tint?.color.swiftUIColor ?? .clear)
					.opacity(tint == nil ? 0 : opacity)
					.allowsHitTesting(false)
			}
			.animation(BrowserSiteTintStyle.animation, value: tint)
	}
}

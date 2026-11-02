import SwiftUI

/// Liquid Glass on macOS 26+, falling back to a blurred material on macOS 15.
public struct NavigatorGlass<S: InsettableShape>: ViewModifier {
	let shape: S
	let tint: Color?
	let isInteractive: Bool

	public func body(content: Content) -> some View {
		if #available(macOS 26.0, *) {
			content.glassEffect(glass, in: shape)
		}
		else {
			content
				.background(.ultraThinMaterial, in: shape)
				.background(tint.map { $0.opacity(0.12) } ?? .clear, in: shape)
				.overlay(shape.strokeBorder(.white.opacity(0.14), lineWidth: 0.5))
				.shadow(color: .black.opacity(0.18), radius: 18, y: 8)
		}
	}

	@available(macOS 26.0, *)
	private var glass: Glass {
		var glass = Glass.regular
		if let tint {
			glass = glass.tint(tint.opacity(0.35))
		}
		if isInteractive {
			glass = glass.interactive()
		}
		return glass
	}
}

public extension View {
	func navigatorGlass(
		cornerRadius: CGFloat = 22,
		tint: Color? = nil,
		interactive: Bool = false
	) -> some View {
		modifier(NavigatorGlass(
			shape: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous),
			tint: tint,
			isInteractive: interactive
		))
	}

	func navigatorGlassCapsule(tint: Color? = nil, interactive: Bool = true) -> some View {
		modifier(NavigatorGlass(shape: Capsule(), tint: tint, isInteractive: interactive))
	}
}

/// The springs every customization surface uses, so motion feels like one system. Same values
/// as Navigator's motion tokens (docs/browser/motion.md).
public extension Animation {
	/// Token: snappy. Hover, selection and small state changes.
	static let navigatorSnappy = Animation.spring(response: 0.24, dampingFraction: 0.86)
	/// Token: morph. Panels appearing and sections opening.
	static let navigatorBouncy = Animation.spring(response: 0.4, dampingFraction: 0.82)
	/// Token: press. Button press-down.
	static let navigatorPress = Animation.spring(response: 0.18, dampingFraction: 0.64)
	/// Token: exit. Dismissals: quicker than the entrance and no bounce.
	static let navigatorExit = Animation.spring(response: 0.22, dampingFraction: 1)
}

/// Presses scale down with a spring, like a physical button.
public struct SpringPressStyle: ButtonStyle {
	public init() {}

	public func makeBody(configuration: Configuration) -> some View {
		configuration.label
			.scaleEffect(configuration.isPressed ? 0.94 : 1)
			.animation(.navigatorPress, value: configuration.isPressed)
	}
}

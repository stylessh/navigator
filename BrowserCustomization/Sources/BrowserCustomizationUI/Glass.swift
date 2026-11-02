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

/// The spring every customization surface uses, so motion feels like one system.
public extension Animation {
	static let navigatorSnappy = Animation.spring(response: 0.32, dampingFraction: 0.78)
	static let navigatorBouncy = Animation.spring(response: 0.42, dampingFraction: 0.62)
}

/// Presses scale down with a spring, like a physical button.
public struct SpringPressStyle: ButtonStyle {
	public init() {}

	public func makeBody(configuration: Configuration) -> some View {
		configuration.label
			.scaleEffect(configuration.isPressed ? 0.94 : 1)
			.animation(.navigatorBouncy, value: configuration.isPressed)
	}
}

import SwiftUI

/// Liquid Glass for the developer overlay.
///
/// macOS 26+ uses SwiftUI's native `glassEffect`, so the HUD refracts the page and neighbouring
/// shapes morph into each other. macOS 15 falls back to a blur material with a hairline stroke and
/// soft shadow, keeping layout and motion identical. Mirrors `floatingGlass` in the app target so
/// the overlay and the floating toolbar read as one family.
public extension View {
	@ViewBuilder
	func developerGlass(
		in shape: some Shape = Capsule(),
		tint: Color? = nil,
		interactive: Bool = false
	) -> some View {
		if #available(macOS 26.0, *) {
			glassEffect(DeveloperGlassResolver.glass(tint: tint, interactive: interactive), in: shape)
		}
		else {
			background {
				ZStack {
					shape.fill(.regularMaterial)
					if let tint {
						shape.fill(tint.opacity(0.18))
					}
				}
				.shadow(color: .black.opacity(0.2), radius: 18, y: 8)
			}
			.overlay {
				shape.stroke(Color.primary.opacity(0.09), lineWidth: 0.5)
			}
		}
	}

	@ViewBuilder
	func developerGlassID(_ id: some Hashable & Sendable, in namespace: Namespace.ID) -> some View {
		if #available(macOS 26.0, *) {
			glassEffectID(id, in: namespace)
		}
		else {
			self
		}
	}
}

@available(macOS 26.0, *)
private enum DeveloperGlassResolver {
	static func glass(tint: Color?, interactive: Bool) -> Glass {
		Glass.regular.tint(tint).interactive(interactive)
	}
}

struct DeveloperGlassContainer<Content: View>: View {
	var spacing: CGFloat
	@ViewBuilder var content: Content

	var body: some View {
		if #available(macOS 26.0, *) {
			GlassEffectContainer(spacing: spacing) {
				content
			}
		}
		else {
			content
		}
	}
}

/// Spring curves shared by every overlay interaction (same values as the floating toolbar).
@MainActor
public enum DeveloperMotion {
	public static let morph = Animation.spring(response: 0.42, dampingFraction: 0.78)
	public static let snappy = Animation.spring(response: 0.26, dampingFraction: 0.82)
	public static let press = Animation.spring(response: 0.2, dampingFraction: 0.58)
	public static let rows = Animation.spring(response: 0.34, dampingFraction: 0.86)
}

// MARK: - Hit regions

/// Rects (in the overlay's coordinate space, top-left origin) where the overlay should receive
/// clicks. Everywhere else, clicks fall through to the page underneath.
@MainActor
final class DeveloperOverlayHitRegions {
	private(set) var rects: [String: CGRect] = [:]

	func set(_ rect: CGRect?, for id: String) {
		rects[id] = rect
	}

	func contains(_ point: CGPoint) -> Bool {
		rects.values.contains { $0.insetBy(dx: -2, dy: -2).contains(point) }
	}
}

extension EnvironmentValues {
	@Entry var developerHitRegions: DeveloperOverlayHitRegions?
}

private struct DeveloperHitRegionModifier: ViewModifier {
	let id: String
	@Environment(\.developerHitRegions) private var regions

	func body(content: Content) -> some View {
		content
			.onGeometryChange(for: CGRect.self) { proxy in
				proxy.frame(in: .named(DeveloperOverlayRootView.coordinateSpaceName))
			} action: { frame in
				regions?.set(frame, for: id)
			}
			.onDisappear {
				regions?.set(nil, for: id)
			}
	}
}

extension View {
	/// Marks this view as clickable; the rest of the overlay lets events reach the page.
	func developerHitRegion(_ id: String) -> some View {
		modifier(DeveloperHitRegionModifier(id: id))
	}
}

// MARK: - Buttons

/// Circular glass-friendly icon button with a springy press.
struct DeveloperIconButton: View {
	let systemImage: String
	let help: String
	var isActive = false
	var tint: Color = .accentColor
	var size: CGFloat = 30
	let action: () -> Void

	@State private var isHovering = false

	init(
		systemImage: String,
		help: String,
		isActive: Bool = false,
		tint: Color = .accentColor,
		size: CGFloat = 30,
		action: @escaping () -> Void
	) {
		self.systemImage = systemImage
		self.help = help
		self.isActive = isActive
		self.tint = tint
		self.size = size
		self.action = action
	}

	var body: some View {
		Button(action: action) {
			Image(systemName: systemImage)
				.font(.system(size: size * 0.43, weight: .semibold))
				.symbolRenderingMode(.hierarchical)
				.foregroundStyle(isActive ? Color.white : Color.primary)
				.frame(width: size, height: size)
				.background {
					Circle()
						.fill(isActive ? AnyShapeStyle(tint) : AnyShapeStyle(Color.primary.opacity(isHovering ? 0.1 : 0)))
				}
				.contentShape(Circle())
		}
		.buttonStyle(DeveloperPressStyle())
		.help(help)
		.onHover { hovering in
			withAnimation(DeveloperMotion.snappy) { isHovering = hovering }
		}
		.animation(DeveloperMotion.snappy, value: isActive)
	}
}

struct DeveloperPressStyle: ButtonStyle {
	func makeBody(configuration: Configuration) -> some View {
		configuration.label
			.scaleEffect(configuration.isPressed ? 0.88 : 1)
			.animation(DeveloperMotion.press, value: configuration.isPressed)
	}
}

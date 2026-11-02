import AppKit
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

	/// Insertion/removal for glass inside a `DeveloperGlassContainer`. On macOS 26 the glass
	/// morphs out of its neighbours (`glassEffectTransition(.matchedGeometry)`) with a plain
	/// fade for the content; a scale transition on top fought that morph and read as a pinch.
	/// macOS 15 keeps `fallback`.
	@ViewBuilder
	func developerGlassTransition(fallback: AnyTransition) -> some View {
		if #available(macOS 26.0, *) {
			glassEffectTransition(.matchedGeometry)
				.transition(.opacity)
		}
		else {
			transition(fallback)
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

/// Spring curves shared by every overlay interaction. Navigator's motion tokens
/// (docs/browser/motion.md), the same values as the floating toolbar.
@MainActor
public enum DeveloperMotion {
	/// Token: morph. Panels, shelves and the HUD changing shape.
	public static let morph = Animation.spring(response: 0.4, dampingFraction: 0.82)
	/// Token: snappy. Hover, selection, tab switches.
	public static let snappy = Animation.spring(response: 0.24, dampingFraction: 0.86)
	/// Token: press. Button press-down.
	public static let press = Animation.spring(response: 0.18, dampingFraction: 0.64)
	/// Token: reflow. Log and network rows streaming in.
	public static let rows = Animation.spring(response: 0.32, dampingFraction: 0.9)
	/// Token: tint. Page theme color in the glass; critically damped so colors don't overshoot.
	public static let tint = Animation.spring(response: 0.55, dampingFraction: 1)
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
	/// Copies text and shows a confirmation: `(text, label)`.
	@Entry var developerCopy: DeveloperCopyAction = DeveloperCopyAction { text, _ in
		NSPasteboard.general.clearContents()
		NSPasteboard.general.setString(text, forType: .string)
	}
}

struct DeveloperCopyAction: Sendable {
	let perform: @MainActor @Sendable (String, String) -> Void

	@MainActor
	func callAsFunction(_ text: String, label: String) {
		perform(text, label)
	}
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

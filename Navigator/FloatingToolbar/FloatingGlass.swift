import SwiftUI

/// Liquid Glass helpers for the floating chrome.
///
/// On macOS 26+ these map to SwiftUI's native `glassEffect` APIs, so shapes refract the page
/// underneath and neighbouring glass morphs together. On macOS 15 they fall back to a blur
/// material with a hairline stroke and soft shadow so the layout and motion stay identical.
extension View {
	/// Renders `self` on a glass surface clipped to `shape`.
	@ViewBuilder
	func floatingGlass(
		in shape: some Shape = Capsule(),
		tint: Color? = nil,
		interactive: Bool = false
	) -> some View {
		if #available(macOS 26.0, *) {
			glassEffect(FloatingGlassResolver.glass(tint: tint, interactive: interactive), in: shape)
		}
		else {
			background {
				ZStack {
					shape.fill(.regularMaterial)
					if let tint {
						shape.fill(tint.opacity(0.18))
					}
				}
				.shadow(color: .black.opacity(0.18), radius: 14, y: 6)
			}
			.overlay {
				shape.stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
			}
		}
	}

	/// Gives a glass shape a stable identity so it morphs (instead of cross-fading) when it
	/// appears, disappears, or changes size inside a `FloatingGlassContainer`.
	@ViewBuilder
	func floatingGlassID(_ id: some Hashable & Sendable, in namespace: Namespace.ID) -> some View {
		if #available(macOS 26.0, *) {
			glassEffectID(id, in: namespace)
		}
		else {
			self
		}
	}
}

@available(macOS 26.0, *)
private enum FloatingGlassResolver {
	static func glass(tint: Color?, interactive: Bool) -> Glass {
		Glass.regular.tint(tint).interactive(interactive)
	}
}

/// Groups glass shapes so they blend into each other when they get close (macOS 26+).
struct FloatingGlassContainer<Content: View>: View {
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

/// Shared spring curves so every piece of floating chrome moves with the same physics.
@MainActor
enum FloatingMotion {
	/// Shape morphs: expand/collapse, shelves appearing.
	static let morph = Animation.spring(response: 0.42, dampingFraction: 0.78)
	/// Small, snappy feedback: hover highlights, selection changes.
	static let snappy = Animation.spring(response: 0.26, dampingFraction: 0.82)
	/// Press-down feedback on buttons, slightly bouncy.
	static let press = Animation.spring(response: 0.2, dampingFraction: 0.58)
}

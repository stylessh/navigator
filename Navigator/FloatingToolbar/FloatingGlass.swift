import BrowserView
import SwiftUI

/// Liquid Glass helpers for the floating chrome.
///
/// On macOS 26+ these map to SwiftUI's native `glassEffect` APIs, so shapes refract the page
/// underneath and neighbouring glass morphs together. On macOS 15 they fall back to a blur
/// material with a hairline stroke and soft shadow so the layout and motion stay identical.
extension View {
	/// Renders `self` on a glass surface clipped to `shape`.
	///
	/// When `tint` is nil the glass picks up the selected page's color from `\.browserSiteTint`
	/// (the "Tint chrome to match each site" experiment), cross-fading with a spring.
	func floatingGlass(
		in shape: some Shape = Capsule(),
		tint: Color? = nil,
		interactive: Bool = false
	) -> some View {
		modifier(FloatingGlassModifier(shape: shape, tint: tint, interactive: interactive))
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

private struct FloatingGlassModifier<S: Shape>: ViewModifier {
	@Environment(\.browserSiteTint) private var siteTint
	let shape: S
	let tint: Color?
	let interactive: Bool

	private var resolvedTint: Color? {
		if let tint { return tint }
		let opacity: Double
		if #available(macOS 26.0, *) {
			opacity = BrowserSiteTintStyle.glassTintOpacity
		}
		else {
			opacity = BrowserSiteTintStyle.glassWashOpacity
		}
		return siteTint.map { $0.color.swiftUIColor.opacity(opacity) }
	}

	func body(content: Content) -> some View {
		glass(content, tint: resolvedTint)
			.animation(BrowserSiteTintStyle.animation, value: siteTint)
	}

	@ViewBuilder
	private func glass(_ content: Content, tint: Color?) -> some View {
		if #available(macOS 26.0, *) {
			content.glassEffect(FloatingGlassResolver.glass(tint: tint, interactive: interactive), in: shape)
		}
		else {
			content
				.background {
					ZStack {
						shape.fill(.regularMaterial)
						// Explicit tints keep the original light wash; the site tint is pre-faded.
						shape.fill(self.tint.map { $0.opacity(0.18) } ?? tint ?? .clear)
					}
					.shadow(color: .black.opacity(0.18), radius: 14, y: 6)
				}
				.overlay {
					shape.stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
				}
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

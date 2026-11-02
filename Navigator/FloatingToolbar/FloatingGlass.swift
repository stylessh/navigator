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

	/// Insertion/removal for a glass shape inside a `FloatingGlassContainer`.
	///
	/// On macOS 26 the glass morphs out of (and back into) its neighbours with
	/// `glassEffectTransition(.matchedGeometry)`, with a plain fade for the content. Stacking a
	/// scale transition on top of that, as before, fought the morph: the shape interpolated its
	/// frame while the scale shrank it again, which read as a pinch. macOS 15 has no glass
	/// morph, so it keeps `fallback`.
	@ViewBuilder
	func floatingGlassTransition(fallback: AnyTransition) -> some View {
		if #available(macOS 26.0, *) {
			glassEffectTransition(.matchedGeometry)
				.transition(.opacity)
		}
		else {
			transition(fallback)
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

private struct FloatingGlassModifier<S: Shape>: ViewModifier {
	@Environment(\.browserSiteTint) private var siteTint
	/// What the glass actually shows; trails `siteTint` with the tint spring.
	@State private var shownTint: BrowserSiteTint?
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
		return shownTint.map { $0.color.swiftUIColor.opacity(opacity) }
	}

	func body(content: Content) -> some View {
		glass(content, tint: resolvedTint)
			// The tint springs in its own transaction. A plain `.animation(_:value: siteTint)`
			// here also animated every other change that landed in the same update (address
			// text, pill width, an expand/collapse) with the slow tint curve, so a tint arriving
			// mid-morph made the toolbar change speed halfway through.
			.onChange(of: siteTint, initial: true) { oldValue, newValue in
				guard oldValue != newValue else {
					shownTint = newValue
					return
				}
				withAnimation(FloatingMotion.tint) {
					shownTint = newValue
				}
			}
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
/// The values are Navigator's motion tokens (docs/browser/motion.md); every experiment's
/// motion enum uses the same numbers.
@MainActor
enum FloatingMotion {
	/// Shape morphs: expand/collapse, shelves and panels appearing.
	static let morph = Animation.spring(response: 0.4, dampingFraction: 0.82)
	/// Layout that follows content: lists and rows being added or removed.
	static let reflow = Animation.spring(response: 0.32, dampingFraction: 0.9)
	/// Small, snappy feedback: hover highlights, selection changes.
	static let snappy = Animation.spring(response: 0.24, dampingFraction: 0.86)
	/// Press-down feedback on buttons, slightly bouncy.
	static let press = Animation.spring(response: 0.18, dampingFraction: 0.64)
	/// Color changes (site tint). Critically damped so colors never overshoot.
	static let tint = BrowserSiteTintStyle.animation
}

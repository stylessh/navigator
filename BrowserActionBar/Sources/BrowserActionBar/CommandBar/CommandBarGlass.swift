import SwiftUI

/// Liquid Glass on macOS 26+, a blur material with a hairline stroke on macOS 15.
/// Mirrors `floatingGlass` in the app target so the command bar matches the toolbar.
extension View {
	@ViewBuilder
	func commandBarGlass(cornerRadius: CGFloat, tint: Color? = nil) -> some View {
		let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
		if #available(macOS 26.0, *) {
			glassEffect(CommandBarGlassResolver.glass(tint: tint), in: shape)
		}
		else {
			background {
				ZStack {
					shape.fill(.regularMaterial)
					if let tint {
						shape.fill(tint.opacity(0.14))
					}
				}
			}
			.overlay {
				shape.strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5)
			}
		}
	}

	@ViewBuilder
	func commandBarGlassID(_ id: some Hashable & Sendable, in namespace: Namespace.ID) -> some View {
		if #available(macOS 26.0, *) {
			glassEffectID(id, in: namespace)
		}
		else {
			self
		}
	}
}

@available(macOS 26.0, *)
private enum CommandBarGlassResolver {
	static func glass(tint: Color?) -> Glass {
		Glass.regular.tint(tint)
	}
}

/// Groups glass so the scope chip and the field melt together (macOS 26+).
struct CommandBarGlassContainer<Content: View>: View {
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

/// One set of springs for the whole bar.
@MainActor
enum CommandBarMotion {
	/// Panel appearing out of the toolbar pill.
	static let present = Animation.spring(response: 0.42, dampingFraction: 0.74)
	/// Results list growing and shrinking.
	static let resize = Animation.spring(response: 0.34, dampingFraction: 0.86)
	/// Highlight sliding between rows.
	static let highlight = Animation.spring(response: 0.24, dampingFraction: 0.84)
	/// Scope chip popping in and out.
	static let chip = Animation.spring(response: 0.3, dampingFraction: 0.62)
}

enum CommandBarLayout {
	static let fieldHeight: CGFloat = 54
	static let rowHeight: CGFloat = 42
	static let headerHeight: CGFloat = 26
	static let listVerticalPadding: CGFloat = 6
	static let maxResultsHeight: CGFloat = 392
	static let cornerRadius: CGFloat = 22
	/// Transparent margin around the card inside the panel window, so the shadow and the
	/// spring overshoot are never clipped by the window edge.
	static let outerPadding: CGFloat = 32

	static func resultsHeight(for sections: [CommandBarSection]) -> CGFloat {
		guard !sections.isEmpty else { return 0 }
		let rows = sections.reduce(0) { $0 + $1.items.count }
		let headers = sections.filter { $0.title != nil }.count
		return CGFloat(rows) * rowHeight + CGFloat(headers) * headerHeight + listVerticalPadding * 2
	}
}

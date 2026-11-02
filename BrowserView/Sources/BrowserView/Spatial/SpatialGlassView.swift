import AppKit

/// Liquid Glass on macOS 26+, falling back to a blur material on older systems.
@MainActor
final class SpatialGlassView: NSView {
	enum Style {
		/// Panels and capsules (header, chips).
		case regular
		/// Full-window backdrop behind the overview grid.
		case backdrop
	}

	let contentView = NSView()
	private let style: Style
	private var effectView: NSView?

	var cornerRadius: CGFloat = 0 {
		didSet { applyCornerRadius() }
	}

	init(style: Style, cornerRadius: CGFloat = 0) {
		self.style = style
		self.cornerRadius = cornerRadius
		super.init(frame: .zero)
		wantsLayer = true
		build()
	}

	@available(*, unavailable)
	required init?(coder: NSCoder) {
		fatalError("init(coder:) has not been implemented")
	}

	private func build() {
		let effect: NSView
		if #available(macOS 26.0, *) {
			let glass = NSGlassEffectView()
			// The backdrop uses regular glass with a dark tint: clear glass picks up the luminance
			// of whatever page is beneath and washed out over light pages.
			glass.style = .regular
			if style == .backdrop {
				glass.tintColor = NSColor.black.withAlphaComponent(0.35)
			}
			glass.cornerRadius = cornerRadius
			glass.contentView = contentView
			effect = glass
		}
		else {
			let blur = NSVisualEffectView()
			blur.material = style == .backdrop ? .fullScreenUI : .popover
			blur.blendingMode = .withinWindow
			blur.state = .active
			blur.wantsLayer = true
			blur.addSubview(contentView)
			contentView.translatesAutoresizingMaskIntoConstraints = false
			NSLayoutConstraint.activate([
				contentView.topAnchor.constraint(equalTo: blur.topAnchor),
				contentView.leadingAnchor.constraint(equalTo: blur.leadingAnchor),
				contentView.trailingAnchor.constraint(equalTo: blur.trailingAnchor),
				contentView.bottomAnchor.constraint(equalTo: blur.bottomAnchor),
			])
			effect = blur
		}
		effect.translatesAutoresizingMaskIntoConstraints = false
		addSubview(effect)
		NSLayoutConstraint.activate([
			effect.topAnchor.constraint(equalTo: topAnchor),
			effect.leadingAnchor.constraint(equalTo: leadingAnchor),
			effect.trailingAnchor.constraint(equalTo: trailingAnchor),
			effect.bottomAnchor.constraint(equalTo: bottomAnchor),
		])
		effectView = effect
		applyCornerRadius()
	}

	private func applyCornerRadius() {
		if #available(macOS 26.0, *), let glass = effectView as? NSGlassEffectView {
			glass.cornerRadius = cornerRadius
			return
		}
		effectView?.wantsLayer = true
		effectView?.layer?.cornerRadius = cornerRadius
		effectView?.layer?.cornerCurve = .continuous
		effectView?.layer?.masksToBounds = cornerRadius > 0
	}
}

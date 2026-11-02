import SwiftUI

/// The whole overlay: the HUD capsule (top trailing), the viewport shelf, and the panel.
/// It's laid over the browser area at full size; only the glass shapes take clicks.
struct DeveloperOverlayRootView: View {
	nonisolated static let coordinateSpaceName = "developerOverlay"

	@Bindable var model: DeveloperOverlayModel
	let hitRegions: DeveloperOverlayHitRegions
	/// Space reserved at the bottom for the floating toolbar so the panel never covers it.
	var bottomInset: CGFloat = 84
	var topInset: CGFloat = 12

	@Namespace private var glassNamespace
	@State private var isViewportShelfPresented = false

	init(model: DeveloperOverlayModel, hitRegions: DeveloperOverlayHitRegions, bottomInset: CGFloat = 84) {
		self.model = model
		self.hitRegions = hitRegions
		self.bottomInset = bottomInset
	}

	var body: some View {
		ZStack(alignment: .topTrailing) {
			Color.clear

			if model.isEnabled {
				DeveloperGlassContainer(spacing: 14) {
					VStack(alignment: .trailing, spacing: 10) {
						hud
							.developerHitRegion("hud")

						if isViewportShelfPresented {
							DeveloperViewportShelf(model: model) {
								withAnimation(DeveloperMotion.morph) { isViewportShelfPresented = false }
							}
							.developerGlass(in: RoundedRectangle(cornerRadius: 20, style: .continuous))
							.developerGlassID("shelf", in: glassNamespace)
							.developerHitRegion("shelf")
							.transition(.scale(scale: 0.85, anchor: .topTrailing).combined(with: .opacity))
						}

						if model.isPanelPresented {
							DeveloperPanelView(model: model)
								.frame(width: 420)
								.frame(maxHeight: .infinity)
								.developerGlass(in: RoundedRectangle(cornerRadius: 22, style: .continuous))
								.developerGlassID("panel", in: glassNamespace)
								.developerHitRegion("panel")
								.transition(
									.asymmetric(
										insertion: .scale(scale: 0.92, anchor: .topTrailing)
											.combined(with: .opacity)
											.combined(with: .offset(x: 24)),
										removal: .scale(scale: 0.95, anchor: .topTrailing).combined(with: .opacity)
									)
								)
						}
					}
				}
				.padding(.top, topInset)
				.padding(.trailing, 12)
				.padding(.bottom, bottomInset)
				.transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .topTrailing)))
			}

			if model.isEnabled, model.viewportMode.preset != nil {
				DeveloperViewportBadge(model: model)
					.developerGlass(in: Capsule())
					.developerHitRegion("viewportBadge")
					.frame(maxWidth: .infinity, alignment: .center)
					.padding(.top, topInset)
					.transition(.move(edge: .top).combined(with: .opacity))
			}
		}
		.coordinateSpace(name: Self.coordinateSpaceName)
		.environment(\.developerHitRegions, hitRegions)
		.animation(DeveloperMotion.morph, value: model.isPanelPresented)
		.animation(DeveloperMotion.morph, value: model.isEnabled)
		.animation(DeveloperMotion.morph, value: model.viewportMode)
	}

	private var hud: some View {
		HStack(spacing: 2) {
			Button {
				withAnimation(DeveloperMotion.morph) { isViewportShelfPresented.toggle() }
			} label: {
				HStack(spacing: 6) {
					Image(systemName: model.viewportMode.preset?.family.symbolName ?? "rectangle.dashed")
						.font(.system(size: 12, weight: .semibold))
						.contentTransition(.symbolEffect(.replace))
					Text(model.viewportMode.preset?.name ?? "Responsive")
						.font(.system(size: 12, weight: .medium))
						.contentTransition(.interpolate)
				}
				.padding(.horizontal, 10)
				.frame(height: 30)
				.background {
					Capsule().fill(Color.primary.opacity(isViewportShelfPresented ? 0.12 : 0))
				}
				.contentShape(Capsule())
			}
			.buttonStyle(DeveloperPressStyle())
			.help("Viewport presets (⌥⌘M cycles)")

			divider

			DeveloperIconButton(
				systemImage: "cursorarrow.rays",
				help: "Inspect element (⌥⌘C)",
				isActive: model.isPicking
			) {
				model.toggleInspect()
			}

			DeveloperIconButton(
				systemImage: "terminal",
				help: "Console (⌥⌘J)",
				isActive: model.isPanelPresented && model.selectedTab == .console
			) {
				model.togglePanel(tab: .console)
			}
			.overlay(alignment: .topTrailing) {
				if model.unseenErrorCount > 0 {
					Text(model.unseenErrorCount > 99 ? "99+" : "\(model.unseenErrorCount)")
						.font(.system(size: 9, weight: .bold).monospacedDigit())
						.foregroundStyle(.white)
						.padding(.horizontal, 4)
						.frame(minWidth: 15, minHeight: 15)
						.background(Capsule().fill(Color.red))
						.offset(x: 4, y: -3)
						.transition(.scale.combined(with: .opacity))
						.allowsHitTesting(false)
				}
			}
			.animation(DeveloperMotion.press, value: model.unseenErrorCount)

			DeveloperIconButton(
				systemImage: "arrow.up.arrow.down",
				help: "Network",
				isActive: model.isPanelPresented && model.selectedTab == .network
			) {
				model.togglePanel(tab: .network)
			}
		}
		.padding(4)
		.developerGlass(in: Capsule(), interactive: true)
		.developerGlassID("hud", in: glassNamespace)
	}

	private var divider: some View {
		Rectangle()
			.fill(Color.primary.opacity(0.12))
			.frame(width: 1, height: 16)
			.padding(.horizontal, 3)
	}
}

// MARK: - Viewport shelf

struct DeveloperViewportShelf: View {
	@Bindable var model: DeveloperOverlayModel
	let dismiss: () -> Void

	private let columns = [GridItem(.adaptive(minimum: 92), spacing: 8)]

	var body: some View {
		VStack(alignment: .leading, spacing: 10) {
			HStack {
				Text("Viewport")
					.font(.system(size: 12, weight: .semibold))
				Spacer()
				if let viewport = model.pageViewport {
					Text("\(Int(viewport.width)) × \(Int(viewport.height)) @\(viewport.devicePixelRatio.formatted())x")
						.font(.system(size: 11).monospacedDigit())
						.foregroundStyle(.secondary)
						.contentTransition(.numericText())
				}
			}

			LazyVGrid(columns: columns, spacing: 8) {
				tile(
					title: "Responsive",
					subtitle: "Fill window",
					symbol: "rectangle.dashed",
					isSelected: model.viewportMode.preset == nil
				) {
					model.setViewport(nil)
				}
				ForEach(DeveloperViewportPreset.builtIn) { preset in
					tile(
						title: preset.name,
						subtitle: "\(Int(preset.size.width)) × \(Int(preset.size.height))",
						symbol: preset.family.symbolName,
						isSelected: model.viewportMode.preset == preset
					) {
						model.setViewport(preset)
					}
				}
			}

			Text("Drag the frame's edges for a custom size. ⌥⌘M cycles presets.")
				.font(.system(size: 10))
				.foregroundStyle(.secondary)
		}
		.padding(12)
		.frame(width: 320)
	}

	private func tile(
		title: String,
		subtitle: String,
		symbol: String,
		isSelected: Bool,
		action: @escaping () -> Void
	) -> some View {
		Button {
			withAnimation(DeveloperMotion.morph) { action() }
		} label: {
			VStack(spacing: 4) {
				Image(systemName: symbol)
					.font(.system(size: 16, weight: .medium))
					.frame(height: 20)
				Text(title)
					.font(.system(size: 11, weight: .medium))
					.lineLimit(1)
				Text(subtitle)
					.font(.system(size: 9).monospacedDigit())
					.foregroundStyle(isSelected ? Color.white.opacity(0.8) : Color.secondary)
			}
			.foregroundStyle(isSelected ? Color.white : Color.primary)
			.frame(maxWidth: .infinity)
			.padding(.vertical, 8)
			.background {
				RoundedRectangle(cornerRadius: 12, style: .continuous)
					.fill(isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color.primary.opacity(0.06)))
			}
			.contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
		}
		.buttonStyle(DeveloperPressStyle())
		.animation(DeveloperMotion.snappy, value: isSelected)
	}
}

// MARK: - Viewport badge

/// Floating label above the framed page: name, live size, rotate and exit.
struct DeveloperViewportBadge: View {
	@Bindable var model: DeveloperOverlayModel

	var body: some View {
		HStack(spacing: 8) {
			if let preset = model.viewportMode.preset {
				Image(systemName: preset.family.symbolName)
					.font(.system(size: 11, weight: .semibold))
					.rotationEffect(.degrees(model.viewportMode.orientation == .landscape ? 90 : 0))
				Text(preset.name)
					.font(.system(size: 12, weight: .semibold))
				if let size = model.viewportMode.targetSize {
					Text("\(Int(size.width)) × \(Int(size.height))")
						.font(.system(size: 12, weight: .regular).monospacedDigit())
						.foregroundStyle(.secondary)
						.contentTransition(.numericText())
				}
				if preset.supportsRotation {
					DeveloperIconButton(systemImage: "rotate.right", help: "Rotate", size: 24) {
						withAnimation(DeveloperMotion.morph) { model.rotateViewport() }
					}
				}
				DeveloperIconButton(systemImage: "xmark", help: "Back to responsive", size: 24) {
					withAnimation(DeveloperMotion.morph) { model.setViewport(nil) }
				}
			}
		}
		.padding(.leading, 12)
		.padding(.trailing, 4)
		.frame(height: 32)
		.animation(DeveloperMotion.morph, value: model.viewportMode.orientation)
	}
}

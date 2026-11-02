import BrowserSidebar
import BrowserView
import SwiftUI

struct BrowserFloatingToolbarActions {
	var goBack: @MainActor () -> Void
	var goForward: @MainActor () -> Void
	var reload: @MainActor () -> Void
	var openLocation: @MainActor () -> Void
	var copyURL: @MainActor () -> Void
	var openNewTab: @MainActor () -> Void
	var selectTab: @MainActor (BrowserTabID) -> Void
	var closeTab: @MainActor (BrowserTabID) -> Void
}

/// Bottom-center floating navigation, in the style of mobile browsers and desktop harness apps.
///
/// Layout (expanded):  [‹ ›]  [favicon  host  ⟳]  [▢ n  +]
/// Layout (compact):          [favicon  host]
/// The tab shelf springs up above the bar when the tab button is pressed.
struct BrowserFloatingToolbarView: View {
	nonisolated private enum GlassID: Hashable {
		case navigation
		case address
		case tabs
		case accessories
		case shelf
	}

	private enum Metrics {
		static let barHeight: CGFloat = 40
		static let compactHeight: CGFloat = 32
		static let clusterSpacing: CGFloat = 10
		/// Glass shapes closer than this blend together. Kept below `clusterSpacing` so the
		/// groups read as separate pills at rest and only melt into each other mid-morph.
		static let glassMergeDistance: CGFloat = 4
		static let shelfEdgeFade: CGFloat = 18
		static let addressMinWidth: CGFloat = 260
		static let addressMaxWidth: CGFloat = 380
		static let compactAddressWidth: CGFloat = 200
		static let shelfMaxWidth: CGFloat = 640
		static let shelfChipWidth: CGFloat = 168
		static let shelfHeight: CGFloat = 44
		static let outerPadding: CGFloat = 14
	}

	let sidebarViewModel: BrowserSidebarViewModel
	let state: BrowserFloatingToolbarState
	let actions: BrowserFloatingToolbarActions
	/// Selected page's tint for the glass; nil keeps stock glass.
	var siteTintStore: BrowserSiteTintStore?

	@Namespace private var glassNamespace
	@State private var isHoveringAddress = false

	var body: some View {
		FloatingGlassContainer(spacing: Metrics.glassMergeDistance) {
			VStack(spacing: 10) {
				if state.isTabShelfPresented {
					tabShelf
						.transition(
							.asymmetric(
								insertion: .scale(scale: 0.86, anchor: .bottom).combined(with: .opacity),
								removal: .scale(scale: 0.92, anchor: .bottom).combined(with: .opacity)
							)
						)
				}
				bar
			}
		}
		.padding(.horizontal, Metrics.outerPadding)
		.padding(.top, Metrics.outerPadding)
		.padding(.bottom, Metrics.outerPadding)
		.fixedSize()
		.onHover { isHovering in
			state.setHovering(isHovering)
		}
		.animation(FloatingMotion.morph, value: state.isExpanded)
		.animation(FloatingMotion.morph, value: state.isTabShelfPresented)
		.animation(FloatingMotion.snappy, value: sidebarViewModel.selectedTabID)
		.animation(FloatingMotion.snappy, value: sidebarViewModel.tabs.count)
		.environment(\.browserSiteTint, siteTintStore?.currentTint)
	}

	// MARK: - Bar

	private var bar: some View {
		HStack(spacing: Metrics.clusterSpacing) {
			if state.isExpanded {
				navigationCluster
					.transition(.scale(scale: 0.6, anchor: .trailing).combined(with: .opacity))
			}

			addressPill

			if state.isExpanded {
				tabsCluster
					.transition(.scale(scale: 0.6, anchor: .leading).combined(with: .opacity))
			}

			if state.isExpanded, !state.trailingAccessories.isEmpty {
				accessoryCluster
					.transition(.scale(scale: 0.6, anchor: .leading).combined(with: .opacity))
			}
		}
		.gesture(WindowDragGesture())
		.allowsWindowActivationEvents(true)
	}

	private var navigationCluster: some View {
		HStack(spacing: 2) {
			ToolbarIconButton(systemName: "chevron.left", help: "Back", isEnabled: sidebarViewModel.canGoBack) {
				actions.goBack()
			}
			ToolbarIconButton(systemName: "chevron.right", help: "Forward", isEnabled: sidebarViewModel.canGoForward) {
				actions.goForward()
			}
		}
		.padding(.horizontal, 5)
		.frame(height: Metrics.barHeight)
		.floatingGlass(in: Capsule(), interactive: true)
		.floatingGlassID(GlassID.navigation, in: glassNamespace)
	}

	private var addressPill: some View {
		let height = state.isExpanded ? Metrics.barHeight : Metrics.compactHeight
		return HStack(spacing: 8) {
			TabFavicon(urlString: selectedTab?.faviconURL, isLoading: sidebarViewModel.isLoading)
				.frame(width: 16, height: 16)

			Text(addressTitle)
				.font(.system(size: state.isExpanded ? 13 : 12, weight: .medium))
				.foregroundStyle(addressTitleIsPlaceholder ? .secondary : .primary)
				.lineLimit(1)
				.truncationMode(.middle)
				.frame(maxWidth: .infinity, alignment: state.isExpanded ? .leading : .center)
				.contentTransition(.opacity)

			if state.isExpanded, isHoveringAddress, !addressTitleIsPlaceholder {
				ToolbarIconButton(systemName: "link", help: "Copy URL (⇧⌘C)", size: 26) {
					actions.copyURL()
				}
				.transition(.scale(scale: 0.5).combined(with: .opacity))
			}

			if state.isExpanded {
				ToolbarIconButton(
					systemName: sidebarViewModel.isLoading ? "xmark" : "arrow.clockwise",
					help: "Reload",
					size: 26
				) {
					actions.reload()
				}
				.transition(.scale.combined(with: .opacity))
			}
		}
		.padding(.leading, 14)
		.padding(.trailing, state.isExpanded ? 6 : 14)
		.frame(
			width: state.isExpanded ? nil : Metrics.compactAddressWidth,
			height: height
		)
		.frame(minWidth: state.isExpanded ? Metrics.addressMinWidth : nil, maxWidth: Metrics.addressMaxWidth)
		.contentShape(Capsule())
		.floatingGlass(in: Capsule(), interactive: true)
		.floatingGlassID(GlassID.address, in: glassNamespace)
		.overlay(alignment: .bottom) {
			LoadingSheen(isLoading: sidebarViewModel.isLoading)
				.clipShape(Capsule())
				.allowsHitTesting(false)
		}
		.onTapGesture {
			actions.openLocation()
		}
		.onHover { isHovering in
			withAnimation(FloatingMotion.snappy) {
				isHoveringAddress = isHovering
			}
		}
		.onGeometryChange(for: CGRect.self) { proxy in
			proxy.frame(in: .global)
		} action: { frame in
			state.addressPillFrame = frame
		}
		.help("Search or enter address (⌘L)")
	}

	private var tabsCluster: some View {
		HStack(spacing: 2) {
			TabCountButton(count: sidebarViewModel.tabs.count, isActive: state.isTabShelfPresented) {
				state.toggleTabShelf()
			}
			ToolbarIconButton(systemName: "plus", help: "New Tab (⌘T)") {
				actions.openNewTab()
			}
		}
		.padding(.horizontal, 5)
		.frame(height: Metrics.barHeight)
		.floatingGlass(in: Capsule(), interactive: true)
		.floatingGlassID(GlassID.tabs, in: glassNamespace)
	}

	private var accessoryCluster: some View {
		HStack(spacing: 2) {
			ForEach(state.trailingAccessories) { accessory in
				ToolbarIconButton(systemName: accessory.systemImage, help: accessory.help) {
					accessory.action()
				}
			}
		}
		.padding(.horizontal, 5)
		.frame(height: Metrics.barHeight)
		.floatingGlass(in: Capsule(), interactive: true)
		.floatingGlassID(GlassID.accessories, in: glassNamespace)
	}

	// MARK: - Tab shelf

	private var tabShelf: some View {
		let tabs = sidebarViewModel.tabs
		let contentWidth = CGFloat(tabs.count) * (Metrics.shelfChipWidth + 4) + 12
		return ScrollViewReader { proxy in
			ScrollView(.horizontal, showsIndicators: false) {
				HStack(spacing: 4) {
					ForEach(tabs) { tab in
						TabShelfChip(
							tab: tab,
							isSelected: tab.id == sidebarViewModel.selectedTabID,
							width: Metrics.shelfChipWidth,
							onSelect: { actions.selectTab(tab.id) },
							onClose: { actions.closeTab(tab.id) }
						)
						.id(tab.id)
						.transition(.scale(scale: 0.8).combined(with: .opacity))
					}
				}
				.padding(.horizontal, 6)
			}
			.frame(width: min(contentWidth, Metrics.shelfMaxWidth), height: Metrics.shelfHeight)
			.mask {
				// Fade chips into the glass at the edges when the shelf overflows, so a clipped
				// chip reads as "scroll for more" rather than a cut-off.
				if contentWidth > Metrics.shelfMaxWidth {
					HStack(spacing: 0) {
						LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing)
							.frame(width: Metrics.shelfEdgeFade)
						Rectangle()
						LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
							.frame(width: Metrics.shelfEdgeFade)
					}
				}
				else {
					Rectangle()
				}
			}
			.onAppear {
				if let selectedID = sidebarViewModel.selectedTabID {
					proxy.scrollTo(selectedID, anchor: .center)
				}
			}
		}
		.floatingGlass(in: RoundedRectangle(cornerRadius: 22, style: .continuous))
		.floatingGlassID(GlassID.shelf, in: glassNamespace)
	}

	// MARK: - Derived

	private var selectedTab: BrowserTabViewModel? {
		guard let selectedTabID = sidebarViewModel.selectedTabID else { return nil }
		return sidebarViewModel.tabs.first { $0.id == selectedTabID }
	}

	private var addressTitleIsPlaceholder: Bool {
		BrowserFloatingToolbarFormatting.displayHost(for: selectedTab?.currentURL) == nil
	}

	private var addressTitle: String {
		BrowserFloatingToolbarFormatting.displayHost(for: selectedTab?.currentURL) ?? "Search or enter address"
	}
}

enum BrowserFloatingToolbarFormatting {
	/// "https://www.github.com/foo" → "github.com". Returns nil for blank pages.
	static func displayHost(for urlString: String?) -> String? {
		guard let urlString, !urlString.isEmpty, urlString != "about:blank" else { return nil }
		guard let url = URL(string: urlString), let host = url.host(), !host.isEmpty else {
			return urlString
		}
		return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
	}
}

// MARK: - Pieces

private struct ToolbarIconButton: View {
	let systemName: String
	var help: String
	var isEnabled = true
	var size: CGFloat = 30
	let action: () -> Void

	var body: some View {
		Button(action: action) {
			Image(systemName: systemName)
				.font(.system(size: 13, weight: .semibold))
				.contentTransition(.symbolEffect(.replace))
				.frame(width: size, height: size)
		}
		.buttonStyle(FloatingPressButtonStyle())
		.disabled(!isEnabled)
		.help(help)
	}
}

private struct TabCountButton: View {
	let count: Int
	let isActive: Bool
	let action: () -> Void

	var body: some View {
		Button(action: action) {
			ZStack {
				RoundedRectangle(cornerRadius: 5, style: .continuous)
					.strokeBorder(lineWidth: 1.6)
					.frame(width: 18, height: 18)
				Text("\(min(count, 99))")
					.font(.system(size: 10, weight: .bold, design: .rounded))
					.monospacedDigit()
					.contentTransition(.numericText(value: Double(count)))
			}
			.frame(width: 30, height: 30)
		}
		.buttonStyle(FloatingPressButtonStyle(isActive: isActive))
		.help("Tabs")
	}
}

/// Hover highlight + springy press-down, used by every toolbar button.
private struct FloatingPressButtonStyle: ButtonStyle {
	var isActive = false

	func makeBody(configuration: Configuration) -> some View {
		FloatingPressButtonBody(configuration: configuration, isActive: isActive)
	}
}

private struct FloatingPressButtonBody: View {
	let configuration: ButtonStyleConfiguration
	let isActive: Bool
	@Environment(\.isEnabled) private var isEnabled
	@State private var isHovering = false

	var body: some View {
		configuration.label
			.foregroundStyle(isEnabled ? Color.primary : Color.primary.opacity(0.32))
			.background {
				Circle()
					.fill(Color.primary.opacity(highlightOpacity))
			}
			.contentShape(Circle())
			.scaleEffect(configuration.isPressed ? 0.86 : 1)
			.animation(FloatingMotion.press, value: configuration.isPressed)
			.animation(FloatingMotion.snappy, value: isHovering)
			.animation(FloatingMotion.snappy, value: isActive)
			.onHover { isHovering = $0 }
	}

	private var highlightOpacity: Double {
		guard isEnabled else { return 0 }
		if configuration.isPressed { return 0.16 }
		if isActive { return 0.12 }
		return isHovering ? 0.08 : 0
	}
}

private struct TabShelfChip: View {
	let tab: BrowserTabViewModel
	let isSelected: Bool
	let width: CGFloat
	let onSelect: () -> Void
	let onClose: () -> Void
	@State private var isHovering = false

	var body: some View {
		HStack(spacing: 7) {
			TabFavicon(urlString: tab.faviconURL, isLoading: tab.isLoading)
				.frame(width: 14, height: 14)
			Text(tab.displayTitle)
				.font(.system(size: 12, weight: isSelected ? .semibold : .regular))
				.lineLimit(1)
				.truncationMode(.tail)
				.frame(maxWidth: .infinity, alignment: .leading)
			if isHovering {
				Button(action: onClose) {
					Image(systemName: "xmark")
						.font(.system(size: 9, weight: .bold))
						.frame(width: 16, height: 16)
				}
				.buttonStyle(FloatingPressButtonStyle())
				.transition(.scale.combined(with: .opacity))
				.help("Close Tab")
			}
		}
		.padding(.leading, 10)
		.padding(.trailing, 6)
		.frame(width: width, height: 32)
		.background {
			if isSelected {
				// Selected tab reads as a raised card, like Arc's active tab.
				RoundedRectangle(cornerRadius: 16, style: .continuous)
					.fill(.background.opacity(0.85))
					.shadow(color: .black.opacity(0.12), radius: 3, y: 1)
			}
			else {
				RoundedRectangle(cornerRadius: 16, style: .continuous)
					.fill(Color.primary.opacity(isHovering ? 0.06 : 0))
			}
		}
		.contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
		.onTapGesture(perform: onSelect)
		.onHover { isHovering = $0 }
		.animation(FloatingMotion.snappy, value: isHovering)
		.animation(FloatingMotion.snappy, value: isSelected)
	}
}

private struct TabFavicon: View {
	let urlString: String?
	let isLoading: Bool

	var body: some View {
		ZStack {
			if let url = urlString.flatMap({ URL(string: $0) }) {
				AsyncImage(url: url) { phase in
					if let image = phase.image {
						image.resizable().interpolation(.high).aspectRatio(contentMode: .fit)
					}
					else {
						placeholder
					}
				}
			}
			else {
				placeholder
			}
		}
		.clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
		.opacity(isLoading ? 0.55 : 1)
		.animation(FloatingMotion.snappy, value: isLoading)
	}

	private var placeholder: some View {
		Image(systemName: "globe")
			.resizable()
			.aspectRatio(contentMode: .fit)
			.foregroundStyle(.secondary)
	}
}

/// A soft highlight that sweeps along the bottom of the address pill while a page loads.
private struct LoadingSheen: View {
	let isLoading: Bool
	@State private var phase: CGFloat = -1

	var body: some View {
		GeometryReader { proxy in
			if isLoading {
				LinearGradient(
					colors: [.clear, Color.accentColor.opacity(0.85), .clear],
					startPoint: .leading,
					endPoint: .trailing
				)
				.frame(width: proxy.size.width * 0.4, height: 2)
				.offset(x: phase * proxy.size.width, y: proxy.size.height - 2)
				.onAppear {
					phase = -0.4
					withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: false)) {
						phase = 1
					}
				}
				.transition(.opacity)
			}
		}
	}
}

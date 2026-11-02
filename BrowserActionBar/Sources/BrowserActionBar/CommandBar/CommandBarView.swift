import AppKit
import SwiftUI

/// Where the card sits inside the panel window.
public enum CommandBarPlacement: Equatable, Sendable {
	/// Field on top, results drop down (classic Spotlight, used without a toolbar anchor).
	case top
	/// Field at the bottom over the toolbar pill, results grow upward.
	case bottom
}

/// Panel-owned presentation state the SwiftUI tree animates against.
@MainActor
@Observable
final class CommandBarChromeState {
	var isShown = false
	var placement: CommandBarPlacement = .top
	var cardWidth: CGFloat = 640
	var maxResultsHeight: CGFloat = CommandBarLayout.maxResultsHeight
}

struct CommandBarRootView: View {
	let model: BrowserActionBarViewModel
	let chrome: CommandBarChromeState
	let field: NSTextField

	var body: some View {
		ZStack(alignment: chrome.placement == .bottom ? .bottom : .top) {
			// Clicks on the transparent margin dismiss, like clicking outside Spotlight.
			Color.clear
				.contentShape(Rectangle())
				.onTapGesture { model.dismiss() }

			CommandBarCard(model: model, chrome: chrome, field: field)
				.padding(CommandBarLayout.outerPadding)
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity)
	}
}

private struct CommandBarCard: View {
	let model: BrowserActionBarViewModel
	let chrome: CommandBarChromeState
	let field: NSTextField
	@Namespace private var glassNamespace

	private var isBottom: Bool {
		chrome.placement == .bottom
	}

	private var resultsHeight: CGFloat {
		min(CommandBarLayout.resultsHeight(for: model.sections), chrome.maxResultsHeight)
	}

	var body: some View {
		VStack(spacing: 0) {
			if isBottom {
				results
				divider
			}
			CommandBarFieldRow(model: model, field: field, namespace: glassNamespace)
			if !isBottom {
				divider
				results
			}
		}
		.frame(width: chrome.cardWidth)
		.commandBarGlass(cornerRadius: CommandBarLayout.cornerRadius, castsShadow: true)
		// Taps on the card hit the card first, so they never reach the dismiss layer behind it.
		.contentShape(RoundedRectangle(cornerRadius: CommandBarLayout.cornerRadius, style: .continuous))
		// Scale, offset and opacity only. The old entrance also animated a blur, which forced
		// the whole glass card (and the hosted text field) through an offscreen pass on every
		// frame of the spring: that was most of the stutter when the bar opened.
		.scaleEffect(chrome.isShown ? 1 : 0.94, anchor: isBottom ? .bottom : .top)
		.offset(y: chrome.isShown ? 0 : (isBottom ? 14 : -10))
		.opacity(chrome.isShown ? 1 : 0)
		// Entrances spring; exits are quicker and never bounce, so the bar gets out of the way.
		.animation(chrome.isShown ? CommandBarMotion.present : CommandBarMotion.exit, value: chrome.isShown)
		.animation(CommandBarMotion.resize, value: resultsHeight)
	}

	@ViewBuilder
	private var divider: some View {
		if resultsHeight > 0 {
			Rectangle()
				.fill(Color.primary.opacity(0.08))
				.frame(height: 0.5)
				.padding(.horizontal, 14)
				.transition(.opacity)
		}
	}

	private var results: some View {
		CommandBarResultsList(model: model)
			.frame(height: resultsHeight, alignment: .top)
			.clipped()
	}
}

// MARK: - Field row

private struct CommandBarFieldRow: View {
	let model: BrowserActionBarViewModel
	let field: NSTextField
	let namespace: Namespace.ID

	private var chip: (title: String, symbol: String)? {
		if let siteSearch = model.siteSearch {
			return (siteSearch.name, siteSearch.symbolName)
		}
		guard model.scope != .all else { return nil }
		return (model.scope.title, model.scope.symbolName)
	}

	private var leadingSymbol: String {
		switch model.queryIntent {
		case .url: "globe"
		case .empty, .search: "magnifyingglass"
		}
	}

	var body: some View {
		HStack(spacing: 10) {
			CommandBarGlassContainer(spacing: 6) {
				HStack(spacing: 8) {
					if let chip {
						HStack(spacing: 5) {
							Image(systemName: chip.symbol)
								.font(.system(size: 11, weight: .semibold))
							Text(chip.title)
								.font(.system(size: 12, weight: .semibold))
						}
						.padding(.horizontal, 9)
						.frame(height: 26)
						.foregroundStyle(Color.accentColor)
						.commandBarGlass(cornerRadius: 13, tint: .accentColor)
						.commandBarGlassID("chip", in: namespace)
						.transition(.scale(scale: 0.6, anchor: .leading).combined(with: .opacity))
						.onTapGesture { model.popScope() }
						.help("Click or press ⌫ to clear")
					}
					else {
						Image(systemName: leadingSymbol)
							.font(.system(size: 16, weight: .medium))
							.foregroundStyle(.secondary)
							.frame(width: 20)
							.contentTransition(.symbolEffect(.replace))
							.transition(.opacity)
					}
				}
			}
			.animation(CommandBarMotion.chip, value: chip?.title)

			CommandBarFieldHost(field: field)
				.frame(maxWidth: .infinity)

			if model.isPresented {
				CommandBarKeycap(text: "esc")
					.opacity(0.6)
			}
		}
		.padding(.horizontal, 18)
		.frame(height: CommandBarLayout.fieldHeight)
	}
}

/// Hosts the panel's AppKit text field (IME, field editor, responder chain) inside SwiftUI.
private struct CommandBarFieldHost: NSViewRepresentable {
	let field: NSTextField

	func makeNSView(context: Context) -> NSTextField {
		field
	}

	func updateNSView(_ nsView: NSTextField, context: Context) {}
}

// MARK: - Results

private struct CommandBarResultsList: View {
	let model: BrowserActionBarViewModel
	@Namespace private var highlightNamespace

	var body: some View {
		ScrollViewReader { proxy in
			ScrollView(.vertical) {
				VStack(alignment: .leading, spacing: 0) {
					ForEach(model.sections) { section in
						if let title = section.title {
							Text(title)
								.font(.system(size: 11, weight: .semibold))
								.foregroundStyle(.secondary)
								.padding(.horizontal, 20)
								.frame(height: CommandBarLayout.headerHeight, alignment: .bottomLeading)
						}
						ForEach(section.items) { item in
							CommandBarRow(
								item: item,
								isHighlighted: item.id == model.highlightedItemID,
								highlightNamespace: highlightNamespace
							)
							.id(item.id)
							.onHover { isHovering in
								if isHovering {
									model.hoverHighlight(itemID: item.id)
								}
							}
							.onTapGesture {
								let forceNewTab = NSEvent.modifierFlags.contains(.command)
								model.activate(item, forceNewTab: forceNewTab)
							}
						}
					}
				}
				.padding(.vertical, CommandBarLayout.listVerticalPadding)
			}
			.scrollIndicators(.never)
			// One transaction for the whole list, so the highlight slides between rows with
			// matchedGeometryEffect. A per-row `.animation(value: isHighlighted)` animated the
			// two rows separately, and the pill cross-faded instead of moving.
			.animation(CommandBarMotion.highlight, value: model.highlightedItemID)
			.onChange(of: model.highlightedItemID) { _, newValue in
				guard let newValue else { return }
				withAnimation(CommandBarMotion.highlight) {
					proxy.scrollTo(newValue)
				}
			}
		}
	}
}

private struct CommandBarRow: View {
	let item: CommandBarItem
	let isHighlighted: Bool
	let highlightNamespace: Namespace.ID

	var body: some View {
		HStack(spacing: 12) {
			CommandBarRowIcon(item: item, isHighlighted: isHighlighted)

			VStack(alignment: .leading, spacing: 1) {
				Text(item.title)
					.font(.system(size: 13.5, weight: .medium))
					.lineLimit(1)
					.truncationMode(.tail)
				if let subtitle = item.subtitle, !subtitle.isEmpty {
					Text(subtitle)
						.font(.system(size: 11.5))
						.foregroundStyle(.secondary)
						.lineLimit(1)
						.truncationMode(.middle)
				}
			}

			Spacer(minLength: 8)

			if let accessory = item.accessory {
				if accessory.count <= 3 || item.kind == .command {
					CommandBarKeycap(text: accessory)
						.opacity(isHighlighted || item.kind == .command ? 1 : 0)
				}
				else {
					Text(accessory)
						.font(.system(size: 11.5, weight: .medium))
						.foregroundStyle(.secondary)
				}
			}
		}
		.padding(.horizontal, 12)
		.frame(height: CommandBarLayout.rowHeight)
		.background {
			if isHighlighted {
				RoundedRectangle(cornerRadius: 12, style: .continuous)
					.fill(Color.primary.opacity(0.085))
					.matchedGeometryEffect(id: "highlight", in: highlightNamespace)
			}
		}
		.padding(.horizontal, 8)
		.contentShape(Rectangle())
	}
}

private struct CommandBarRowIcon: View {
	let item: CommandBarItem
	let isHighlighted: Bool

	var body: some View {
		ZStack {
			RoundedRectangle(cornerRadius: 7, style: .continuous)
				.fill(Color.primary.opacity(isHighlighted ? 0.1 : 0.06))
			if let iconURL = item.iconURL, let url = URL(string: iconURL) {
				AsyncImage(url: url) { phase in
					if let image = phase.image {
						image.resizable().interpolation(.high).frame(width: 16, height: 16)
					}
					else {
						symbol
					}
				}
			}
			else {
				symbol
			}
		}
		.frame(width: 26, height: 26)
		.scaleEffect(isHighlighted ? 1.06 : 1)
	}

	private var symbol: some View {
		Image(systemName: item.symbolName)
			.font(.system(size: 12.5, weight: .medium))
			.foregroundStyle(item.kind == .answer ? Color.accentColor : Color.primary.opacity(0.75))
	}
}

struct CommandBarKeycap: View {
	let text: String

	var body: some View {
		Text(text)
			.font(.system(size: 10.5, weight: .semibold, design: .rounded))
			.foregroundStyle(.secondary)
			.padding(.horizontal, 6)
			.frame(minWidth: 20, minHeight: 18)
			.background(
				RoundedRectangle(cornerRadius: 5, style: .continuous)
					.fill(Color.primary.opacity(0.07))
			)
	}
}

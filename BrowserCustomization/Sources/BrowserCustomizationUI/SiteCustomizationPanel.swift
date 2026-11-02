import AppKit
import BrowserCustomization
import SwiftUI

/// Everything the panel needs from the browser, so it stays free of CEF and BrowserView.
@MainActor
public struct SiteCustomizationPanelActions {
	public var startZapPicker: @MainActor () -> Void
	/// Counts elements matching a selector on the live page (nil while unknown).
	public var countMatches: @MainActor (String) async -> Int?
	public var dismiss: @MainActor () -> Void

	public init(
		startZapPicker: @escaping @MainActor () -> Void,
		countMatches: @escaping @MainActor (String) async -> Int?,
		dismiss: @escaping @MainActor () -> Void
	) {
		self.startZapPicker = startZapPicker
		self.countMatches = countMatches
		self.dismiss = dismiss
	}
}

public struct SiteCustomizationPanel: View {
	private let store: BoostStore
	private let url: URL
	private let actions: SiteCustomizationPanelActions

	@State private var draft: Boost
	@State private var appeared = false
	@State private var showsCode = false
	@State private var matchCounts: [String: Int] = [:]
	@State private var saveTask: Task<Void, Never>?
	@State private var customTint: Color = .accentColor

	public init(store: BoostStore, url: URL, actions: SiteCustomizationPanelActions) {
		self.store = store
		self.url = url
		self.actions = actions
		let initial = store.siteBoostOrNew(for: url) ?? .forSite(url.host ?? "site")
		_draft = State(initialValue: initial)
		_showsCode = State(initialValue: initial.css.isEmpty == false || initial.allowsJavaScript)
		if let rgb = initial.tint.rgb {
			_customTint = State(initialValue: Color(red: rgb.red, green: rgb.green, blue: rgb.blue))
		}
	}

	private var accent: Color {
		if let rgb = draft.tint.rgb { return Color(red: rgb.red, green: rgb.green, blue: rgb.blue) }
		return .accentColor
	}

	public var body: some View {
		VStack(alignment: .leading, spacing: 16) {
			header
			if draft.isEnabled {
				Group {
					presets
					zaps
					tint
					code
				}
				.transition(.asymmetric(
					insertion: .opacity.combined(with: .offset(y: -6)),
					removal: .opacity
				))
			}
			footer
		}
		.padding(18)
		.frame(width: 340)
		.navigatorGlass(cornerRadius: 26, tint: draft.tint == .automatic ? nil : accent)
		.scaleEffect(appeared ? 1 : 0.92, anchor: .topTrailing)
		.opacity(appeared ? 1 : 0)
		.blur(radius: appeared ? 0 : 6)
		.onAppear {
			withAnimation(.navigatorBouncy) { appeared = true }
			refreshMatchCounts()
		}
		.onChange(of: store.revision) { _, _ in
			// External edits (or a zap picked on the page) win over the draft.
			if let latest = store.boost(id: draft.id), latest != draft {
				withAnimation(.navigatorSnappy) { draft = latest }
				refreshMatchCounts()
			}
		}
		.onExitCommand(perform: close)
		.animation(.navigatorSnappy, value: draft)
	}

	// MARK: Sections

	private var header: some View {
		HStack(spacing: 12) {
			ZStack {
				Circle().fill(accent.gradient)
				Text(String(draft.name.prefix(1)).uppercased())
					.font(.system(size: 15, weight: .bold, design: .rounded))
					.foregroundStyle(.white)
			}
			.frame(width: 34, height: 34)
			.shadow(color: accent.opacity(0.4), radius: 8, y: 3)

			VStack(alignment: .leading, spacing: 1) {
				Text(draft.name).font(.headline).lineLimit(1)
				Text(draft.isEnabled ? summary : "Showing the original site")
					.font(.caption)
					.foregroundStyle(.secondary)
					.contentTransition(.numericText())
			}
			Spacer()
			Toggle("Boost", isOn: binding(\.isEnabled))
				.toggleStyle(.switch)
				.labelsHidden()
				.controlSize(.small)
				.tint(accent)
		}
	}

	private var summary: String {
		var parts: [String] = []
		if draft.presets.isEmpty == false { parts.append("\(draft.presets.count) preset\(draft.presets.count == 1 ? "" : "s")") }
		if draft.zaps.isEmpty == false { parts.append("\(draft.zaps.count) hidden") }
		if draft.css.isEmpty == false { parts.append("custom CSS") }
		if draft.allowsJavaScript, draft.javascript.isEmpty == false { parts.append("script") }
		return parts.isEmpty ? "No changes yet" : parts.joined(separator: " · ")
	}

	private var presets: some View {
		section("Presets") {
			FlowLayout(spacing: 6) {
				ForEach(BoostPreset.all) { preset in
					let isOn = draft.presets.contains(preset.id)
					Button {
						update { boost in
							if let index = boost.presets.firstIndex(of: preset.id) {
								boost.presets.remove(at: index)
							}
							else {
								boost.presets.append(preset.id)
							}
						}
					} label: {
						Label(preset.title, systemImage: preset.systemImage)
							.font(.callout.weight(.medium))
							.padding(.horizontal, 10)
							.padding(.vertical, 6)
							.foregroundStyle(isOn ? Color.white : Color.primary)
							.background {
								Capsule()
									.fill(isOn ? AnyShapeStyle(accent.gradient) : AnyShapeStyle(Color.secondary.opacity(0.14)))
							}
							.scaleEffect(isOn ? 1.0 : 0.97)
					}
					.buttonStyle(SpringPressStyle())
					.help(isOn ? "Turn off \(preset.title)" : "Turn on \(preset.title)")
				}
			}
		}
	}

	private var zaps: some View {
		section("Hidden elements", trailing: {
			Button {
				actions.startZapPicker()
			} label: {
				Label("Zap", systemImage: "scope")
					.font(.callout.weight(.semibold))
					.padding(.horizontal, 10)
					.padding(.vertical, 5)
			}
			.buttonStyle(SpringPressStyle())
			.navigatorGlassCapsule(tint: accent)
			.help("Pick an element on the page to hide it (⌥⌘Z)")
		}) {
			if draft.zaps.isEmpty {
				Text("Click Zap, then click anything on the page to hide it here.")
					.font(.caption)
					.foregroundStyle(.secondary)
			}
			else {
				VStack(spacing: 4) {
					ForEach(draft.zaps, id: \.self) { selector in
						HStack(spacing: 8) {
							Text(selector)
								.font(.system(.caption, design: .monospaced))
								.lineLimit(1)
								.truncationMode(.middle)
							Spacer(minLength: 4)
							if let count = matchCounts[selector] {
								Text(count < 0 ? "invalid" : "\(count)")
									.font(.caption2.monospacedDigit())
									.foregroundStyle(count <= 0 ? Color.orange : Color.secondary)
									.help(count < 0 ? "Not a valid selector" : "\(count) element(s) hidden on this page")
							}
							Button {
								update { $0.zaps.removeAll { $0 == selector } }
							} label: {
								Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
							}
							.buttonStyle(.plain)
							.help("Show this element again")
						}
						.padding(.horizontal, 10)
						.padding(.vertical, 6)
						.background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
						.transition(.asymmetric(
							insertion: .scale(scale: 0.9).combined(with: .opacity),
							removal: .move(edge: .trailing).combined(with: .opacity)
						))
					}
				}
			}
		}
	}

	private var tint: some View {
		section("Toolbar tint") {
			HStack(spacing: 8) {
				Picker("Tint", selection: tintMode) {
					Text("Auto").tag(TintMode.automatic)
					Text("Custom").tag(TintMode.custom)
					Text("Off").tag(TintMode.off)
				}
				.pickerStyle(.segmented)
				.labelsHidden()
				if case .custom = draft.tint {
					ColorPicker("Tint color", selection: $customTint, supportsOpacity: false)
						.labelsHidden()
						.transition(.scale.combined(with: .opacity))
						.onChange(of: customTint) { _, color in
							if let hex = color.navigatorHex {
								update { $0.tint = .custom(hex: hex) }
							}
						}
				}
			}
		}
	}

	private var code: some View {
		VStack(alignment: .leading, spacing: 8) {
			Button {
				withAnimation(.navigatorSnappy) { showsCode.toggle() }
			} label: {
				HStack {
					Text("Custom CSS & script").font(.subheadline.weight(.semibold))
					Spacer()
					Image(systemName: "chevron.right")
						.rotationEffect(.degrees(showsCode ? 90 : 0))
						.foregroundStyle(.secondary)
				}
				.contentShape(Rectangle())
			}
			.buttonStyle(.plain)

			if showsCode {
				CodeEditor(text: binding(\.css, debounced: true), placeholder: "/* CSS for \(draft.name) */")
					.frame(height: 110)
				Toggle(isOn: binding(\.allowsJavaScript)) {
					VStack(alignment: .leading, spacing: 1) {
						Text("Run JavaScript on this site").font(.callout)
						Text("Runs with full access to the page. Only paste code you trust.")
							.font(.caption2)
							.foregroundStyle(.secondary)
					}
				}
				.toggleStyle(.switch)
				.controlSize(.mini)
				if draft.allowsJavaScript {
					CodeEditor(text: binding(\.javascript, debounced: true), placeholder: "// runs once per page load")
						.frame(height: 90)
						.transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
				}
			}
		}
	}

	private var footer: some View {
		HStack {
			Button("Open in Editor") {
				let folder = store.folder(for: draft.id)
				try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
				if draft.isEmpty == false { store.save(draft) }
				NSWorkspace.shared.activateFileViewerSelecting([folder])
			}
			.help("Reveal this site's boost folder; edits there apply live")
			Spacer()
			if store.boost(id: draft.id) != nil {
				Button("Reset Site", role: .destructive) {
					store.delete(id: draft.id)
					withAnimation(.navigatorSnappy) { draft = .forSite(draft.name) }
				}
			}
			Button("Done", action: close)
				.keyboardShortcut(.defaultAction)
		}
		.controlSize(.small)
		.buttonStyle(.borderless)
	}

	// MARK: Helpers

	private func section<Content: View>(
		_ title: String,
		@ViewBuilder content: () -> Content
	) -> some View {
		section(title, trailing: { EmptyView() }, content: content)
	}

	private func section<Trailing: View, Content: View>(
		_ title: String,
		@ViewBuilder trailing: () -> Trailing,
		@ViewBuilder content: () -> Content
	) -> some View {
		VStack(alignment: .leading, spacing: 8) {
			HStack {
				Text(title).font(.subheadline.weight(.semibold))
				Spacer()
				trailing()
			}
			content()
		}
	}

	private enum TintMode: Hashable { case automatic, custom, off }

	private var tintMode: Binding<TintMode> {
		Binding {
			switch draft.tint {
			case .automatic: .automatic
			case .custom: .custom
			case .off: .off
			}
		} set: { mode in
			update { boost in
				switch mode {
				case .automatic: boost.tint = .automatic
				case .off: boost.tint = .off
				case .custom: boost.tint = .custom(hex: customTint.navigatorHex ?? "#0A84FF")
				}
			}
		}
	}

	private func binding<Value>(_ keyPath: WritableKeyPath<Boost, Value>, debounced: Bool = false) -> Binding<Value> {
		Binding {
			draft[keyPath: keyPath]
		} set: { value in
			draft[keyPath: keyPath] = value
			if debounced {
				scheduleSave()
			}
			else {
				commit()
			}
		}
	}

	private func update(_ transform: (inout Boost) -> Void) {
		withAnimation(.navigatorSnappy) { transform(&draft) }
		commit()
	}

	private func scheduleSave() {
		saveTask?.cancel()
		saveTask = Task { @MainActor in
			try? await Task.sleep(for: .milliseconds(350))
			guard Task.isCancelled == false else { return }
			commit()
		}
	}

	private func commit() {
		saveTask?.cancel()
		// Don't litter the Boosts folder with empty sites the user only peeked at.
		if draft.isEmpty, store.boost(id: draft.id) == nil, draft.isEnabled { return }
		store.save(draft)
		refreshMatchCounts()
	}

	private func refreshMatchCounts() {
		let selectors = draft.zaps
		Task { @MainActor in
			var counts: [String: Int] = [:]
			for selector in selectors {
				if let count = await actions.countMatches(selector) { counts[selector] = count }
			}
			withAnimation(.navigatorSnappy) { matchCounts = counts }
		}
	}

	private func close() {
		commit()
		withAnimation(.navigatorSnappy) { appeared = false }
		Task { @MainActor in
			try? await Task.sleep(for: .milliseconds(180))
			actions.dismiss()
		}
	}
}

/// Monospaced editor with a placeholder, on a recessed background.
struct CodeEditor: View {
	@Binding var text: String
	let placeholder: String

	var body: some View {
		ZStack(alignment: .topLeading) {
			TextEditor(text: $text)
				.font(.system(size: 11.5, design: .monospaced))
				.scrollContentBackground(.hidden)
				.autocorrectionDisabled()
				.padding(6)
			if text.isEmpty {
				Text(placeholder)
					.font(.system(size: 11.5, design: .monospaced))
					.foregroundStyle(.tertiary)
					.padding(.horizontal, 11)
					.padding(.vertical, 6)
					.allowsHitTesting(false)
			}
		}
		.background(.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
		.overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.white.opacity(0.08)))
	}
}

/// Wrapping row layout for preset chips.
struct FlowLayout: Layout {
	var spacing: CGFloat = 6

	func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
		let rows = arrange(subviews: subviews, width: proposal.width ?? .infinity)
		let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1))
		let width = rows.map(\.width).max() ?? 0
		return CGSize(width: proposal.width ?? width, height: height)
	}

	func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
		var y = bounds.minY
		for row in arrange(subviews: subviews, width: bounds.width) {
			var x = bounds.minX
			for index in row.indices {
				let size = subviews[index].sizeThatFits(.unspecified)
				subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
				x += size.width + spacing
			}
			y += row.height + spacing
		}
	}

	private struct Row {
		var indices: [Int] = []
		var width: CGFloat = 0
		var height: CGFloat = 0
	}

	private func arrange(subviews: Subviews, width: CGFloat) -> [Row] {
		var rows: [Row] = [Row()]
		for index in subviews.indices {
			let size = subviews[index].sizeThatFits(.unspecified)
			let proposedWidth = rows[rows.count - 1].width + (rows[rows.count - 1].indices.isEmpty ? 0 : spacing) + size.width
			if proposedWidth > width, rows[rows.count - 1].indices.isEmpty == false {
				rows.append(Row())
			}
			let gap = rows[rows.count - 1].indices.isEmpty ? 0 : spacing
			rows[rows.count - 1].indices.append(index)
			rows[rows.count - 1].width += gap + size.width
			rows[rows.count - 1].height = max(rows[rows.count - 1].height, size.height)
		}
		return rows.filter { $0.indices.isEmpty == false }
	}
}

extension Color {
	/// sRGB `#RRGGBB`, or nil if the color can't be converted.
	var navigatorHex: String? {
		guard let srgb = NSColor(self).usingColorSpace(.sRGB) else { return nil }
		let r = Int((srgb.redComponent * 255).rounded())
		let g = Int((srgb.greenComponent * 255).rounded())
		let b = Int((srgb.blueComponent * 255).rounded())
		return String(format: "#%02X%02X%02X", r, g, b)
	}
}

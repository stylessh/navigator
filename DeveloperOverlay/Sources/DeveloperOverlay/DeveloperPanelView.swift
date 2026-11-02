import AppKit
import SwiftUI

struct DeveloperPanelView: View {
	@Bindable var model: DeveloperOverlayModel
	@Namespace private var tabNamespace

	var body: some View {
		VStack(spacing: 0) {
			header
			Divider().opacity(0.5)
			ZStack {
				switch model.selectedTab {
				case .console:
					DeveloperConsoleView(model: model)
						.transition(.opacity.combined(with: .offset(x: -12)))
				case .network:
					DeveloperNetworkView(model: model)
						.transition(.opacity.combined(with: .offset(x: 12)))
				case .element:
					DeveloperElementView(model: model)
						.transition(.opacity.combined(with: .offset(x: 12)))
				}
			}
			.frame(maxWidth: .infinity, maxHeight: .infinity)
			.animation(DeveloperMotion.snappy, value: model.selectedTab)
		}
	}

	private var header: some View {
		HStack(spacing: 4) {
			ForEach(DeveloperOverlayTab.allCases) { tab in
				Button {
					withAnimation(DeveloperMotion.snappy) { model.select(tab) }
				} label: {
					HStack(spacing: 5) {
						Image(systemName: tab.symbolName)
							.font(.system(size: 11, weight: .semibold))
						Text(tab.title)
							.font(.system(size: 12, weight: .medium))
						if let count = badgeCount(for: tab), count > 0 {
							Text("\(count)")
								.font(.system(size: 10, weight: .semibold).monospacedDigit())
								.padding(.horizontal, 5)
								.padding(.vertical, 1)
								.background(Capsule().fill(badgeColor(for: tab).opacity(0.2)))
								.foregroundStyle(badgeColor(for: tab))
								.contentTransition(.numericText())
						}
					}
					.padding(.horizontal, 10)
					.frame(height: 28)
					.foregroundStyle(model.selectedTab == tab ? Color.primary : Color.secondary)
					.background {
						if model.selectedTab == tab {
							Capsule()
								.fill(Color.primary.opacity(0.1))
								.matchedGeometryEffect(id: "tab", in: tabNamespace)
						}
					}
					.contentShape(Capsule())
				}
				.buttonStyle(DeveloperPressStyle())
			}
			Spacer(minLength: 4)
			DeveloperIconButton(systemImage: "trash", help: "Clear", size: 26) {
				withAnimation(DeveloperMotion.rows) {
					switch model.selectedTab {
					case .console: model.clearConsole()
					case .network: model.clearNetwork()
					case .element: model.clearInspectedElement()
					}
				}
			}
			DeveloperIconButton(systemImage: "xmark", help: "Close (⌥⌘I)", size: 26) {
				model.isPanelPresented = false
			}
		}
		.padding(8)
	}

	private func badgeCount(for tab: DeveloperOverlayTab) -> Int? {
		switch tab {
		case .console: model.errorCount + model.warningCount
		case .network: model.failedRequestCount
		case .element: nil
		}
	}

	private func badgeColor(for tab: DeveloperOverlayTab) -> Color {
		switch tab {
		case .console: model.errorCount > 0 ? .red : .orange
		case .network: .red
		case .element: .accentColor
		}
	}
}

// MARK: - Console

struct DeveloperConsoleView: View {
	@Bindable var model: DeveloperOverlayModel
	@State private var prompt = ""
	@State private var history: [String] = []
	@State private var historyIndex: Int?
	@FocusState private var isPromptFocused: Bool

	var body: some View {
		VStack(spacing: 0) {
			filterBar
			Divider().opacity(0.4)
			let entries = model.filteredConsoleEntries
			if entries.isEmpty {
				DeveloperEmptyState(
					symbol: "terminal",
					title: "No messages",
					message: "console.log, warnings, errors and uncaught exceptions from this page show up here."
				)
			}
			else {
				ScrollViewReader { proxy in
					ScrollView {
						LazyVStack(alignment: .leading, spacing: 0) {
							ForEach(entries) { entry in
								DeveloperConsoleRow(entry: entry)
									.id(entry.id)
									.transition(.move(edge: .bottom).combined(with: .opacity))
							}
						}
						.animation(DeveloperMotion.rows, value: entries.count)
					}
					.onChange(of: entries.last?.id) { _, lastID in
						guard let lastID else { return }
						withAnimation(DeveloperMotion.rows) { proxy.scrollTo(lastID, anchor: .bottom) }
					}
					.onAppear {
						if let lastID = entries.last?.id { proxy.scrollTo(lastID, anchor: .bottom) }
					}
				}
			}
			Divider().opacity(0.4)
			promptField
		}
	}

	private var filterBar: some View {
		HStack(spacing: 6) {
			HStack(spacing: 4) {
				Image(systemName: "line.3.horizontal.decrease")
					.font(.system(size: 10, weight: .semibold))
					.foregroundStyle(.secondary)
				TextField("Filter", text: $model.consoleFilter.text)
					.textFieldStyle(.plain)
					.font(.system(size: 11))
			}
			.padding(.horizontal, 8)
			.frame(height: 24)
			.background(Capsule().fill(Color.primary.opacity(0.06)))

			levelToggle("Logs", isOn: $model.consoleFilter.showsLogs, color: .secondary)
			levelToggle("Warn", isOn: $model.consoleFilter.showsWarnings, color: .orange)
			levelToggle("Errors", isOn: $model.consoleFilter.showsErrors, color: .red)
		}
		.padding(.horizontal, 8)
		.padding(.vertical, 6)
	}

	private func levelToggle(_ title: String, isOn: Binding<Bool>, color: Color) -> some View {
		Button {
			withAnimation(DeveloperMotion.snappy) { isOn.wrappedValue.toggle() }
		} label: {
			Text(title)
				.font(.system(size: 10, weight: .semibold))
				.padding(.horizontal, 7)
				.frame(height: 22)
				.foregroundStyle(isOn.wrappedValue ? color : Color.secondary.opacity(0.6))
				.background(Capsule().fill(isOn.wrappedValue ? color.opacity(0.15) : Color.clear))
				.overlay(Capsule().stroke(Color.primary.opacity(isOn.wrappedValue ? 0 : 0.12), lineWidth: 0.5))
				.contentShape(Capsule())
		}
		.buttonStyle(DeveloperPressStyle())
	}

	private var promptField: some View {
		HStack(alignment: .firstTextBaseline, spacing: 6) {
			Image(systemName: "chevron.right")
				.font(.system(size: 10, weight: .bold))
				.foregroundStyle(Color.accentColor)
			TextField("Evaluate JavaScript", text: $prompt)
				.textFieldStyle(.plain)
				.font(.system(size: 12, design: .monospaced))
				.focused($isPromptFocused)
				.onSubmit(submit)
				.onKeyPress(.upArrow) {
					recall(offset: -1)
					return .handled
				}
				.onKeyPress(.downArrow) {
					recall(offset: 1)
					return .handled
				}
		}
		.padding(.horizontal, 12)
		.padding(.vertical, 10)
	}

	private func submit() {
		let source = prompt
		guard source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else { return }
		if history.last != source {
			history.append(source)
		}
		historyIndex = nil
		prompt = ""
		model.evaluate(source)
		isPromptFocused = true
	}

	private func recall(offset: Int) {
		guard history.isEmpty == false else { return }
		let current = historyIndex ?? history.count
		let next = min(max(0, current + offset), history.count)
		historyIndex = next
		prompt = next == history.count ? "" : history[next]
	}
}

struct DeveloperConsoleRow: View {
	let entry: DeveloperConsoleEntry

	var body: some View {
		if entry.level == .system {
			HStack(spacing: 8) {
				Rectangle().fill(Color.primary.opacity(0.12)).frame(height: 1)
				Text(entry.text)
					.font(.system(size: 10, weight: .medium))
					.foregroundStyle(.secondary)
				Rectangle().fill(Color.primary.opacity(0.12)).frame(height: 1)
			}
			.padding(.horizontal, 12)
			.padding(.vertical, 6)
		}
		else {
			HStack(alignment: .firstTextBaseline, spacing: 8) {
				Image(systemName: symbol)
					.font(.system(size: 9, weight: .bold))
					.foregroundStyle(color)
					.frame(width: 12)
				Text(entry.text)
					.font(.system(size: 11.5, design: .monospaced))
					.foregroundStyle(textColor)
					.textSelection(.enabled)
					.frame(maxWidth: .infinity, alignment: .leading)
					.lineLimit(12)
				if entry.repeatCount > 1 {
					Text("\(entry.repeatCount)")
						.font(.system(size: 9, weight: .bold).monospacedDigit())
						.padding(.horizontal, 5)
						.padding(.vertical, 1)
						.background(Capsule().fill(color.opacity(0.2)))
						.foregroundStyle(color)
						.contentTransition(.numericText())
				}
				if let source = entry.source {
					Text(source)
						.font(.system(size: 10))
						.foregroundStyle(.tertiary)
						.lineLimit(1)
				}
			}
			.padding(.horizontal, 12)
			.padding(.vertical, 5)
			.background(background)
			.contextMenu {
				Button("Copy Message") {
					NSPasteboard.general.clearContents()
					NSPasteboard.general.setString(entry.text, forType: .string)
				}
			}
		}
	}

	private var symbol: String {
		switch entry.level {
		case .error: "xmark.octagon.fill"
		case .warn: "exclamationmark.triangle.fill"
		case .info: "info.circle.fill"
		case .debug: "ant.fill"
		case .input: "chevron.right"
		case .result: "chevron.left"
		case .log, .system: "circle.fill"
		}
	}

	private var color: Color {
		switch entry.level {
		case .error: .red
		case .warn: .orange
		case .info: .blue
		case .input: .accentColor
		case .debug, .result, .log, .system: .secondary
		}
	}

	private var textColor: Color {
		switch entry.level {
		case .error: .red
		case .warn: Color(nsColor: .systemOrange)
		case .result: .secondary
		default: .primary
		}
	}

	@ViewBuilder
	private var background: some View {
		switch entry.level {
		case .error: Color.red.opacity(0.08)
		case .warn: Color.orange.opacity(0.08)
		default: Color.clear
		}
	}
}

// MARK: - Network

struct DeveloperNetworkView: View {
	@Bindable var model: DeveloperOverlayModel
	@State private var expandedID: String?

	var body: some View {
		VStack(spacing: 0) {
			HStack(spacing: 4) {
				ForEach(DeveloperOverlayModel.NetworkFilter.allCases) { filter in
					Button {
						withAnimation(DeveloperMotion.snappy) { model.networkFilter = filter }
					} label: {
						Text(filter.title)
							.font(.system(size: 10.5, weight: .semibold))
							.padding(.horizontal, 8)
							.frame(height: 22)
							.foregroundStyle(model.networkFilter == filter ? Color.primary : Color.secondary)
							.background(Capsule().fill(Color.primary.opacity(model.networkFilter == filter ? 0.1 : 0)))
							.contentShape(Capsule())
					}
					.buttonStyle(DeveloperPressStyle())
				}
				Spacer()
			}
			.padding(.horizontal, 8)
			.padding(.vertical, 6)
			Divider().opacity(0.4)

			let entries = model.filteredNetworkEntries
			if entries.isEmpty {
				DeveloperEmptyState(
					symbol: "arrow.up.arrow.down",
					title: "No requests",
					message: "Documents, scripts, styles, images, fetch and XHR calls for this page appear here as they happen."
				)
			}
			else {
				let bounds = model.networkTimelineBounds
				ScrollView {
					LazyVStack(spacing: 0) {
						ForEach(entries) { entry in
							DeveloperNetworkRow(
								entry: entry,
								timeline: bounds,
								isExpanded: expandedID == entry.id
							)
							.onTapGesture {
								withAnimation(DeveloperMotion.snappy) {
									expandedID = expandedID == entry.id ? nil : entry.id
								}
							}
							.transition(.move(edge: .bottom).combined(with: .opacity))
						}
					}
					.animation(DeveloperMotion.rows, value: entries.count)
				}
			}

			Divider().opacity(0.4)
			HStack(spacing: 12) {
				Text("\(model.networkEntries.count) requests")
				Text(DeveloperFormat.bytes(model.totalTransferSize) + " transferred")
				if model.failedRequestCount > 0 {
					Text("\(model.failedRequestCount) failed").foregroundStyle(.red)
				}
				Spacer()
			}
			.font(.system(size: 10.5).monospacedDigit())
			.foregroundStyle(.secondary)
			.contentTransition(.numericText())
			.padding(.horizontal, 12)
			.padding(.vertical, 8)
		}
	}
}

struct DeveloperNetworkRow: View {
	let entry: DeveloperNetworkEntry
	let timeline: ClosedRange<Double>
	let isExpanded: Bool

	var body: some View {
		VStack(alignment: .leading, spacing: 4) {
			HStack(spacing: 8) {
				statusBadge
				VStack(alignment: .leading, spacing: 1) {
					Text(entry.displayName)
						.font(.system(size: 11.5, weight: .medium))
						.lineLimit(1)
						.truncationMode(.middle)
					HStack(spacing: 6) {
						Text(entry.method)
						Text(entry.kind.label)
						if let host = entry.host { Text(host).lineLimit(1) }
					}
					.font(.system(size: 9.5))
					.foregroundStyle(.secondary)
				}
				Spacer(minLength: 4)
				VStack(alignment: .trailing, spacing: 1) {
					Text(entry.duration.map(DeveloperFormat.milliseconds) ?? "…")
						.font(.system(size: 10.5, weight: .medium).monospacedDigit())
					Text(entry.transferSize.map(DeveloperFormat.bytes) ?? "–")
						.font(.system(size: 9.5).monospacedDigit())
						.foregroundStyle(.secondary)
				}
			}
			waterfall
			if isExpanded {
				VStack(alignment: .leading, spacing: 4) {
					Text(entry.url)
						.font(.system(size: 10.5, design: .monospaced))
						.textSelection(.enabled)
						.lineLimit(4)
					if let mime = entry.mimeType {
						Text(mime).font(.system(size: 10)).foregroundStyle(.secondary)
					}
					if let error = entry.errorText {
						Text(error).font(.system(size: 10)).foregroundStyle(.red)
					}
					HStack {
						Button("Copy URL") { copy(entry.url) }
						Button("Copy as cURL") { copy("curl -X \(entry.method) '\(entry.url)'") }
					}
					.controlSize(.small)
					.buttonStyle(.borderless)
				}
				.transition(.opacity.combined(with: .move(edge: .top)))
			}
		}
		.padding(.horizontal, 12)
		.padding(.vertical, 6)
		.background(entry.isFailure ? Color.red.opacity(0.07) : Color.clear)
		.contentShape(Rectangle())
		.help(entry.url)
	}

	private var statusBadge: some View {
		let text: String
		let color: Color
		if entry.isPending {
			text = "···"
			color = .secondary
		}
		else if let error = entry.errorText, entry.status == nil || entry.status == 0 {
			text = error == "Aborted" ? "ABT" : "ERR"
			color = .red
		}
		else if let status = entry.status, status > 0 {
			text = "\(status)"
			color = switch status {
			case ..<300: .green
			case ..<400: .blue
			case ..<500: .orange
			default: .red
			}
		}
		else {
			text = "—"
			color = .secondary
		}
		return Text(text)
			.font(.system(size: 9.5, weight: .bold).monospacedDigit())
			.foregroundStyle(color)
			.frame(width: 34, height: 18)
			.background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(color.opacity(0.14)))
	}

	private var waterfall: some View {
		GeometryReader { proxy in
			let span = max(1, timeline.upperBound - timeline.lowerBound)
			let startFraction = (entry.startTime - timeline.lowerBound) / span
			let widthFraction = max(0.006, (entry.duration ?? (timeline.upperBound - entry.startTime)) / span)
			Capsule()
				.fill(barColor.gradient)
				.frame(width: max(3, proxy.size.width * widthFraction), height: 3)
				.offset(x: proxy.size.width * startFraction)
				.opacity(entry.isPending ? 0.5 : 1)
		}
		.frame(height: 3)
		.animation(DeveloperMotion.rows, value: entry.duration)
	}

	private var barColor: Color {
		switch entry.kind {
		case .document: .blue
		case .fetch, .xhr: .purple
		case .script: .orange
		case .stylesheet: .teal
		case .image, .media: .green
		case .font: .pink
		case .other: .gray
		}
	}

	private func copy(_ string: String) {
		NSPasteboard.general.clearContents()
		NSPasteboard.general.setString(string, forType: .string)
	}
}

// MARK: - Element

struct DeveloperElementView: View {
	@Bindable var model: DeveloperOverlayModel

	var body: some View {
		if let element = model.inspectedElement {
			ScrollView {
				VStack(alignment: .leading, spacing: 14) {
					selectorHeader(element)
					DeveloperBoxModelView(element: element)
						.frame(maxWidth: .infinity)
					styles(element)
					if let text = element.textPreview {
						VStack(alignment: .leading, spacing: 4) {
							sectionTitle("Text")
							Text("“\(text)”")
								.font(.system(size: 11))
								.foregroundStyle(.secondary)
								.lineLimit(4)
						}
					}
					Button {
						model.startPicking()
					} label: {
						Label("Pick another element", systemImage: "cursorarrow.rays")
							.font(.system(size: 12, weight: .medium))
							.frame(maxWidth: .infinity)
							.frame(height: 30)
							.background(Capsule().fill(Color.accentColor.opacity(0.15)))
							.foregroundStyle(Color.accentColor)
							.contentShape(Capsule())
					}
					.buttonStyle(DeveloperPressStyle())
				}
				.padding(14)
				.id(element.selector)
				.transition(.opacity.combined(with: .scale(scale: 0.97)))
			}
			.animation(DeveloperMotion.morph, value: element)
		}
		else {
			DeveloperEmptyState(
				symbol: model.isPicking ? "scope" : "cursorarrow.rays",
				title: model.isPicking ? "Click anything on the page" : "No element selected",
				message: model.isPicking
					? "Hover to highlight, click to inspect. Press Esc to cancel."
					: "Pick an element to see its box model, size and key styles. ⌥⌘C works from anywhere.",
				actionTitle: model.isPicking ? "Cancel" : "Pick an element",
				action: { model.toggleInspect() }
			)
		}
	}

	private func selectorHeader(_ element: DeveloperInspectedElement) -> some View {
		VStack(alignment: .leading, spacing: 6) {
			HStack(alignment: .firstTextBaseline) {
				Text(elementLabel(element))
					.font(.system(size: 14, weight: .semibold, design: .monospaced))
					.foregroundStyle(Color.accentColor)
					.lineLimit(1)
				Spacer()
				Text("\(DeveloperFormat.points(element.rect.width)) × \(DeveloperFormat.points(element.rect.height))")
					.font(.system(size: 11, weight: .medium).monospacedDigit())
					.foregroundStyle(.secondary)
					.contentTransition(.numericText())
			}
			HStack(spacing: 6) {
				Text(element.selector)
					.font(.system(size: 10.5, design: .monospaced))
					.foregroundStyle(.secondary)
					.lineLimit(2)
					.textSelection(.enabled)
				Spacer()
				DeveloperIconButton(systemImage: "doc.on.doc", help: "Copy selector", size: 22) {
					NSPasteboard.general.clearContents()
					NSPasteboard.general.setString(element.selector, forType: .string)
				}
			}
		}
	}

	private func styles(_ element: DeveloperInspectedElement) -> some View {
		VStack(alignment: .leading, spacing: 6) {
			sectionTitle("Styles")
			ForEach(DeveloperInspectedElement.displayedStyleKeys, id: \.self) { key in
				if let value = element.styles[key] {
					HStack(alignment: .firstTextBaseline, spacing: 8) {
						Text(key)
							.font(.system(size: 11, design: .monospaced))
							.foregroundStyle(.secondary)
							.frame(width: 78, alignment: .leading)
						if let swatch = DeveloperFormat.color(fromCSS: value) {
							RoundedRectangle(cornerRadius: 3, style: .continuous)
								.fill(swatch)
								.overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.primary.opacity(0.2), lineWidth: 0.5))
								.frame(width: 11, height: 11)
						}
						Text(value)
							.font(.system(size: 11, design: .monospaced))
							.textSelection(.enabled)
							.lineLimit(2)
					}
				}
			}
		}
	}

	private func sectionTitle(_ title: String) -> some View {
		Text(title.uppercased())
			.font(.system(size: 9.5, weight: .semibold))
			.foregroundStyle(.tertiary)
			.tracking(0.6)
	}

	private func elementLabel(_ element: DeveloperInspectedElement) -> String {
		var label = element.tag
		if let id = element.elementID { label += "#\(id)" }
		if let first = element.classes.first { label += ".\(first)" }
		if element.classes.count > 1 { label += " +\(element.classes.count - 1)" }
		return label
	}
}

/// The classic margin / border / padding / content diagram.
struct DeveloperBoxModelView: View {
	let element: DeveloperInspectedElement

	var body: some View {
		layer(
			title: "margin",
			edges: element.margin,
			fill: Color.orange.opacity(0.16),
			stroke: Color.orange.opacity(0.5),
			dashed: true
		) {
			layer(
				title: "border",
				edges: element.border,
				fill: Color.yellow.opacity(0.16),
				stroke: Color.yellow.opacity(0.6),
				dashed: false
			) {
				layer(
					title: "padding",
					edges: element.padding,
					fill: Color.green.opacity(0.16),
					stroke: Color.green.opacity(0.5),
					dashed: true
				) {
					Text("\(DeveloperFormat.points(element.rect.width)) × \(DeveloperFormat.points(element.rect.height))")
						.font(.system(size: 10.5, weight: .semibold).monospacedDigit())
						.padding(.horizontal, 10)
						.padding(.vertical, 6)
						.background(
							RoundedRectangle(cornerRadius: 4, style: .continuous)
								.fill(Color.blue.opacity(0.2))
						)
						.overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.blue.opacity(0.5), lineWidth: 0.5))
				}
			}
		}
		.font(.system(size: 9.5).monospacedDigit())
	}

	private func layer(
		title: String,
		edges: DeveloperInspectedElement.Edges,
		fill: Color,
		stroke: Color,
		dashed: Bool,
		@ViewBuilder content: () -> some View
	) -> some View {
		VStack(spacing: 2) {
			HStack {
				Text(title).foregroundStyle(.secondary)
				Spacer()
				Text(value(edges.top))
				Spacer()
				Text(" ").hidden()
			}
			HStack(spacing: 4) {
				Text(value(edges.left)).frame(minWidth: 16)
				content()
				Text(value(edges.right)).frame(minWidth: 16)
			}
			Text(value(edges.bottom))
		}
		.padding(6)
		.background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(fill))
		.overlay(
			RoundedRectangle(cornerRadius: 6, style: .continuous)
				.stroke(stroke, style: StrokeStyle(lineWidth: 0.75, dash: dashed ? [3, 2] : []))
		)
	}

	private func value(_ number: Double) -> String {
		number == 0 ? "–" : DeveloperFormat.points(number)
	}
}

// MARK: - Shared

struct DeveloperEmptyState: View {
	let symbol: String
	let title: String
	let message: String
	var actionTitle: String?
	var action: (() -> Void)?

	var body: some View {
		VStack(spacing: 10) {
			Image(systemName: symbol)
				.font(.system(size: 26, weight: .light))
				.foregroundStyle(.secondary)
				.symbolEffect(.pulse, options: .repeating, isActive: symbol == "scope")
			Text(title)
				.font(.system(size: 13, weight: .semibold))
			Text(message)
				.font(.system(size: 11))
				.foregroundStyle(.secondary)
				.multilineTextAlignment(.center)
				.frame(maxWidth: 280)
			if let actionTitle, let action {
				Button(action: action) {
					Text(actionTitle)
						.font(.system(size: 12, weight: .medium))
						.padding(.horizontal, 14)
						.frame(height: 28)
						.background(Capsule().fill(Color.accentColor))
						.foregroundStyle(.white)
						.contentShape(Capsule())
				}
				.buttonStyle(DeveloperPressStyle())
				.padding(.top, 4)
			}
		}
		.padding(24)
		.frame(maxWidth: .infinity, maxHeight: .infinity)
		.transition(.opacity.combined(with: .scale(scale: 0.96)))
	}
}

enum DeveloperFormat {
	static func bytes(_ count: Int) -> String {
		ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file)
	}

	static func milliseconds(_ value: Double) -> String {
		value >= 1000 ? String(format: "%.2f s", value / 1000) : String(format: "%.0f ms", value)
	}

	static func points(_ value: Double) -> String {
		value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value)
	}

	/// Parses `rgb(…)` / `rgba(…)` from computed styles into a swatch color.
	static func color(fromCSS value: String) -> Color? {
		guard let open = value.firstIndex(of: "("), let close = value.lastIndex(of: ")") else { return nil }
		let prefix = value[..<open].trimmingCharacters(in: .whitespaces)
		guard prefix == "rgb" || prefix == "rgba" else { return nil }
		let components = value[value.index(after: open)..<close]
			.replacingOccurrences(of: "/", with: ",")
			.split(whereSeparator: { $0 == "," || $0 == " " })
			.compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
		guard components.count >= 3 else { return nil }
		let alpha = components.count >= 4 ? components[3] : 1
		guard alpha > 0 else { return nil }
		return Color(
			.sRGB,
			red: components[0] / 255,
			green: components[1] / 255,
			blue: components[2] / 255,
			opacity: alpha
		)
	}
}

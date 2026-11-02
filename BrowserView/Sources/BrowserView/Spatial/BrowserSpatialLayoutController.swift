import AppKit
import BrowserSidebar
import Vendors

/// What the spatial layout controller needs from `BrowserChromeView`.
@MainActor
struct BrowserSpatialLayoutHooks {
	var tabs: () -> [BrowserTabViewModel]
	var selectedTabID: () -> BrowserTabID?
	var container: (BrowserTabID) -> BrowserContainerView?
	var selectTab: (BrowserTabID) -> Void
	var closeTab: (BrowserTabID) -> Void
	var moveTab: (BrowserTabID, BrowserTabID) -> Void
	/// Makes a non-selected pane's browser live and protects it from eviction (or releases it).
	var setPaneLive: (BrowserTabID, Bool) -> Void
	/// Re-runs container visibility for the current selection.
	var refreshVisibility: () -> Void
}

/// Owns the experimental tab overview and split panes for one browser window.
@MainActor
final class BrowserSpatialLayoutController: NSObject {
	private static let splitDefaultsKey = "navigator.spatial.splitLayouts"
	private static let snapshotMaxWidth: CGFloat = 900

	let hostView = BrowserSpatialHostView()
	private weak var overlayParent: NSView?
	private let hooks: BrowserSpatialLayoutHooks
	private let experiments: NavigatorExperiments
	private let defaults: UserDefaults

	/// Every split the user has made. A split is shown when its tab is selected.
	private(set) var splits: [SpatialSplitLayout<BrowserTabID>]
	private var livePaneIDs = Set<BrowserTabID>()
	private var snapshots = [BrowserTabID: CGImage]()
	private var overview: SpatialTabOverviewView?
	private var pinch: SpatialPinchInterpreter?
	private var eventMonitor: Any?

	init(
		hooks: BrowserSpatialLayoutHooks,
		experiments: NavigatorExperiments = .shared,
		defaults: UserDefaults = .standard
	) {
		self.hooks = hooks
		self.experiments = experiments
		self.defaults = defaults
		splits = Self.loadSplits(from: defaults)
		super.init()
		hostView.paneFrames = { [weak self] bounds in
			self?.activeSplit?.paneFrames(in: bounds, gap: BrowserSpatialHostView.paneGap) ?? [:]
		}
		hostView.dividers = { [weak self] bounds in
			self?.activeSplit?.dividers(in: bounds, gap: BrowserSpatialHostView.paneGap) ?? []
		}
		hostView.focusedPaneID = { [weak self] in
			self?.hooks.selectedTabID()
		}
		hostView.onDividerDrag = { [weak self] divider, location in
			self?.updateActiveSplit(animated: false) { split in
				split.setRatio(SpatialSplitLayout<BrowserTabID>.ratio(for: location, divider: divider, gap: BrowserSpatialHostView.paneGap), at: divider.path)
			}
		}
		hostView.onDividerReset = { [weak self] divider in
			self?.updateActiveSplit(animated: true) { split in
				split.setRatio(0.5, at: divider.path)
			}
		}
	}

	var isOverviewEnabled: Bool {
		experiments.isEnabled(.spatialTabOverview)
	}

	var isSplitEnabled: Bool {
		experiments.isEnabled(.spatialSplitPanes)
	}

	var isOverviewPresented: Bool {
		overview != nil
	}

	/// The split containing the selected tab, if any.
	var activeSplit: SpatialSplitLayout<BrowserTabID>? {
		guard isSplitEnabled, let selected = hooks.selectedTabID() else { return nil }
		return splits.first { $0.contains(selected) }
	}

	/// Tabs that must stay visible alongside the selected tab.
	func visiblePaneIDs(selected: BrowserTabID) -> Set<BrowserTabID> {
		guard let split = activeSplit, split.contains(selected) else { return [] }
		return Set(split.paneIDs)
	}

	// MARK: Lifecycle

	func attach(overlayParent: NSView) {
		self.overlayParent = overlayParent
		installEventMonitor()
	}

	func detach() {
		if let eventMonitor {
			NSEvent.removeMonitor(eventMonitor)
		}
		eventMonitor = nil
		overview?.removeFromSuperview()
		overview = nil
	}

	/// Call after tabs are added/removed so splits drop closed tabs.
	func tabsDidChange() {
		let liveIDs = Set(hooks.tabs().map(\.id))
		var changed = false
		splits = splits.compactMap { split in
			var next: SpatialSplitLayout<BrowserTabID>? = split
			for id in split.paneIDs where liveIDs.contains(id) == false {
				next = next?.removing(id)
				changed = true
			}
			guard let next, next.isSplit else {
				if split.isSplit { changed = true }
				return nil
			}
			return next
		}
		snapshots = snapshots.filter { liveIDs.contains($0.key) }
		if changed {
			persist()
		}
		syncLivePanes()
		if let overview {
			overview.setItems(overviewItems(), pageAspectRatio: pageAspectRatio)
		}
	}

	/// Call when the selection changes, before the previous tab's container is hidden.
	func selectionWillChange(from previous: BrowserTabID?) {
		guard let previous else { return }
		captureSnapshot(for: previous)
	}

	/// Call after container visibility was applied for a new selection.
	func selectionDidChange() {
		syncLivePanes()
		hostView.setNeedsSpatialLayout(animated: true)
	}

	func registerContainer(_ container: BrowserContainerView, for tabID: BrowserTabID) {
		hostView.addContainer(container, for: tabID)
	}

	func unregisterContainer(for tabID: BrowserTabID) {
		hostView.removeContainer(for: tabID)
	}

	private func syncLivePanes() {
		let selected = hooks.selectedTabID()
		let next = selected.map { visiblePaneIDs(selected: $0) } ?? []
		for id in livePaneIDs.subtracting(next) {
			hooks.setPaneLive(id, false)
		}
		for id in next.subtracting(livePaneIDs) where id != selected {
			hooks.setPaneLive(id, true)
		}
		livePaneIDs = next
	}

	// MARK: Splits

	/// ⌘⌥\ — split the current tab with the previously used one, or unsplit.
	func toggleSplitWithAdjacentTab() {
		guard isSplitEnabled, let selected = hooks.selectedTabID() else { return }
		if let index = splits.firstIndex(where: { $0.contains(selected) }) {
			let split = splits[index]
			if let next = split.removing(selected), next.isSplit {
				splits[index] = next
			}
			else {
				splits.remove(at: index)
			}
			commitSplitChange()
			return
		}
		let tabs = hooks.tabs()
		guard let selectedIndex = tabs.firstIndex(where: { $0.id == selected }) else { return }
		let candidates = tabs.indices
			.filter { $0 != selectedIndex }
			.sorted { abs($0 - selectedIndex) < abs($1 - selectedIndex) }
			.map { tabs[$0].id }
			.filter { id in splits.contains { $0.contains(id) } == false }
		guard let partner = candidates.first else { return }
		split(partner, into: selected, edge: .right)
	}

	/// Places `tabID` against `edge` of `targetID`'s pane, creating or extending a split.
	func split(_ tabID: BrowserTabID, into targetID: BrowserTabID, edge: SpatialSplitEdge) {
		guard isSplitEnabled, tabID != targetID else { return }
		// A tab lives in at most one split.
		splits = splits.compactMap { split in
			guard split.contains(tabID), split.contains(targetID) == false else { return split }
			guard let next = split.removing(tabID), next.isSplit else { return nil }
			return next
		}
		if let index = splits.firstIndex(where: { $0.contains(targetID) }) {
			var split = splits[index]
			if split.contains(tabID) {
				if let removed = split.removing(tabID) {
					split = removed
				}
			}
			guard split.insert(tabID, adjacentTo: targetID, edge: edge) else { return }
			splits[index] = split
		}
		else {
			splits.append(SpatialSplitLayout(targetID, adding: tabID, edge: edge))
		}
		commitSplitChange()
		if hooks.selectedTabID() != targetID, hooks.selectedTabID() != tabID {
			hooks.selectTab(targetID)
		}
	}

	/// ⌘⌥ arrows — move focus between panes.
	func focusPane(_ direction: SpatialDirection) {
		guard let split = activeSplit, let selected = hooks.selectedTabID(),
		      let next = split.neighbor(of: selected, direction: direction, in: hostView.bounds)
		else { return }
		hooks.selectTab(next)
	}

	func equalizeActiveSplit() {
		updateActiveSplit(animated: true) { $0.equalize() }
	}

	private func updateActiveSplit(animated: Bool, _ change: (inout SpatialSplitLayout<BrowserTabID>) -> Void) {
		guard let selected = hooks.selectedTabID(), let index = splits.firstIndex(where: { $0.contains(selected) }) else { return }
		change(&splits[index])
		persist()
		hostView.setNeedsSpatialLayout(animated: animated)
	}

	private func commitSplitChange() {
		persist()
		hooks.refreshVisibility()
		syncLivePanes()
		hostView.setNeedsSpatialLayout(animated: true)
	}

	/// Focus follows clicks into another pane of the active split.
	private func handleMouseDown(_ event: NSEvent) {
		guard let split = activeSplit, event.window == hostView.window else { return }
		let point = hostView.convert(event.locationInWindow, from: nil)
		let frames = split.paneFrames(in: hostView.bounds, gap: BrowserSpatialHostView.paneGap)
		guard let hit = frames.first(where: { $0.value.contains(point) })?.key, hit != hooks.selectedTabID() else { return }
		hooks.selectTab(hit)
	}

	// MARK: Overview

	func toggleOverview() {
		if let overview {
			overview.dismiss(choosing: hooks.selectedTabID())
		}
		else {
			presentOverview(interactive: false)
		}
	}

	private func presentOverview(interactive: Bool) {
		guard isOverviewEnabled, overview == nil, let overlayParent else { return }
		captureVisibleSnapshots()
		let overview = SpatialTabOverviewView()
		overview.delegate = self
		overview.frame = overlayParent.bounds
		overview.autoresizingMask = [.width, .height]
		overlayParent.addSubview(overview, positioned: .above, relativeTo: nil)
		overview.setItems(overviewItems(), pageAspectRatio: pageAspectRatio)
		self.overview = overview
		overview.present(interactive: interactive)
	}

	private var pageAspectRatio: CGFloat {
		let size = hostView.bounds.size
		guard size.width > 0, size.height > 0 else { return 16 / 10 }
		return size.width / size.height
	}

	private func overviewItems() -> [SpatialOverviewItem] {
		let selected = hooks.selectedTabID()
		let splitIDs = Set(splits.flatMap(\.paneIDs))
		return hooks.tabs().map { tab in
			SpatialOverviewItem(
				id: tab.id,
				title: tab.displayTitle,
				url: tab.currentURL,
				snapshot: snapshots[tab.id],
				isSelected: tab.id == selected,
				isInSplit: splitIDs.contains(tab.id)
			)
		}
	}

	private func captureVisibleSnapshots() {
		guard let selected = hooks.selectedTabID() else { return }
		var ids = visiblePaneIDs(selected: selected)
		ids.insert(selected)
		for id in ids {
			captureSnapshot(for: id)
		}
	}

	private func captureSnapshot(for tabID: BrowserTabID) {
		guard isOverviewEnabled, let container = hooks.container(tabID), let image = container.captureSpatialSnapshot() else { return }
		snapshots[tabID] = Self.downscaled(image, maxWidth: Self.snapshotMaxWidth * (hostView.window?.backingScaleFactor ?? 2) / 2)
	}

	private static func downscaled(_ image: CGImage, maxWidth: CGFloat) -> CGImage {
		let width = CGFloat(image.width)
		guard width > maxWidth, maxWidth > 0 else { return image }
		let scale = maxWidth / width
		let size = CGSize(width: (width * scale).rounded(), height: (CGFloat(image.height) * scale).rounded())
		guard let context = CGContext(
			data: nil,
			width: Int(size.width),
			height: Int(size.height),
			bitsPerComponent: 8,
			bytesPerRow: 0,
			space: image.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
			bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
		) else {
			return image
		}
		context.interpolationQuality = .medium
		context.draw(image, in: CGRect(origin: .zero, size: size))
		return context.makeImage() ?? image
	}

	// MARK: Events

	private func installEventMonitor() {
		guard eventMonitor == nil else { return }
		// Local monitors run on the main thread; the closure is formed in a main-actor context,
		// matching how BrowserChromeView installs its own monitors.
		let handler: (NSEvent) -> NSEvent? = { [weak self] event in
			guard let self else { return event }
			return self.handle(event)
		}
		eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.magnify, .keyDown, .leftMouseDown], handler: handler)
	}

	private func handle(_ event: NSEvent) -> NSEvent? {
		guard event.window != nil, event.window == hostView.window else { return event }
		switch event.type {
		case .keyDown:
			return handleKeyDown(event)
		case .magnify:
			return handleMagnify(event)
		case .leftMouseDown:
			if overview == nil {
				handleMouseDown(event)
			}
			return event
		default:
			return event
		}
	}

	private func handleKeyDown(_ event: NSEvent) -> NSEvent? {
		let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
		let isBackslash = event.keyCode == 42
		if isBackslash, modifiers == [.command, .shift], isOverviewEnabled {
			toggleOverview()
			return nil
		}
		guard overview == nil else { return event }
		if isBackslash, modifiers == [.command, .option], isSplitEnabled {
			toggleSplitWithAdjacentTab()
			return nil
		}
		if modifiers == [.command, .option], activeSplit != nil {
			switch event.keyCode {
			case 123: focusPane(.left); return nil
			case 124: focusPane(.right); return nil
			case 125: focusPane(.down); return nil
			case 126: focusPane(.up); return nil
			case 24: equalizeActiveSplit(); return nil // ⌘⌥=
			default: break
			}
		}
		return event
	}

	private func handleMagnify(_ event: NSEvent) -> NSEvent? {
		guard isOverviewEnabled else { return event }
		if let overview, pinch == nil {
			// Inside the overview: spreading fingers over a card opens it.
			if event.phase == .began || event.phase == .changed, event.magnification > 0.04 {
				overview.handleZoomInGesture(at: event.locationInWindow)
			}
			return nil
		}
		switch event.phase {
		case .began:
			pinch = nil
			return event
		case .changed:
			if pinch == nil {
				guard SpatialPinchInterpreter.claims(direction: .zoomOut, firstDelta: event.magnification) else { return event }
				pinch = SpatialPinchInterpreter(direction: .zoomOut)
				presentOverview(interactive: true)
			}
			pinch?.update(magnificationDelta: event.magnification, timestamp: event.timestamp)
			overview?.setInteractiveProgress(pinch?.rubberBandedProgress ?? 0)
			return nil
		case .ended, .cancelled:
			guard let pinch else { return event }
			self.pinch = nil
			overview?.completeInteractivePresentation(commit: event.phase == .ended && pinch.outcome() == .commit)
			return nil
		default:
			return pinch == nil ? event : nil
		}
	}

	// MARK: Persistence

	private func persist() {
		guard let data = try? JSONEncoder().encode(splits) else { return }
		defaults.set(data, forKey: Self.splitDefaultsKey)
	}

	private static func loadSplits(from defaults: UserDefaults) -> [SpatialSplitLayout<BrowserTabID>] {
		guard let data = defaults.data(forKey: splitDefaultsKey),
		      let splits = try? JSONDecoder().decode([SpatialSplitLayout<BrowserTabID>].self, from: data)
		else { return [] }
		return splits.filter(\.isSplit)
	}
}

extension BrowserSpatialLayoutController: SpatialTabOverviewViewDelegate {
	func overviewPageRect(for tabID: BrowserTabID) -> CGRect {
		guard let overview else { return .zero }
		var rect = hostView.bounds
		if let split = splits.first(where: { $0.contains(tabID) }), isSplitEnabled {
			rect = split.paneFrames(in: hostView.bounds, gap: BrowserSpatialHostView.paneGap)[tabID] ?? rect
		}
		return overview.convert(rect, from: hostView)
	}

	func overviewDidChooseTab(_ tabID: BrowserTabID) {
		if hooks.selectedTabID() != tabID {
			hooks.selectTab(tabID)
		}
	}

	func overviewDidRequestClose(_ tabID: BrowserTabID) {
		hooks.closeTab(tabID)
		if hooks.tabs().isEmpty {
			overview?.dismiss(choosing: nil, notifyChoice: false)
		}
	}

	func overviewDidRequestSplit(dragged: BrowserTabID, target: BrowserTabID, edge: SpatialSplitEdge) {
		guard isSplitEnabled else { return }
		split(dragged, into: target, edge: edge)
		hooks.selectTab(target)
		overview?.setItems(overviewItems(), pageAspectRatio: pageAspectRatio)
		overview?.dismiss(choosing: target, notifyChoice: false)
	}

	func overviewDidRequestMove(_ tabID: BrowserTabID, before target: BrowserTabID) {
		hooks.moveTab(tabID, target)
		overview?.setItems(overviewItems(), pageAspectRatio: pageAspectRatio)
	}

	func overviewDidFinishDismissing() {
		overview?.removeFromSuperview()
		overview = nil
		hostView.window?.makeFirstResponder(hooks.selectedTabID().flatMap { hooks.container($0) })
	}
}

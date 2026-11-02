import Foundation
import Observation

/// Drives the floating toolbar's presentation: when it is expanded, collapsed to a compact
/// pill, or showing the tab shelf.
///
/// The toolbar stays expanded while the pointer is over it or near the bottom edge of the
/// window, or while the tab shelf is open. Otherwise it collapses after a short idle delay
/// so the page gets the screen.
struct BrowserFloatingToolbarAccessory: Identifiable {
	let id: String
	let systemImage: String
	let help: String
	let action: @MainActor () -> Void

	init(id: String, systemImage: String, help: String, action: @escaping @MainActor () -> Void) {
		self.id = id
		self.systemImage = systemImage
		self.help = help
		self.action = action
	}
}

@MainActor
@Observable
final class BrowserFloatingToolbarState {
	private(set) var isExpanded = true
	private(set) var isTabShelfPresented = false
	/// Address pill frame in the hosting view's coordinate space (flipped, top-left origin).
	var addressPillFrame: CGRect = .zero
	/// Extra buttons rendered after the tab cluster (e.g. user actions from other modules).
	var trailingAccessories: [BrowserFloatingToolbarAccessory] = []

	@ObservationIgnored var autoCollapses = true
	@ObservationIgnored var collapseDelay: Duration = .seconds(2.2)

	@ObservationIgnored private var isHovering = false
	@ObservationIgnored private var isPointerNearBottom = false
	@ObservationIgnored private var collapseTask: Task<Void, Never>?

	func setHovering(_ isHovering: Bool) {
		guard self.isHovering != isHovering else { return }
		self.isHovering = isHovering
		reevaluate()
	}

	func setPointerNearBottom(_ isNear: Bool) {
		guard isPointerNearBottom != isNear else { return }
		isPointerNearBottom = isNear
		reevaluate()
	}

	func toggleTabShelf() {
		setTabShelfPresented(!isTabShelfPresented)
	}

	func setTabShelfPresented(_ isPresented: Bool) {
		guard isTabShelfPresented != isPresented else { return }
		isTabShelfPresented = isPresented
		reevaluate()
	}

	/// Briefly brings the toolbar back, e.g. after a navigation or tab switch, so the user
	/// sees where they are before it tucks away again.
	func flash() {
		isExpanded = true
		reevaluate()
	}

	private func reevaluate() {
		let shouldStayExpanded = !autoCollapses || isHovering || isPointerNearBottom || isTabShelfPresented
		if shouldStayExpanded {
			collapseTask?.cancel()
			collapseTask = nil
			if !isExpanded {
				isExpanded = true
			}
		}
		else {
			scheduleCollapse()
		}
	}

	private func scheduleCollapse() {
		collapseTask?.cancel()
		let delay = collapseDelay
		collapseTask = Task { [weak self] in
			try? await Task.sleep(for: delay)
			guard !Task.isCancelled, let self else { return }
			self.isExpanded = false
			self.collapseTask = nil
		}
	}
}

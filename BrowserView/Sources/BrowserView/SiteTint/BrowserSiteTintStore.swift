import BrowserSidebar
import Foundation
import Observation

/// Per-host tint overrides shared by every window. The per-site customization layer writes here.
@MainActor
public final class BrowserSiteTintOverrides {
	public static let shared = BrowserSiteTintOverrides()
	static let didChangeNotification = Notification.Name("navigator.siteTint.overridesDidChange")

	private var overridesByHost = [String: BrowserSiteTintOverride]()

	public init() {}

	public func override(forHost host: String?) -> BrowserSiteTintOverride? {
		guard let key = Self.normalizedHost(host) else { return nil }
		return overridesByHost[key]
	}

	/// Pass `nil` to clear the host back to automatic tinting.
	public func setOverride(_ override: BrowserSiteTintOverride?, forHost host: String) {
		guard let key = Self.normalizedHost(host) else { return }
		guard overridesByHost[key] != override else { return }
		overridesByHost[key] = override
		NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
	}

	static func normalizedHost(_ host: String?) -> String? {
		guard var value = host?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
		      value.isEmpty == false
		else { return nil }
		if value.hasPrefix("www.") { value.removeFirst(4) }
		return value
	}
}

/// Tracks the sampled colors of every tab in one window and publishes the tint for the selected one.
@MainActor
@Observable
public final class BrowserSiteTintStore {
	public private(set) var currentTint: BrowserSiteTint?

	public var isDarkAppearance = false {
		didSet { if oldValue != isDarkAppearance { recompute() } }
	}

	public var isEnabled: Bool {
		didSet { if oldValue != isEnabled { recompute() } }
	}

	/// Fires after `currentTint` changes; AppKit chrome uses it to run its spring cross-fade.
	@ObservationIgnored public var onTintChange: ((BrowserSiteTint?) -> Void)?

	@ObservationIgnored private let overrides: BrowserSiteTintOverrides
	@ObservationIgnored private var entriesByTabID = [BrowserTabID: Entry]()
	@ObservationIgnored private var selectedTabID: BrowserTabID?
	@ObservationIgnored nonisolated(unsafe) private var overridesObserver: NSObjectProtocol?

	private struct Entry: Equatable {
		var host: String?
		var sample: BrowserSiteTintSample?
	}

	public init(
		overrides: BrowserSiteTintOverrides = .shared,
		isEnabled: Bool = true
	) {
		self.overrides = overrides
		self.isEnabled = isEnabled
		overridesObserver = NotificationCenter.default.addObserver(
			forName: BrowserSiteTintOverrides.didChangeNotification,
			object: overrides,
			queue: .main
		) { [weak self] _ in
			MainActor.assumeIsolated { self?.recompute() }
		}
	}

	deinit {
		if let overridesObserver {
			NotificationCenter.default.removeObserver(overridesObserver)
		}
	}

	/// Convenience for the per-site customization layer.
	public static func setOverride(_ override: BrowserSiteTintOverride?, forHost host: String) {
		BrowserSiteTintOverrides.shared.setOverride(override, forHost: host)
	}

	public func selectTab(_ tabID: BrowserTabID?) {
		guard selectedTabID != tabID else { return }
		selectedTabID = tabID
		recompute()
	}

	/// A new main-frame URL. Keeps the old sample when staying on the same host so in-site
	/// navigation doesn't flash back to neutral before the next sample lands.
	public func noteURL(_ url: String, for tabID: BrowserTabID) {
		let host = URLComponents(string: url)?.host
		var entry = entriesByTabID[tabID] ?? Entry()
		if BrowserSiteTintOverrides.normalizedHost(entry.host) != BrowserSiteTintOverrides.normalizedHost(host) {
			entry.sample = nil
		}
		entry.host = host
		update(entry, for: tabID)
	}

	public func record(_ sample: BrowserSiteTintSample, for tabID: BrowserTabID) {
		BrowserSiteTintDebugLog.log {
			"sample tab=\(tabID.uuidString.prefix(8)) host=\(self.entriesByTabID[tabID]?.host ?? "-") \(sample.debugDescription)"
		}
		var entry = entriesByTabID[tabID] ?? Entry()
		entry.sample = sample
		update(entry, for: tabID)
	}

	public func removeTab(_ tabID: BrowserTabID) {
		guard entriesByTabID.removeValue(forKey: tabID) != nil else { return }
		if tabID == selectedTabID { recompute() }
	}

	private func update(_ entry: Entry, for tabID: BrowserTabID) {
		guard entriesByTabID[tabID] != entry else { return }
		entriesByTabID[tabID] = entry
		if tabID == selectedTabID { recompute() }
	}

	private func recompute() {
		let next: BrowserSiteTint?
		if isEnabled, let selectedTabID, let entry = entriesByTabID[selectedTabID] {
			next = BrowserSiteTintResolver.resolve(
				sample: entry.sample,
				override: overrides.override(forHost: entry.host),
				isDarkAppearance: isDarkAppearance
			)
		}
		else {
			next = nil
		}
		guard next != currentTint else { return }
		BrowserSiteTintDebugLog.log {
			"tint -> \(next.map { "\($0.color.hexString) (\($0.source.rawValue))" } ?? "none") enabled=\(self.isEnabled)"
		}
		currentTint = next
		onTintChange?(next)
	}
}

/// Set NAVIGATOR_SITE_TINT_DEBUG=1 to log samples and resolved tints.
enum BrowserSiteTintDebugLog {
	static let isEnabled = ProcessInfo.processInfo.environment["NAVIGATOR_SITE_TINT_DEBUG"] == "1"

	static func log(_ message: () -> String) {
		guard isEnabled else { return }
		NSLog("[SiteTint] %@", message())
	}
}

extension BrowserSiteTintSample {
	var debugDescription: String {
		func hex(_ color: BrowserSiteTintColor?) -> String {
			color.map { "\($0.hexString)\($0.isNeutral ? "(n)" : "")" } ?? "-"
		}
		return "theme=\(hex(themeColor)) bottom=\(hex(bottomEdge)) top=\(hex(topEdge)) bg=\(hex(pageBackground))"
	}
}

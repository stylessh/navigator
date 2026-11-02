import Foundation
import Observation

/// A feature that can be switched on and off from Settings → Experiments.
///
/// To add one, declare a `static let` in an extension in your own file and append it to
/// `NavigatorExperiment.all` (one line in this file). The settings tab lists every entry.
public struct NavigatorExperiment: Hashable, Sendable, Identifiable {
	/// Stable key, also used as the UserDefaults key suffix. Never rename a shipped id.
	public let id: String
	public let title: String
	public let summary: String
	public let isEnabledByDefault: Bool

	public init(id: String, title: String, summary: String, isEnabledByDefault: Bool) {
		self.id = id
		self.title = title
		self.summary = summary
		self.isEnabledByDefault = isEnabledByDefault
	}

	public var defaultsKey: String {
		"navigator.experiment.\(id)"
	}
}

public extension NavigatorExperiment {
	/// Every experiment shown in Settings, in display order. Append new entries here.
	static let all: [NavigatorExperiment] = [
		.floatingToolbarAutoHide,
		.commandBar,
	]

	static let floatingToolbarAutoHide = NavigatorExperiment(
		id: "floatingToolbar.autoHide",
		title: "Auto-hide toolbar",
		summary: "Tuck the bottom toolbar into a small pill when the pointer is away from it.",
		isEnabledByDefault: true
	)
}

/// Observable on/off state for experiments, persisted in UserDefaults.
///
/// Read with `NavigatorExperiments.shared.isEnabled(.myExperiment)`. Reads are tracked by
/// Observation, so SwiftUI views and `withObservationTracking` update when a toggle flips.
@MainActor
@Observable
public final class NavigatorExperiments {
	public static let shared = NavigatorExperiments()

	private var overrides: [String: Bool]
	@ObservationIgnored private let defaults: UserDefaults

	public init(defaults: UserDefaults = .standard) {
		self.defaults = defaults
		var overrides = [String: Bool]()
		for experiment in NavigatorExperiment.all {
			if let stored = defaults.object(forKey: experiment.defaultsKey) as? Bool {
				overrides[experiment.id] = stored
			}
		}
		self.overrides = overrides
	}

	public func isEnabled(_ experiment: NavigatorExperiment) -> Bool {
		overrides[experiment.id] ?? experiment.isEnabledByDefault
	}

	public func setEnabled(_ experiment: NavigatorExperiment, _ isEnabled: Bool) {
		guard self.isEnabled(experiment) != isEnabled else { return }
		overrides[experiment.id] = isEnabled
		defaults.set(isEnabled, forKey: experiment.defaultsKey)
	}

	public func resetAll() {
		for experiment in NavigatorExperiment.all {
			defaults.removeObject(forKey: experiment.defaultsKey)
		}
		overrides.removeAll()
	}
}

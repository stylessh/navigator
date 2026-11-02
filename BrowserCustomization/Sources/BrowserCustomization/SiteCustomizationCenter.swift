import Foundation
import Observation

/// One place that owns boosts, user actions and the action registry for the whole app.
///
/// BrowserView asks it which scripts to inject; the toolbar and command bar ask its
/// `actions` registry what to show. It has no AppKit or CEF dependency.
@MainActor
@Observable
public final class SiteCustomizationCenter {
	public static let shared = SiteCustomizationCenter(
		boostDirectory: BoostStore.defaultDirectory(),
		actionDirectory: UserActionLoader.defaultDirectory()
	)

	public let boosts: BoostStore
	public let actions: NavigatorActionRegistry
	public let actionDirectory: URL
	public private(set) var userActionErrors: [String: String] = [:]

	/// When false nothing is injected and the registry is empty. Driven by the Experiments toggle.
	public var isEnabled = true {
		didSet {
			guard isEnabled != oldValue else { return }
			notifyChange()
		}
	}

	/// Called with (host, preference) when a site's tint preference changes, and once per boost on start.
	/// BrowserView forwards this to the site-tint feature.
	@ObservationIgnored public var onTintPreferenceChange: (@MainActor (String, SiteTintPreference) -> Void)?

	@ObservationIgnored private var watcher: BoostDirectoryWatcher?
	@ObservationIgnored private var actionWatcherTask: Task<Void, Never>?
	@ObservationIgnored private var lastActionFingerprint: [String: Date] = [:]
	@ObservationIgnored private var lastTintByHost: [String: SiteTintPreference] = [:]
	@ObservationIgnored private var changeObservers: [UUID: @MainActor () -> Void] = [:]
	@ObservationIgnored private var started = false

	public init(boostDirectory: URL, actionDirectory: URL) {
		boosts = BoostStore(directory: boostDirectory)
		actions = NavigatorActionRegistry()
		self.actionDirectory = actionDirectory
	}

	public func start() {
		guard started == false else { return }
		started = true
		try? FileManager.default.createDirectory(at: boosts.directory, withIntermediateDirectories: true)
		UserActionLoader.seedExamplesIfNeeded(in: actionDirectory)
		boosts.reload()
		boosts.addObserver { [weak self] in
			self?.publishTintChanges()
			self?.notifyChange()
		}
		actions.register(BuiltInActions.make(store: boosts))
		reloadUserActions()
		publishTintChanges()

		let watcher = BoostDirectoryWatcher(store: boosts)
		watcher.start()
		self.watcher = watcher
		lastActionFingerprint = BoostDirectoryWatcher.fingerprint(of: actionDirectory)
		actionWatcherTask = Task { [weak self] in
			while Task.isCancelled == false {
				try? await Task.sleep(for: .seconds(1))
				self?.reloadUserActionsIfChanged()
			}
		}
	}

	public func stop() {
		watcher?.stop()
		watcher = nil
		actionWatcherTask?.cancel()
		actionWatcherTask = nil
		started = false
	}

	// MARK: Injection

	/// Boosts that should be live on `url` right now.
	public func activeBoosts(for url: URL) -> [Boost] {
		guard isEnabled else { return [] }
		return boosts.boosts(for: url)
	}

	/// Scripts to evaluate in the main frame, in order, for a page lifecycle phase.
	/// `.commit` syncs styles (also removes stale ones); `.idle` re-syncs and runs idle scripts.
	public func scripts(for url: URL, phase: Boost.RunAt) -> [String] {
		let active = activeBoosts(for: url)
		// Always sync, even with no boosts, so disabling a boost takes effect without a reload.
		// Skip pages that never had a boost to avoid touching every page on the web.
		guard active.isEmpty == false || hadBoostsRecently(for: url) else { return [] }
		return [BoostScriptBuilder.syncScript(for: active)] + BoostScriptBuilder.userScripts(for: active, phase: phase)
	}

	private func hadBoostsRecently(for url: URL) -> Bool {
		boosts.boosts.contains { $0.matches.contains { $0.matches(url) } }
	}

	// MARK: Change notification for AppKit clients

	@discardableResult
	public func addChangeObserver(_ handler: @escaping @MainActor () -> Void) -> UUID {
		let token = UUID()
		changeObservers[token] = handler
		return token
	}

	public func removeChangeObserver(_ token: UUID) {
		changeObservers[token] = nil
	}

	private func notifyChange() {
		for observer in changeObservers.values {
			observer()
		}
	}

	// MARK: Tint bridge

	private func publishTintChanges() {
		var current: [String: SiteTintPreference] = [:]
		for boost in boosts.boosts {
			for pattern in boost.matches {
				let host = pattern.rawValue.lowercased()
				guard host.contains("*") == false, host.contains("/") == false else { continue }
				current[SiteHost.normalized(host) ?? host] = boost.isEnabled ? boost.tint : .automatic
			}
		}
		for host in Set(current.keys).union(lastTintByHost.keys) {
			let preference = current[host] ?? .automatic
			if lastTintByHost[host] != preference {
				onTintPreferenceChange?(host, preference)
			}
		}
		lastTintByHost = current
	}

	// MARK: User actions

	public func reloadUserActions() {
		let (manifests, errors) = UserActionLoader.load(from: actionDirectory)
		userActionErrors = errors
		actions.replaceActions(
			fromSource: UserActionLoader.sourceName,
			with: manifests.map { $0.makeAction(source: UserActionLoader.sourceName) }
		)
	}

	private func reloadUserActionsIfChanged() {
		let fingerprint = BoostDirectoryWatcher.fingerprint(of: actionDirectory)
		guard fingerprint != lastActionFingerprint else { return }
		lastActionFingerprint = fingerprint
		reloadUserActions()
	}
}

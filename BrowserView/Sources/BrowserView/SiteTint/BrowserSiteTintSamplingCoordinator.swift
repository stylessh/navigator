import BrowserSidebar
import Foundation

/// Decides when to run the page sampler and feeds results into a `BrowserSiteTintStore`.
///
/// It knows nothing about CEF: the chrome view hands it an `evaluate` closure that runs the
/// sampler in the tab's main frame (fire-and-forget), and forwards the tab's page messages to
/// `handlePageMessage(_:for:)`, which is where results arrive. That keeps this logic testable.
@MainActor
final class BrowserSiteTintSamplingCoordinator {
	typealias Evaluate = (_ tabID: BrowserTabID, _ script: String) -> Void
	typealias Scheduler = (TimeInterval, @escaping @MainActor () -> Void) -> () -> Void

	static let defaultScheduler: Scheduler = { delay, action in
		let workItem = DispatchWorkItem { MainActor.assumeIsolated { action() } }
		DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
		return { workItem.cancel() }
	}

	var store: BrowserSiteTintStore? {
		didSet {
			guard store !== oldValue, let store else { return }
			store.selectTab(selectedTabID)
		}
	}

	private let evaluate: Evaluate
	/// False while the tab is loading. The page-command channel uses window.prompt, and a prompt
	/// during a load can cancel navigations the page starts itself, so samples wait for the load.
	private let canSample: (BrowserTabID) -> Bool
	private var deferredSampleCancellationByTabID = [BrowserTabID: () -> Void]()
	static let loadingRetryDelay: TimeInterval = 0.4
	static let maxLoadingRetries = 25
	private let scheduler: Scheduler
	private var pendingResamplesByTabID = [BrowserTabID: [() -> Void]]()
	private var selectedTabID: BrowserTabID?
	private var latestTokenByTabID = [BrowserTabID: Int]()
	private var nextToken = 1

	init(
		evaluate: @escaping Evaluate,
		canSample: @escaping (BrowserTabID) -> Bool = { _ in true },
		scheduler: @escaping Scheduler = defaultScheduler
	) {
		self.evaluate = evaluate
		self.canSample = canSample
		self.scheduler = scheduler
	}

	func tabSelected(_ tabID: BrowserTabID) {
		selectedTabID = tabID
		store?.selectTab(tabID)
		sample(tabID)
	}

	/// Main-frame commit or URL change: reset the host and sample on a short back-off.
	func navigationCommitted(_ url: String, for tabID: BrowserTabID) {
		store?.noteURL(url, for: tabID)
		scheduleResamples(for: tabID)
	}

	/// Title changes usually land once `<head>` is parsed, a good moment to catch theme-color.
	func titleChanged(for tabID: BrowserTabID) {
		sample(tabID)
	}

	func tabRemoved(_ tabID: BrowserTabID) {
		cancelResamples(for: tabID)
		latestTokenByTabID.removeValue(forKey: tabID)
		store?.removeTab(tabID)
	}

	func cancelAll() {
		for tabID in Array(pendingResamplesByTabID.keys) {
			cancelResamples(for: tabID)
		}
	}

	private func scheduleResamples(for tabID: BrowserTabID) {
		cancelResamples(for: tabID)
		pendingResamplesByTabID[tabID] = BrowserSiteTintSampler.resampleDelays.map { delay in
			scheduler(delay) { [weak self] in
				self?.sample(tabID)
			}
		}
	}

	private func cancelResamples(for tabID: BrowserTabID) {
		pendingResamplesByTabID.removeValue(forKey: tabID)?.forEach { $0() }
		deferredSampleCancellationByTabID.removeValue(forKey: tabID)?()
	}

	/// A page message from `tabID`. Returns true when it was a site-tint result.
	@discardableResult
	func handlePageMessage(_ payload: String, for tabID: BrowserTabID) -> Bool {
		guard let message = BrowserSiteTintSampler.decodeMessage(payload) else { return false }
		// Drop answers from an older sample so a slow page can't repaint the chrome with the
		// previous page's color.
		guard let token = message.token, latestTokenByTabID[tabID] == token else { return true }
		guard let sample = message.sample else {
			BrowserSiteTintDebugLog.log {
				"sample failed tab=\(tabID.uuidString.prefix(8)) error=\(message.error ?? "-") payload=\(payload.prefix(200))"
			}
			return true
		}
		store?.record(sample, for: tabID)
		return true
	}

	private func sample(_ tabID: BrowserTabID, loadingRetries: Int = 0) {
		guard let store, store.isEnabled else { return }
		guard canSample(tabID) else {
			// One deferred sample per tab is enough; later triggers fold into it.
			guard deferredSampleCancellationByTabID[tabID] == nil, loadingRetries < Self.maxLoadingRetries else { return }
			deferredSampleCancellationByTabID[tabID] = scheduler(Self.loadingRetryDelay) { [weak self] in
				self?.deferredSampleCancellationByTabID[tabID] = nil
				self?.sample(tabID, loadingRetries: loadingRetries + 1)
			}
			return
		}
		let token = nextToken
		nextToken += 1
		latestTokenByTabID[tabID] = token
		BrowserSiteTintDebugLog.log { "sampling tab=\(tabID.uuidString.prefix(8)) token=\(token)" }
		evaluate(tabID, BrowserSiteTintSampler.script(token: token))
	}
}

import Foundation

/// Reloads a `BoostStore` when files in its directory change, so editing `style.css`
/// in an external editor restyles the page within a fraction of a second.
///
/// Uses a cheap polling fingerprint (file names + modification dates) instead of FSEvents
/// because boost folders are tiny and nested edits need to be seen without per-folder sources.
@MainActor
public final class BoostDirectoryWatcher {
	private let store: BoostStore
	private let interval: Duration
	private var task: Task<Void, Never>?
	private var lastFingerprint: [String: Date] = [:]

	public init(store: BoostStore, interval: Duration = .milliseconds(500)) {
		self.store = store
		self.interval = interval
	}

	public func start() {
		guard task == nil else { return }
		lastFingerprint = Self.fingerprint(of: store.directory)
		task = Task { [weak self] in
			while Task.isCancelled == false {
				guard let interval = self?.interval else { return }
				try? await Task.sleep(for: interval)
				self?.tick()
			}
		}
	}

	public func stop() {
		task?.cancel()
		task = nil
	}

	private func tick() {
		let fingerprint = Self.fingerprint(of: store.directory)
		guard fingerprint != lastFingerprint else { return }
		lastFingerprint = fingerprint
		store.reload()
	}

	nonisolated static func fingerprint(of directory: URL) -> [String: Date] {
		let keys: [URLResourceKey] = [.contentModificationDateKey]
		guard let enumerator = FileManager.default.enumerator(
			at: directory,
			includingPropertiesForKeys: keys,
			options: [.skipsHiddenFiles]
		) else { return [:] }
		var result: [String: Date] = [:]
		for case let url as URL in enumerator {
			let date = (try? url.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast
			result[url.path] = date
		}
		return result
	}
}

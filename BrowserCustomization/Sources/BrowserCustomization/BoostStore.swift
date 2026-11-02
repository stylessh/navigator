import Foundation
import Observation

/// Loads and saves boosts as editable folders:
///
/// ```
/// ~/Library/Application Support/Navigator/Boosts/
///   github-com/
///     boost.json   { "id", "name", "matches", "enabled", "zaps", "presets", "allowJavaScript", "runAt" }
///     style.css    (optional, overrides "css" in boost.json)
///     script.js    (optional, overrides "javascript" in boost.json)
/// ```
///
/// Edits made in an external editor are picked up by `reload()`; `BoostDirectoryWatcher` calls it automatically.
@MainActor
@Observable
public final class BoostStore {
	public private(set) var boosts: [Boost] = []
	public private(set) var lastLoadErrors: [String: String] = [:]
	/// Bumped on every change so injectors can tell a page to re-apply.
	public private(set) var revision = 0

	public let directory: URL
	private let fileManager: FileManager
	@ObservationIgnored private var observers: [UUID: @MainActor () -> Void] = [:]

	public nonisolated static let manifestFileName = "boost.json"
	public nonisolated static let styleFileName = "style.css"
	public nonisolated static let scriptFileName = "script.js"

	public init(directory: URL, fileManager: FileManager = .default) {
		self.directory = directory
		self.fileManager = fileManager
	}

	public nonisolated static func defaultDirectory(fileManager: FileManager = .default) -> URL {
		let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
			?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
		return base.appendingPathComponent("Navigator/Boosts", isDirectory: true)
	}

	// MARK: Querying

	/// Enabled boosts for `url`, least specific first so more specific CSS wins the cascade.
	public func boosts(for url: URL) -> [Boost] {
		boosts
			.filter { $0.applies(to: url) }
			.sorted { $0.specificity(for: url) < $1.specificity(for: url) }
	}

	/// The boost dedicated to `url`'s host, if one exists (enabled or not).
	public func siteBoost(for url: URL) -> Boost? {
		guard let host = SiteHost.normalized(url.host) else { return nil }
		return boosts.first { $0.id == BoostID.make(fromHost: host) }
	}

	public func boost(id: Boost.ID) -> Boost? {
		boosts.first { $0.id == id }
	}

	// MARK: Mutating

	/// Returns the site boost for `url`, creating an empty one in memory if needed.
	public func siteBoostOrNew(for url: URL) -> Boost? {
		if let existing = siteBoost(for: url) { return existing }
		guard let host = SiteHost.normalized(url.host) else { return nil }
		return .forSite(host)
	}

	public func save(_ boost: Boost) {
		if let index = boosts.firstIndex(where: { $0.id == boost.id }) {
			boosts[index] = boost
		}
		else {
			boosts.append(boost)
		}
		do {
			try write(boost)
			lastLoadErrors[boost.id] = nil
		}
		catch {
			lastLoadErrors[boost.id] = error.localizedDescription
		}
		didChange()
	}

	/// Applies `transform` to the site boost for `url`, creating it if needed, and saves.
	@discardableResult
	public func updateSiteBoost(for url: URL, _ transform: (inout Boost) -> Void) -> Boost? {
		guard var boost = siteBoostOrNew(for: url) else { return nil }
		transform(&boost)
		save(boost)
		return boost
	}

	public func addZap(_ selector: String, for url: URL) {
		let trimmed = selector.trimmingCharacters(in: .whitespacesAndNewlines)
		guard trimmed.isEmpty == false else { return }
		updateSiteBoost(for: url) { boost in
			if boost.zaps.contains(trimmed) == false {
				boost.zaps.append(trimmed)
			}
			boost.isEnabled = true
		}
	}

	public func delete(id: Boost.ID) {
		boosts.removeAll { $0.id == id }
		try? fileManager.removeItem(at: folder(for: id))
		didChange()
	}

	// MARK: Observation for non-SwiftUI clients

	/// Calls `handler` after every change. Returns a token for `removeObserver`.
	@discardableResult
	public func addObserver(_ handler: @escaping @MainActor () -> Void) -> UUID {
		let token = UUID()
		observers[token] = handler
		return token
	}

	public func removeObserver(_ token: UUID) {
		observers[token] = nil
	}

	private func didChange() {
		revision += 1
		for observer in observers.values {
			observer()
		}
	}

	// MARK: Disk

	public func reload() {
		var loaded: [Boost] = []
		var errors: [String: String] = [:]
		let folders = (try? fileManager.contentsOfDirectory(
			at: directory,
			includingPropertiesForKeys: [.isDirectoryKey],
			options: [.skipsHiddenFiles]
		)) ?? []
		for folder in folders.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
			let manifestURL = folder.appendingPathComponent(Self.manifestFileName)
			guard fileManager.fileExists(atPath: manifestURL.path) else { continue }
			do {
				loaded.append(try Self.readBoost(in: folder))
			}
			catch {
				errors[folder.lastPathComponent] = String(describing: error)
			}
		}
		let changed = loaded != boosts
		boosts = loaded
		lastLoadErrors = errors
		if changed {
			didChange()
		}
	}

	static func readBoost(in folder: URL) throws -> Boost {
		let data = try Data(contentsOf: folder.appendingPathComponent(manifestFileName))
		var boost = try JSONDecoder().decode(Boost.self, from: data)
		if let css = try? String(contentsOf: folder.appendingPathComponent(styleFileName), encoding: .utf8) {
			boost.css = css
		}
		if let js = try? String(contentsOf: folder.appendingPathComponent(scriptFileName), encoding: .utf8) {
			boost.javascript = js
		}
		// The folder name is the source of truth so renaming a folder can't create duplicate ids.
		boost.id = folder.lastPathComponent
		return boost
	}

	public func folder(for id: Boost.ID) -> URL {
		directory.appendingPathComponent(id, isDirectory: true)
	}

	private func write(_ boost: Boost) throws {
		let folder = folder(for: boost.id)
		try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
		var manifest = boost
		// CSS and JS live in their own files so they get syntax highlighting in an editor.
		manifest.css = ""
		manifest.javascript = ""
		let encoder = JSONEncoder()
		encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
		try encoder.encode(manifest).write(to: folder.appendingPathComponent(Self.manifestFileName), options: .atomic)
		try writeOptional(boost.css, to: folder.appendingPathComponent(Self.styleFileName))
		try writeOptional(boost.javascript, to: folder.appendingPathComponent(Self.scriptFileName))
	}

	private func writeOptional(_ contents: String, to url: URL) throws {
		if contents.isEmpty {
			if fileManager.fileExists(atPath: url.path) {
				try fileManager.removeItem(at: url)
			}
		}
		else {
			try Data(contents.utf8).write(to: url, options: .atomic)
		}
	}
}

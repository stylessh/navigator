import Foundation

/// A declarative user plugin: one JSON file in `~/Library/Application Support/Navigator/Actions/`.
///
/// ```json
/// {
///   "id": "archive",
///   "title": "Open in Wayback Machine",
///   "systemImage": "clock.arrow.circlepath",
///   "placements": ["commandBar", "toolbar"],
///   "matches": ["*"],
///   "run": { "type": "openURL", "template": "https://web.archive.org/web/{url}", "newTab": true }
/// }
/// ```
///
/// `run.type` is `openURL` (template vars: `{url}`, `{host}`, `{title}`, `{selection}`, all percent-encoded,
/// plus `{raw_url}` unencoded)
/// or `script` (page JavaScript; a returned string is shown as a toast).
public struct UserActionManifest: Codable, Hashable, Sendable {
	public enum Run: Hashable, Sendable {
		case openURL(template: String, newTab: Bool)
		case script(source: String)
	}

	public var id: String
	public var title: String
	public var subtitle: String?
	public var systemImage: String
	public var keywords: [String]
	public var placements: Set<NavigatorActionPlacement>
	public var matches: [SitePattern]
	public var run: Run

	public init(
		id: String,
		title: String,
		subtitle: String? = nil,
		systemImage: String = "puzzlepiece.extension",
		keywords: [String] = [],
		placements: Set<NavigatorActionPlacement> = [.commandBar],
		matches: [SitePattern] = ["*"],
		run: Run
	) {
		self.id = id
		self.title = title
		self.subtitle = subtitle
		self.systemImage = systemImage
		self.keywords = keywords
		self.placements = placements
		self.matches = matches
		self.run = run
	}

	enum CodingKeys: String, CodingKey {
		case id, title, subtitle, systemImage, keywords, placements, matches, run
	}

	enum RunKeys: String, CodingKey {
		case type, template, newTab, source
	}

	public init(from decoder: any Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		id = try container.decode(String.self, forKey: .id)
		title = try container.decode(String.self, forKey: .title)
		subtitle = try container.decodeIfPresent(String.self, forKey: .subtitle)
		systemImage = try container.decodeIfPresent(String.self, forKey: .systemImage) ?? "puzzlepiece.extension"
		keywords = try container.decodeIfPresent([String].self, forKey: .keywords) ?? []
		placements = try container.decodeIfPresent(Set<NavigatorActionPlacement>.self, forKey: .placements)
			?? [.commandBar]
		matches = try container.decodeIfPresent([SitePattern].self, forKey: .matches) ?? ["*"]
		let runContainer = try container.nestedContainer(keyedBy: RunKeys.self, forKey: .run)
		switch try runContainer.decode(String.self, forKey: .type) {
		case "openURL":
			run = .openURL(
				template: try runContainer.decode(String.self, forKey: .template),
				newTab: try runContainer.decodeIfPresent(Bool.self, forKey: .newTab) ?? true
			)
		case "script":
			run = .script(source: try runContainer.decode(String.self, forKey: .source))
		case let other:
			throw DecodingError.dataCorruptedError(
				forKey: .type,
				in: runContainer,
				debugDescription: "Unknown run type \"\(other)\". Use \"openURL\" or \"script\"."
			)
		}
	}

	public func encode(to encoder: any Encoder) throws {
		var container = encoder.container(keyedBy: CodingKeys.self)
		try container.encode(id, forKey: .id)
		try container.encode(title, forKey: .title)
		try container.encodeIfPresent(subtitle, forKey: .subtitle)
		try container.encode(systemImage, forKey: .systemImage)
		try container.encode(keywords, forKey: .keywords)
		try container.encode(placements.map(\.rawValue).sorted(), forKey: .placements)
		try container.encode(matches, forKey: .matches)
		var runContainer = container.nestedContainer(keyedBy: RunKeys.self, forKey: .run)
		switch run {
		case let .openURL(template, newTab):
			try runContainer.encode("openURL", forKey: .type)
			try runContainer.encode(template, forKey: .template)
			try runContainer.encode(newTab, forKey: .newTab)
		case let .script(source):
			try runContainer.encode("script", forKey: .type)
			try runContainer.encode(source, forKey: .source)
		}
	}

	/// Expands `{url}`, `{host}`, `{title}` and `{selection}`, percent-encoding each value.
	public static func expand(template: String, context: NavigatorActionContext, selection: String?) -> URL? {
		let values: [String: String] = [
			"url": context.url?.absoluteString ?? "",
			"host": context.host ?? "",
			"title": context.title ?? "",
			"selection": selection ?? "",
		]
		var allowed = CharacterSet.urlQueryAllowed
		allowed.remove(charactersIn: "&=?#+/:")
		var result = template
		for (key, value) in values {
			let encoded = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
			result = result.replacingOccurrences(of: "{\(key)}", with: encoded)
		}
		// `{raw_url}` is for services that take the whole URL as a path, like the Wayback Machine.
		result = result.replacingOccurrences(of: "{raw_url}", with: context.url?.absoluteString ?? "")
		return URL(string: result)
	}

	public func makeAction(source: String) -> NavigatorAction {
		let patterns = matches
		let run = run
		return NavigatorAction(
			id: "user.\(id)",
			title: title,
			subtitle: subtitle,
			systemImage: systemImage,
			keywords: keywords,
			placements: placements,
			source: source,
			isAvailable: { context in
				guard let url = context.url else { return false }
				return patterns.contains { $0.matches(url) }
			}
		) { context, performer in
			switch run {
			case let .openURL(template, newTab):
				let selection = template.contains("{selection}")
					? await performer.evaluateInPage("String(window.getSelection ? window.getSelection() : '')")
					: nil
				guard let url = Self.expand(template: template, context: context, selection: selection) else {
					performer.showToast("Couldn't build a link from this action", systemImage: "exclamationmark.triangle")
					return
				}
				performer.open(url, inNewTab: newTab)
			case let .script(source):
				let wrapped = "(function(){ try { var r = (function(){\n\(source)\n})(); "
					+ "return r == null ? '' : String(r); } catch (e) { return 'Error: ' + e.message; } })()"
				if let message = await performer.evaluateInPage(wrapped), message.isEmpty == false {
					performer.showToast(message, systemImage: systemImage)
				}
			}
		}
	}
}

/// Loads every `*.json` manifest in a folder. Bad files are reported, not fatal.
public enum UserActionLoader {
	public static let sourceName = "User actions"

	public static func defaultDirectory(fileManager: FileManager = .default) -> URL {
		BoostStore.defaultDirectory(fileManager: fileManager)
			.deletingLastPathComponent()
			.appendingPathComponent("Actions", isDirectory: true)
	}

	public static func load(
		from directory: URL,
		fileManager: FileManager = .default
	) -> (manifests: [UserActionManifest], errors: [String: String]) {
		let files = (try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
		var manifests: [UserActionManifest] = []
		var errors: [String: String] = [:]
		for file in files.filter({ $0.pathExtension == "json" }).sorted(by: { $0.path < $1.path }) {
			do {
				manifests.append(try JSONDecoder().decode(UserActionManifest.self, from: Data(contentsOf: file)))
			}
			catch {
				errors[file.lastPathComponent] = String(describing: error)
			}
		}
		return (manifests, errors)
	}

	/// Writes a couple of examples the first time so the folder isn't a blank page.
	public static func seedExamplesIfNeeded(in directory: URL, fileManager: FileManager = .default) {
		guard fileManager.fileExists(atPath: directory.path) == false else { return }
		try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
		let examples = [
			UserActionManifest(
				id: "wayback",
				title: "Open in Wayback Machine",
				systemImage: "clock.arrow.circlepath",
				keywords: ["archive", "history"],
				placements: [.commandBar],
				run: .openURL(template: "https://web.archive.org/web/{raw_url}", newTab: true)
			),
			UserActionManifest(
				id: "word-count",
				title: "Count Words on Page",
				systemImage: "textformat.123",
				keywords: ["reading", "length"],
				placements: [.commandBar, .pageMenu],
				run: .script(source: """
				const words = (document.body.innerText.match(/\\S+/g) || []).length;
				return words.toLocaleString() + " words · ~" + Math.max(1, Math.round(words / 230)) + " min read";
				""")
			),
		]
		let encoder = JSONEncoder()
		encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
		for example in examples {
			if let data = try? encoder.encode(example) {
				try? data.write(to: directory.appendingPathComponent("\(example.id).json"))
			}
		}
	}
}

import Foundation

/// A user customization applied to every page that matches one of its patterns.
///
/// On disk a boost is a folder: `boost.json` plus optional `style.css` and `script.js`,
/// so it can be edited in any text editor and live-reloaded.
public struct Boost: Identifiable, Hashable, Sendable, Codable {
	public enum RunAt: String, Hashable, Sendable, Codable {
		/// As soon as the main frame commits. Best for CSS so there is no flash of unstyled content.
		case commit
		/// After the page finishes loading. Best for scripts that query the DOM.
		case idle
	}

	public var id: String
	public var name: String
	public var matches: [SitePattern]
	public var isEnabled: Bool
	public var css: String
	/// CSS selectors hidden with `display: none !important` (built by the zap picker).
	public var zaps: [String]
	public var javascript: String
	/// User JavaScript only runs when this is true, even if `javascript` is non-empty.
	public var allowsJavaScript: Bool
	public var runAt: RunAt
	/// Identifiers of built-in presets layered under the custom CSS.
	public var presets: [BoostPreset.ID]
	/// How the browser chrome tints itself on this site.
	public var tint: SiteTintPreference

	public init(
		id: String,
		name: String,
		matches: [SitePattern],
		isEnabled: Bool = true,
		css: String = "",
		zaps: [String] = [],
		javascript: String = "",
		allowsJavaScript: Bool = false,
		runAt: RunAt = .commit,
		presets: [BoostPreset.ID] = [],
		tint: SiteTintPreference = .automatic
	) {
		self.id = id
		self.name = name
		self.matches = matches
		self.isEnabled = isEnabled
		self.css = css
		self.zaps = zaps
		self.javascript = javascript
		self.allowsJavaScript = allowsJavaScript
		self.runAt = runAt
		self.presets = presets
		self.tint = tint
	}

	/// The default boost created the first time someone customizes a site.
	public static func forSite(_ host: String) -> Boost {
		Boost(id: BoostID.make(fromHost: host), name: host, matches: [SitePattern(host)])
	}

	public var isEmpty: Bool {
		css.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
			&& zaps.isEmpty
			&& presets.isEmpty
			&& tint == .automatic
			&& (allowsJavaScript == false || javascript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
	}

	public func applies(to url: URL) -> Bool {
		isEnabled && matches.contains { $0.matches(url) }
	}

	/// Highest specificity among the patterns that match `url`.
	func specificity(for url: URL) -> Int {
		matches.filter { $0.matches(url) }.map(\.specificity).max() ?? 0
	}

	/// The CSS the page actually receives: presets, then zaps, then custom CSS.
	public var compiledCSS: String {
		var chunks = presets.compactMap { BoostPreset.preset(for: $0)?.css }
		if zaps.isEmpty == false {
			chunks.append(zaps.joined(separator: ",\n") + " { display: none !important; }")
		}
		if css.isEmpty == false {
			chunks.append(css)
		}
		return chunks.joined(separator: "\n\n")
	}

	// Keys use the on-disk names so `boost.json` stays readable.
	enum CodingKeys: String, CodingKey {
		case id, name, matches, css, zaps, javascript, presets, tint
		case isEnabled = "enabled"
		case allowsJavaScript = "allowJavaScript"
		case runAt
	}

	public init(from decoder: any Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		id = try container.decode(String.self, forKey: .id)
		name = try container.decodeIfPresent(String.self, forKey: .name) ?? id
		matches = try container.decodeIfPresent([SitePattern].self, forKey: .matches) ?? []
		isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
		css = try container.decodeIfPresent(String.self, forKey: .css) ?? ""
		zaps = try container.decodeIfPresent([String].self, forKey: .zaps) ?? []
		javascript = try container.decodeIfPresent(String.self, forKey: .javascript) ?? ""
		allowsJavaScript = try container.decodeIfPresent(Bool.self, forKey: .allowsJavaScript) ?? false
		runAt = try container.decodeIfPresent(RunAt.self, forKey: .runAt) ?? .commit
		presets = try container.decodeIfPresent([BoostPreset.ID].self, forKey: .presets) ?? []
		tint = try container.decodeIfPresent(SiteTintPreference.self, forKey: .tint) ?? .automatic
	}
}

/// Per-site override for the chrome tint (the tint itself is resolved by BrowserView's site-tint feature).
/// Encoded as `"auto"`, `"off"`, or a `"#RRGGBB"` hex string.
public enum SiteTintPreference: Hashable, Sendable, Codable {
	case automatic
	case off
	case custom(hex: String)

	public init(from decoder: any Decoder) throws {
		let raw = try decoder.singleValueContainer().decode(String.self)
		self = Self(rawValue: raw)
	}

	public init(rawValue raw: String) {
		switch raw.lowercased() {
		case "off", "none": self = .off
		case "auto", "automatic", "": self = .automatic
		default:
			self = Self.normalizedHex(raw).map { .custom(hex: $0) } ?? .automatic
		}
	}

	public var rawValue: String {
		switch self {
		case .automatic: "auto"
		case .off: "off"
		case let .custom(hex): hex
		}
	}

	public func encode(to encoder: any Encoder) throws {
		var container = encoder.singleValueContainer()
		try container.encode(rawValue)
	}

	/// `#abc`, `abc`, `#AABBCC` -> `#AABBCC`; anything else -> nil.
	public static func normalizedHex(_ value: String) -> String? {
		var hex = value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
		if hex.hasPrefix("#") { hex.removeFirst() }
		if hex.count == 3 { hex = hex.map { "\($0)\($0)" }.joined() }
		guard hex.count == 6, hex.allSatisfy(\.isHexDigit) else { return nil }
		return "#" + hex
	}

	/// Components in 0...1, for building an NSColor/Color without importing AppKit here.
	public var rgb: (red: Double, green: Double, blue: Double)? {
		guard case let .custom(hex) = self, let value = UInt32(hex.dropFirst(), radix: 16) else { return nil }
		return (
			Double((value >> 16) & 0xFF) / 255,
			Double((value >> 8) & 0xFF) / 255,
			Double(value & 0xFF) / 255
		)
	}
}

public enum BoostID {
	/// A filesystem-safe identifier derived from a host, e.g. `news.ycombinator.com` -> `news-ycombinator-com`.
	public static func make(fromHost host: String) -> String {
		let allowed = CharacterSet.alphanumerics
		let mapped = host.lowercased().unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
		let collapsed = String(mapped).split(separator: "-", omittingEmptySubsequences: true).joined(separator: "-")
		return collapsed.isEmpty ? "boost" : collapsed
	}
}

/// One-tap building blocks for a boost. Kept small and CSS-only so they are safe to toggle anywhere.
public struct BoostPreset: Identifiable, Hashable, Sendable {
	public let id: String
	public let title: String
	public let systemImage: String
	public let css: String

	public static let all: [BoostPreset] = [
		BoostPreset(
			id: "readable-width",
			title: "Readable width",
			systemImage: "text.alignleft",
			css: """
			body > * { max-width: 72ch !important; margin-left: auto !important; margin-right: auto !important; }
			"""
		),
		BoostPreset(
			id: "force-dark",
			title: "Force dark",
			systemImage: "moon.fill",
			css: """
			html { filter: invert(0.92) hue-rotate(180deg) !important; background: #fff !important; }
			img, video, picture, canvas, svg image, iframe, [style*="background-image"] { filter: invert(1) hue-rotate(180deg) !important; }
			"""
		),
		BoostPreset(
			id: "hide-sticky",
			title: "Hide sticky bars",
			systemImage: "pin.slash",
			// Applied by the runtime, which tags fixed/sticky elements with this attribute.
			css: """
			[data-navigator-sticky] { display: none !important; }
			"""
		),
		BoostPreset(
			id: "system-font",
			title: "System font",
			systemImage: "textformat",
			css: """
			body, body *:not(code):not(pre):not(kbd):not(samp):not([class*="icon"]) { font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif !important; }
			code, pre, kbd, samp { font-family: ui-monospace, "SF Mono", Menlo, monospace !important; }
			"""
		),
		BoostPreset(
			id: "no-animations",
			title: "Calm motion",
			systemImage: "tortoise.fill",
			css: """
			*, *::before, *::after { animation-duration: 0.001s !important; animation-iteration-count: 1 !important; transition-duration: 0.001s !important; scroll-behavior: auto !important; }
			"""
		),
	]

	public static func preset(for id: ID) -> BoostPreset? {
		all.first { $0.id == id }
	}
}

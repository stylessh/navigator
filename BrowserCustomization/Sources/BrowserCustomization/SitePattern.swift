import Foundation

/// A host (and optional path) pattern that decides which pages a boost or action applies to.
///
/// Supported forms:
/// - `*` matches every http(s) page.
/// - `github.com` matches `github.com` and `www.github.com` only.
/// - `*.github.com` matches `github.com` and every subdomain of it.
/// - `github.com/settings*` or `github.com/settings/` adds a path prefix.
public struct SitePattern: Hashable, Sendable, Codable, CustomStringConvertible, ExpressibleByStringLiteral {
	public let rawValue: String

	public init(_ rawValue: String) {
		self.rawValue = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
	}

	public init(stringLiteral value: String) {
		self.init(value)
	}

	public init(from decoder: any Decoder) throws {
		let container = try decoder.singleValueContainer()
		self.init(try container.decode(String.self))
	}

	public func encode(to encoder: any Encoder) throws {
		var container = encoder.singleValueContainer()
		try container.encode(rawValue)
	}

	public var description: String {
		rawValue
	}

	/// The pattern that matches exactly the host of `url` (minus a leading `www.`).
	public static func host(of url: URL) -> SitePattern? {
		guard let host = SiteHost.normalized(url.host) else { return nil }
		return SitePattern(host)
	}

	private var parts: (host: String, path: String?) {
		var value = rawValue.lowercased()
		if let schemeRange = value.range(of: "://") {
			value = String(value[schemeRange.upperBound...])
		}
		guard let slash = value.firstIndex(of: "/") else {
			return (value, nil)
		}
		let host = String(value[..<slash])
		var path = String(value[slash...])
		if path.hasSuffix("*") {
			path.removeLast()
		}
		return (host, path.isEmpty || path == "/" ? nil : path)
	}

	/// Specificity used to order overlapping rules: more specific rules apply later so they win the cascade.
	public var specificity: Int {
		let (host, path) = parts
		if host == "*" { return 0 }
		let hostScore = host.split(separator: ".").count * 10 - (host.hasPrefix("*.") ? 5 : 0)
		return hostScore + (path.map { $0.count * 100 } ?? 0)
	}

	public func matches(_ url: URL) -> Bool {
		guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
			return false
		}
		guard let urlHost = url.host?.lowercased(), urlHost.isEmpty == false else { return false }
		let (host, path) = parts
		guard Self.hostMatches(pattern: host, host: urlHost) else { return false }
		guard let path else { return true }
		let urlPath = url.path.isEmpty ? "/" : url.path
		return urlPath.lowercased().hasPrefix(path)
	}

	private static func hostMatches(pattern: String, host: String) -> Bool {
		if pattern == "*" { return true }
		if pattern.hasPrefix("*.") {
			let base = String(pattern.dropFirst(2))
			return host == base || host.hasSuffix("." + base)
		}
		return host == pattern || host == "www." + pattern
	}
}

public enum SiteHost {
	/// Lowercased host with a leading `www.` removed, or nil for non-web URLs.
	public static func normalized(_ host: String?) -> String? {
		guard var host = host?.lowercased(), host.isEmpty == false else { return nil }
		if host.hasPrefix("www.") {
			host.removeFirst(4)
		}
		return host
	}
}

import Foundation

/// URL heuristics shared by the action bar and the command bar.
public enum CommandBarURLResolver {
	/// Returns a navigable URL when the text looks like one (`example.com`, `localhost:3000`, `https://…`), else nil.
	public static func resolvedURL(from value: String) -> String? {
		let normalizedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !normalizedValue.isEmpty else { return nil }

		if let implicitWebURL = implicitWebURL(from: normalizedValue) {
			return implicitWebURL
		}

		if hasExplicitScheme(normalizedValue) {
			return URL(string: normalizedValue) == nil ? nil : normalizedValue
		}

		return nil
	}

	public static func searchURL(for query: String) -> String {
		var components = URLComponents(string: "https://www.google.com/search")!
		components.queryItems = [URLQueryItem(name: "q", value: query)]
		return components.url!.absoluteString
	}

	/// `https://www.example.com/path/` → `example.com/path`
	public static func displayURL(_ url: String) -> String {
		var value = url
		for prefix in ["https://", "http://"] where value.hasPrefix(prefix) {
			value.removeFirst(prefix.count)
		}
		if value.hasPrefix("www.") {
			value.removeFirst(4)
		}
		if value.hasSuffix("/") {
			value.removeLast()
		}
		return value
	}

	/// Key used to dedupe the same page across tabs and history.
	public static func normalizedKey(_ url: String) -> String {
		var value = displayURL(url).lowercased()
		if let hashIndex = value.firstIndex(of: "#") {
			value = String(value[..<hashIndex])
		}
		return value
	}

	private static func implicitWebURL(from normalizedValue: String) -> String? {
		guard !normalizedValue.contains("://") else { return nil }
		guard !normalizedValue.contains(where: { $0.isWhitespace }) else { return nil }
		let candidateURL = "https://\(normalizedValue)"
		guard var components = URLComponents(string: candidateURL),
		      components.user == nil,
		      components.password == nil,
		      let host = components.host,
		      !host.isEmpty else { return nil }
		guard isIPAddress(host) || host.contains(".") || isLocalhostHost(host) else {
			return nil
		}
		components.scheme = isLocalhostHost(host) ? "http" : "https"
		return components.string
	}

	private static func hasExplicitScheme(_ value: String) -> Bool {
		guard let separatorIndex = value.firstIndex(of: ":"),
		      separatorIndex > value.startIndex else {
			return false
		}

		let scheme = value[..<separatorIndex]
		guard let firstCharacter = scheme.first, firstCharacter.isLetter else { return false }
		return scheme.dropFirst().allSatisfy { character in
			character.isLetter || character.isNumber || character == "+" || character == "-" || character == "."
		}
	}

	private static func isIPAddress(_ host: String) -> Bool {
		if host.contains(":") {
			return true
		}

		let components = host.split(separator: ".", omittingEmptySubsequences: false)
		guard components.count == 4 else { return false }
		return components.allSatisfy { component in
			guard let octet = Int(component), (0...255).contains(octet) else { return false }
			return String(octet) == component
		}
	}

	private static func isLocalhostHost(_ host: String) -> Bool {
		let normalizedHost = host.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
		return normalizedHost == "localhost" || normalizedHost.hasSuffix(".localhost")
	}
}

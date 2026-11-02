import Foundation

/// Builds the JavaScript that native code evaluates in a page's main frame.
///
/// The runtime (`boost-runtime.js`) is idempotent, so every script starts with it and
/// can be evaluated at any point in a page's life: on commit, on load end, or after an edit.
public enum BoostScriptBuilder {
	public static let runtimeSource: String = {
		guard let url = Bundle.module.url(forResource: "boost-runtime", withExtension: "js"),
		      let source = try? String(contentsOf: url, encoding: .utf8)
		else {
			assertionFailure("boost-runtime.js missing from BrowserCustomization bundle")
			return ""
		}
		return source
	}()

	struct SyncEntry: Encodable {
		let id: String
		let css: String
		let revision: String
		let tagSticky: Bool
	}

	/// One evaluation that installs the runtime and makes the page's boost styles match `boosts` exactly.
	/// Passing an empty array removes every boost style from the page.
	public static func syncScript(for boosts: [Boost]) -> String {
		let entries = boosts.map { boost in
			SyncEntry(
				id: boost.id,
				css: boost.compiledCSS,
				revision: revision(of: boost.compiledCSS),
				tagSticky: boost.presets.contains("hide-sticky")
			)
		}
		return runtimeSource + "\n;window.__navigatorBoost.sync(" + jsonLiteral(entries) + ");"
	}

	/// User scripts are evaluated separately from the sync script so a syntax error
	/// in one boost can't stop styles (or other boosts) from applying.
	public static func userScripts(for boosts: [Boost], phase: Boost.RunAt) -> [String] {
		boosts.compactMap { boost in
			guard boost.allowsJavaScript, boost.runAt == phase else { return nil }
			let source = boost.javascript.trimmingCharacters(in: .whitespacesAndNewlines)
			guard source.isEmpty == false else { return nil }
			return runtimeSource
				+ "\n;window.__navigatorBoost.runOnce(" + jsonLiteral(boost.id) + ", "
				+ jsonLiteral(revision(of: source)) + ", function () {\n" + source + "\n});"
		}
	}

	public static func startPickerScript(accentHex: String? = nil) -> String {
		runtimeSource + "\n;window.__navigatorBoost.startPicker(" + jsonLiteral(accentHex) + ");"
	}

	public static let takePickScript = "window.__navigatorBoost ? window.__navigatorBoost.takePick() : ''"
	public static let cancelPickerScript = "window.__navigatorBoost && window.__navigatorBoost.cancelPicker();"

	public static func countMatchesScript(selector: String) -> String {
		"window.__navigatorBoost ? String(window.__navigatorBoost.countMatches(" + jsonLiteral(selector) + ")) : '-1'"
	}

	/// Stable FNV-1a hash, so revisions survive relaunch (unlike `hashValue`).
	static func revision(of string: String) -> String {
		var hash: UInt64 = 0xCBF2_9CE4_8422_2325
		for byte in string.utf8 {
			hash ^= UInt64(byte)
			hash = hash &* 0x100_0000_01B3
		}
		return String(hash, radix: 36)
	}

	/// Encodes a value as a JavaScript literal. JSON is a subset of JS once U+2028/2029 are escaped.
	static func jsonLiteral(_ value: some Encodable) -> String {
		let encoder = JSONEncoder()
		encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
		guard let data = try? encoder.encode(value), let json = String(data: data, encoding: .utf8) else {
			return "null"
		}
		return json
			.replacingOccurrences(of: "\u{2028}", with: "\\u2028")
			.replacingOccurrences(of: "\u{2029}", with: "\\u2029")
			.replacingOccurrences(of: "</script", with: "<\\/script")
	}
}

public struct BoostPickResult: Decodable, Equatable, Sendable {
	public let selector: String
	public let cancelled: Bool
	public let idle: Bool?

	public static func parse(_ raw: String?) -> BoostPickResult? {
		guard let raw, raw.isEmpty == false, let data = raw.data(using: .utf8) else { return nil }
		return try? JSONDecoder().decode(Self.self, from: data)
	}
}

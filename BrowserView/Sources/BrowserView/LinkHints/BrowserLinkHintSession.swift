import CoreGraphics
import Foundation

/// Generates short, prefix-free hint labels from a home-row-first alphabet.
///
/// No label is a prefix of another, so typing a full label always resolves to exactly one
/// target without needing a confirm key. Labels are as short as the target count allows.
enum BrowserLinkHintLabelGenerator {
	static let defaultAlphabet = Array("sadfjklewcmpgh")

	static func labels(count: Int, alphabet: [Character] = defaultAlphabet) -> [String] {
		guard count > 0 else { return [] }
		guard alphabet.count > 1 else {
			return (0..<count).map { String(repeating: String(alphabet.first ?? "a"), count: $0 + 1) }
		}

		// Breadth-first expansion: repeatedly replace the oldest label with alphabet.count
		// longer labels until there are enough leaves.
		var hints = [""]
		var offset = 0
		while hints.count - offset < count || hints.count == 1 {
			let hint = hints[offset]
			offset += 1
			for character in alphabet {
				hints.append(String(character) + hint)
			}
		}

		// Shorter labels first, so the first targets in reading order get single letters, then
		// by alphabet priority so home-row letters come before the rest.
		let priority = Dictionary(uniqueKeysWithValues: alphabet.enumerated().map { ($1, $0) })
		return hints[offset..<(offset + count)]
			.map { String($0.reversed()) }
			.sorted { lhs, rhs in
				guard lhs.count == rhs.count else { return lhs.count < rhs.count }
				return lhs.map { priority[$0, default: 0] }.lexicographicallyPrecedes(rhs.map { priority[$0, default: 0] })
			}
	}
}

struct BrowserLinkHintTarget: Equatable, Decodable {
	enum Kind: String, Decodable {
		case link
		case button
		case input
	}

	var x: CGFloat
	var y: CGFloat
	var width: CGFloat
	var height: CGFloat
	var kind: Kind

	var rect: CGRect {
		CGRect(x: x, y: y, width: width, height: height)
	}

	private enum CodingKeys: String, CodingKey {
		case x, y, width, height, kind
	}

	init(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat, kind: Kind) {
		self.x = x
		self.y = y
		self.width = width
		self.height = height
		self.kind = kind
	}

	init(from decoder: any Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		x = try container.decode(CGFloat.self, forKey: .x)
		y = try container.decode(CGFloat.self, forKey: .y)
		width = try container.decode(CGFloat.self, forKey: .width)
		height = try container.decode(CGFloat.self, forKey: .height)
		kind = (try? container.decode(Kind.self, forKey: .kind)) ?? .button
	}
}

struct BrowserLinkHintCollection: Equatable, Decodable {
	struct Viewport: Equatable, Decodable {
		var width: CGFloat
		var height: CGFloat
	}

	var viewport: Viewport
	var targets: [BrowserLinkHintTarget]

	static func from(json: String) -> BrowserLinkHintCollection? {
		guard let data = json.data(using: .utf8) else { return nil }
		return try? JSONDecoder().decode(BrowserLinkHintCollection.self, from: data)
	}
}

struct BrowserLinkHint: Equatable, Identifiable {
	/// Index into the page's stored target list.
	var id: Int
	var label: String
	/// Frame in page CSS pixels, relative to the top-left of the viewport.
	var pageRect: CGRect
	var kind: BrowserLinkHintTarget.Kind
}

/// Pure state machine for one hint-mode session: which labels exist, what has been typed,
/// and what should happen after each key press.
struct BrowserLinkHintSession: Equatable {
	enum Outcome: Equatable {
		/// The typed prefix changed; these hints still match.
		case filtered(matching: [BrowserLinkHint], typedPrefix: String)
		/// The key did not match any label and was ignored.
		case rejected
		/// The typed label resolved to exactly one hint.
		case activate(BrowserLinkHint)
		/// The session ended without an activation.
		case dismissed
	}

	let hints: [BrowserLinkHint]
	let openInNewTab: Bool
	private(set) var typedPrefix = ""

	init(collection: BrowserLinkHintCollection, openInNewTab: Bool) {
		let labels = BrowserLinkHintLabelGenerator.labels(count: collection.targets.count)
		hints = zip(collection.targets.indices, labels).map { index, label in
			let target = collection.targets[index]
			return BrowserLinkHint(id: index, label: label, pageRect: target.rect, kind: target.kind)
		}
		self.openInNewTab = openInNewTab
	}

	var matchingHints: [BrowserLinkHint] {
		guard typedPrefix.isEmpty == false else { return hints }
		return hints.filter { $0.label.hasPrefix(typedPrefix) }
	}

	mutating func type(_ text: String) -> Outcome {
		let normalized = text.lowercased().filter { $0.isLetter }
		guard normalized.count == 1 else { return .rejected }
		let candidate = typedPrefix + normalized
		let matches = hints.filter { $0.label.hasPrefix(candidate) }
		guard matches.isEmpty == false else { return .rejected }
		typedPrefix = candidate
		if matches.count == 1, matches[0].label == candidate {
			return .activate(matches[0])
		}
		return .filtered(matching: matches, typedPrefix: typedPrefix)
	}

	mutating func deleteBackward() -> Outcome {
		guard typedPrefix.isEmpty == false else { return .dismissed }
		typedPrefix.removeLast()
		return .filtered(matching: matchingHints, typedPrefix: typedPrefix)
	}
}

import Foundation

/// One poll's worth of data from the page agent.
public struct DeveloperOverlayPayload: Equatable, Sendable, Decodable {
	public struct Picked: Equatable, Sendable, Decodable {
		/// `nil` when the selection was cleared.
		public var value: DeveloperInspectedElement?
	}

	public struct Viewport: Equatable, Sendable, Decodable {
		public var width: Double
		public var height: Double
		public var devicePixelRatio: Double

		private enum CodingKeys: String, CodingKey {
			case width = "w"
			case height = "h"
			case devicePixelRatio = "dpr"
		}

		public init(width: Double, height: Double, devicePixelRatio: Double) {
			self.width = width
			self.height = height
			self.devicePixelRatio = devicePixelRatio
		}
	}

	public var revision: Int
	public var console: [DeveloperConsoleEntry]
	public var network: [DeveloperNetworkEntry]
	/// Present only when the selection changed since the requested revision.
	public var picked: Picked?
	public var isPicking: Bool
	public var url: String
	public var title: String
	public var viewport: Viewport?
	/// CSS color string for the page's accent (`rgb(...)`), when it has one.
	public var themeColor: String?
	/// `document.visibilityState` (diagnostics).
	public var visibility: String?

	private enum CodingKeys: String, CodingKey {
		case revision = "rev"
		case console
		case network
		case picked
		case isPicking = "picking"
		case url
		case title
		case viewport
		case themeColor = "theme"
		case visibility
	}

	public init(from decoder: Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		revision = try container.decodeIfPresent(Int.self, forKey: .revision) ?? 0
		console = try container.decodeIfPresent([DeveloperConsoleEntry].self, forKey: .console) ?? []
		network = try container.decodeIfPresent([DeveloperNetworkEntry].self, forKey: .network) ?? []
		picked = try container.decodeIfPresent(Picked.self, forKey: .picked)
		isPicking = try container.decodeIfPresent(Bool.self, forKey: .isPicking) ?? false
		url = try container.decodeIfPresent(String.self, forKey: .url) ?? ""
		title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
		viewport = try container.decodeIfPresent(Viewport.self, forKey: .viewport)
		themeColor = try container.decodeIfPresent(String.self, forKey: .themeColor)
		visibility = try container.decodeIfPresent(String.self, forKey: .visibility)
	}

	public enum PollResult: Equatable, Sendable {
		case payload(DeveloperOverlayPayload)
		/// The current document doesn't have the agent (first poll, or the page navigated).
		case agentMissing
		case failure(String)
	}

	public static func parsePoll(result: String?, error: String?) -> PollResult {
		if let error, error.isEmpty == false {
			return .failure(error)
		}
		guard let result, result.isEmpty == false else {
			return .failure("Empty result")
		}
		if result == DeveloperOverlayAgentScript.missingSentinel {
			return .agentMissing
		}
		guard let data = result.data(using: .utf8) else {
			return .failure("Invalid encoding")
		}
		do {
			return try .payload(JSONDecoder().decode(DeveloperOverlayPayload.self, from: data))
		}
		catch {
			return .failure("Malformed payload: \(error.localizedDescription)")
		}
	}
}

/// Result of a console prompt evaluation.
public struct DeveloperEvaluationResult: Equatable, Sendable, Decodable {
	public var ok: Bool
	public var text: String
	/// The page's CSP blocked `eval`; retry with `DeveloperOverlayAgentScript.evaluateInline`.
	public var isBlockedByCSP: Bool

	public init(ok: Bool, text: String, isBlockedByCSP: Bool = false) {
		self.ok = ok
		self.text = text
		self.isBlockedByCSP = isBlockedByCSP
	}

	private enum CodingKeys: String, CodingKey {
		case ok
		case text
		case isBlockedByCSP = "blocked"
	}

	public init(from decoder: Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		ok = try container.decode(Bool.self, forKey: .ok)
		text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
		isBlockedByCSP = try container.decodeIfPresent(Bool.self, forKey: .isBlockedByCSP) ?? false
	}

	public static func parse(result: String?, error: String?) -> DeveloperEvaluationResult {
		if let error, error.isEmpty == false {
			return DeveloperEvaluationResult(ok: false, text: error)
		}
		guard
			let result,
			let data = result.data(using: .utf8),
			let decoded = try? JSONDecoder().decode(DeveloperEvaluationResult.self, from: data)
		else {
			return DeveloperEvaluationResult(ok: true, text: result ?? "undefined")
		}
		return decoded
	}
}

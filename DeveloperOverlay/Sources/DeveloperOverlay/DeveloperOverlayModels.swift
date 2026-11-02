import CoreGraphics
import Foundation

// MARK: - Console

public struct DeveloperConsoleEntry: Identifiable, Equatable, Sendable, Decodable {
	public enum Level: String, Equatable, Sendable, Decodable, CaseIterable {
		case log
		case info
		case warn
		case error
		case debug
		/// A line the developer typed into the console prompt.
		case input
		/// The value produced by evaluating an `input` line.
		case result
		/// A marker inserted by the overlay, for example when the page navigates.
		case system

		public init(from decoder: Decoder) throws {
			let raw = try decoder.singleValueContainer().decode(String.self)
			self = Level(rawValue: raw) ?? .log
		}
	}

	/// Stable identity. Page entries use `page-<seq>`; overlay-created entries use `local-<n>`.
	public var id: String
	public var level: Level
	public var text: String
	public var source: String?
	public var timestamp: Date
	/// Number of identical consecutive messages folded into this row.
	public var repeatCount: Int

	public init(
		id: String,
		level: Level,
		text: String,
		source: String? = nil,
		timestamp: Date = Date(),
		repeatCount: Int = 1
	) {
		self.id = id
		self.level = level
		self.text = text
		self.source = source
		self.timestamp = timestamp
		self.repeatCount = repeatCount
	}

	private enum CodingKeys: String, CodingKey {
		case id
		case level
		case text
		case source
		case ts
	}

	public init(from decoder: Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		let sequence = try container.decode(Int.self, forKey: .id)
		id = "page-\(sequence)"
		level = try container.decodeIfPresent(Level.self, forKey: .level) ?? .log
		text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
		source = try container.decodeIfPresent(String.self, forKey: .source)
		let milliseconds = try container.decodeIfPresent(Double.self, forKey: .ts) ?? 0
		timestamp = Date(timeIntervalSince1970: milliseconds / 1000)
		repeatCount = 1
	}

	public var isProblem: Bool {
		level == .error || level == .warn
	}
}

// MARK: - Network

public struct DeveloperNetworkEntry: Identifiable, Equatable, Sendable, Decodable {
	public enum Kind: String, Equatable, Sendable, Decodable {
		case document
		case fetch
		case xhr
		case script
		case stylesheet
		case image
		case font
		case media
		case other

		public init(from decoder: Decoder) throws {
			let raw = try decoder.singleValueContainer().decode(String.self)
			self = Kind(rawValue: raw) ?? .other
		}

		public var label: String {
			switch self {
			case .document: "doc"
			case .fetch: "fetch"
			case .xhr: "xhr"
			case .script: "js"
			case .stylesheet: "css"
			case .image: "img"
			case .font: "font"
			case .media: "media"
			case .other: "other"
			}
		}
	}

	public var id: String
	public var kind: Kind
	public var method: String
	public var url: String
	/// HTTP status, when known. `0` means the browser didn't expose it (cross-origin timing entries).
	public var status: Int?
	/// Milliseconds since navigation start.
	public var startTime: Double
	/// Milliseconds, nil while the request is still in flight.
	public var duration: Double?
	/// Bytes over the wire, when known.
	public var transferSize: Int?
	public var mimeType: String?
	public var errorText: String?

	public init(
		id: String,
		kind: Kind,
		method: String = "GET",
		url: String,
		status: Int? = nil,
		startTime: Double = 0,
		duration: Double? = nil,
		transferSize: Int? = nil,
		mimeType: String? = nil,
		errorText: String? = nil
	) {
		self.id = id
		self.kind = kind
		self.method = method
		self.url = url
		self.status = status
		self.startTime = startTime
		self.duration = duration
		self.transferSize = transferSize
		self.mimeType = mimeType
		self.errorText = errorText
	}

	private enum CodingKeys: String, CodingKey {
		case id
		case kind
		case method
		case url
		case status
		case start
		case duration
		case size
		case mime
		case error
	}

	public init(from decoder: Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		id = try container.decode(String.self, forKey: .id)
		kind = try container.decodeIfPresent(Kind.self, forKey: .kind) ?? .other
		method = try container.decodeIfPresent(String.self, forKey: .method) ?? "GET"
		url = try container.decodeIfPresent(String.self, forKey: .url) ?? ""
		status = try container.decodeIfPresent(Int.self, forKey: .status)
		startTime = try container.decodeIfPresent(Double.self, forKey: .start) ?? 0
		duration = try container.decodeIfPresent(Double.self, forKey: .duration)
		transferSize = try container.decodeIfPresent(Int.self, forKey: .size)
		mimeType = try container.decodeIfPresent(String.self, forKey: .mime)
		errorText = try container.decodeIfPresent(String.self, forKey: .error)
	}

	public var isPending: Bool {
		duration == nil && errorText == nil
	}

	public var isFailure: Bool {
		if errorText != nil { return true }
		if let status, status >= 400 { return true }
		return false
	}

	/// Last path component (or host) for compact rows.
	public var displayName: String {
		guard let components = URLComponents(string: url) else { return url }
		let path = components.path
		if let last = path.split(separator: "/").last, last.isEmpty == false {
			if let query = components.query, query.isEmpty == false {
				return "\(last)?\(query)"
			}
			return String(last)
		}
		return components.host ?? url
	}

	public var host: String? {
		URLComponents(string: url)?.host
	}
}

// MARK: - Inspector

public struct DeveloperInspectedElement: Equatable, Sendable, Decodable {
	public struct Rect: Equatable, Sendable, Decodable {
		public var x: Double
		public var y: Double
		public var width: Double
		public var height: Double

		public init(x: Double, y: Double, width: Double, height: Double) {
			self.x = x
			self.y = y
			self.width = width
			self.height = height
		}

		private enum CodingKeys: String, CodingKey {
			case x
			case y
			case width = "w"
			case height = "h"
		}
	}

	/// CSS box edges in px: top, right, bottom, left.
	public struct Edges: Equatable, Sendable, Decodable {
		public var top: Double
		public var right: Double
		public var bottom: Double
		public var left: Double

		public init(top: Double, right: Double, bottom: Double, left: Double) {
			self.top = top
			self.right = right
			self.bottom = bottom
			self.left = left
		}

		private enum CodingKeys: String, CodingKey {
			case top = "t"
			case right = "r"
			case bottom = "b"
			case left = "l"
		}

		public var isZero: Bool {
			top == 0 && right == 0 && bottom == 0 && left == 0
		}

		/// CSS shorthand, e.g. `8 16` or `0`.
		public var shorthand: String {
			func format(_ value: Double) -> String {
				value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value)
			}
			if top == bottom, left == right {
				if top == left { return format(top) }
				return "\(format(top)) \(format(left))"
			}
			return "\(format(top)) \(format(right)) \(format(bottom)) \(format(left))"
		}
	}

	public var selector: String
	public var tag: String
	public var elementID: String?
	public var classes: [String]
	public var rect: Rect
	public var margin: Edges
	public var padding: Edges
	public var border: Edges
	public var styles: [String: String]
	public var textPreview: String?
	public var childCount: Int

	public init(
		selector: String,
		tag: String,
		elementID: String? = nil,
		classes: [String] = [],
		rect: Rect,
		margin: Edges = .init(top: 0, right: 0, bottom: 0, left: 0),
		padding: Edges = .init(top: 0, right: 0, bottom: 0, left: 0),
		border: Edges = .init(top: 0, right: 0, bottom: 0, left: 0),
		styles: [String: String] = [:],
		textPreview: String? = nil,
		childCount: Int = 0
	) {
		self.selector = selector
		self.tag = tag
		self.elementID = elementID
		self.classes = classes
		self.rect = rect
		self.margin = margin
		self.padding = padding
		self.border = border
		self.styles = styles
		self.textPreview = textPreview
		self.childCount = childCount
	}

	private enum CodingKeys: String, CodingKey {
		case selector
		case tag
		case elementID = "id"
		case classes
		case rect
		case margin
		case padding
		case border
		case styles
		case text
		case children
	}

	public init(from decoder: Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		selector = try container.decode(String.self, forKey: .selector)
		tag = try container.decode(String.self, forKey: .tag)
		elementID = try container.decodeIfPresent(String.self, forKey: .elementID)
		classes = try container.decodeIfPresent([String].self, forKey: .classes) ?? []
		rect = try container.decode(Rect.self, forKey: .rect)
		let zero = Edges(top: 0, right: 0, bottom: 0, left: 0)
		margin = try container.decodeIfPresent(Edges.self, forKey: .margin) ?? zero
		padding = try container.decodeIfPresent(Edges.self, forKey: .padding) ?? zero
		border = try container.decodeIfPresent(Edges.self, forKey: .border) ?? zero
		styles = try container.decodeIfPresent([String: String].self, forKey: .styles) ?? [:]
		textPreview = try container.decodeIfPresent(String.self, forKey: .text)
		childCount = try container.decodeIfPresent(Int.self, forKey: .children) ?? 0
	}

	/// Ordered style keys shown in the inspector card.
	public static let displayedStyleKeys: [String] = [
		"display",
		"position",
		"font",
		"color",
		"background",
		"radius",
		"gap",
		"opacity",
		"z-index",
	]
}

// MARK: - Viewport

public struct DeveloperViewportPreset: Identifiable, Equatable, Hashable, Sendable {
	public enum Family: String, Sendable, Hashable {
		case phone
		case tablet
		case desktop
		case custom

		public var symbolName: String {
			switch self {
			case .phone: "iphone"
			case .tablet: "ipad"
			case .desktop: "laptopcomputer"
			case .custom: "arrow.up.left.and.arrow.down.right"
			}
		}
	}

	public var id: String
	public var name: String
	public var family: Family
	/// Portrait size in CSS points.
	public var size: CGSize

	public init(id: String, name: String, family: Family, size: CGSize) {
		self.id = id
		self.name = name
		self.family = family
		self.size = size
	}

	public func size(for orientation: DeveloperViewportOrientation) -> CGSize {
		switch orientation {
		case .portrait: size
		case .landscape: CGSize(width: size.height, height: size.width)
		}
	}

	public var supportsRotation: Bool {
		family == .phone || family == .tablet
	}

	public static let iPhoneSE = DeveloperViewportPreset(
		id: "iphone-se", name: "iPhone SE", family: .phone, size: CGSize(width: 375, height: 667)
	)
	public static let iPhone16 = DeveloperViewportPreset(
		id: "iphone-16", name: "iPhone 16", family: .phone, size: CGSize(width: 393, height: 852)
	)
	public static let iPhone16ProMax = DeveloperViewportPreset(
		id: "iphone-16-pro-max", name: "iPhone 16 Pro Max", family: .phone, size: CGSize(width: 440, height: 956)
	)
	public static let iPadMini = DeveloperViewportPreset(
		id: "ipad-mini", name: "iPad mini", family: .tablet, size: CGSize(width: 744, height: 1133)
	)
	public static let iPadPro11 = DeveloperViewportPreset(
		id: "ipad-pro-11", name: "iPad Pro 11\"", family: .tablet, size: CGSize(width: 834, height: 1210)
	)
	public static let laptop = DeveloperViewportPreset(
		id: "laptop-1280", name: "Laptop", family: .desktop, size: CGSize(width: 1280, height: 800)
	)
	public static let desktop = DeveloperViewportPreset(
		id: "desktop-1440", name: "Desktop", family: .desktop, size: CGSize(width: 1440, height: 900)
	)

	public static let builtIn: [DeveloperViewportPreset] = [
		.iPhoneSE,
		.iPhone16,
		.iPhone16ProMax,
		.iPadMini,
		.iPadPro11,
		.laptop,
		.desktop,
	]

	// CGSize isn't Hashable; identity plus size is enough.
	public func hash(into hasher: inout Hasher) {
		hasher.combine(id)
		hasher.combine(size.width)
		hasher.combine(size.height)
	}

	public static func custom(size: CGSize) -> DeveloperViewportPreset {
		DeveloperViewportPreset(id: "custom", name: "Custom", family: .custom, size: size)
	}

	/// Common CSS breakpoints shown as ticks along the stage ruler.
	public static let breakpoints: [CGFloat] = [640, 768, 1024, 1280, 1536]
}

public enum DeveloperViewportOrientation: String, Sendable, Hashable {
	case portrait
	case landscape

	public var toggled: DeveloperViewportOrientation {
		self == .portrait ? .landscape : .portrait
	}
}

/// What the browser area is doing right now.
public enum DeveloperViewportMode: Equatable, Sendable {
	/// The page fills the browser area (normal browsing).
	case responsive
	/// The page is framed at a fixed size, centered on a stage.
	case preset(DeveloperViewportPreset, DeveloperViewportOrientation)

	public var preset: DeveloperViewportPreset? {
		if case let .preset(preset, _) = self { return preset }
		return nil
	}

	public var orientation: DeveloperViewportOrientation {
		if case let .preset(_, orientation) = self { return orientation }
		return .portrait
	}

	public var targetSize: CGSize? {
		if case let .preset(preset, orientation) = self { return preset.size(for: orientation) }
		return nil
	}
}

// MARK: - Panel

public enum DeveloperOverlayTab: String, CaseIterable, Identifiable, Sendable {
	case console
	case network
	case element

	public var id: String { rawValue }

	public var title: String {
		switch self {
		case .console: "Console"
		case .network: "Network"
		case .element: "Element"
		}
	}

	public var symbolName: String {
		switch self {
		case .console: "terminal"
		case .network: "arrow.up.arrow.down"
		case .element: "cursorarrow.rays"
		}
	}
}

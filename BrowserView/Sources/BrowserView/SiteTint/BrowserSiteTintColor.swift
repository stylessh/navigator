import Foundation

/// An sRGB color in 0...1 components. Kept free of AppKit so tint math is unit-testable.
public struct BrowserSiteTintColor: Equatable, Hashable, Sendable, Codable {
	public var red: Double
	public var green: Double
	public var blue: Double
	public var alpha: Double

	public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
		self.red = Self.clamp(red)
		self.green = Self.clamp(green)
		self.blue = Self.clamp(blue)
		self.alpha = Self.clamp(alpha)
	}

	/// Accepts `#rgb`, `#rgba`, `#rrggbb` and `#rrggbbaa`, with or without the leading `#`.
	public init?(hex: String) {
		var value = hex.trimmingCharacters(in: .whitespacesAndNewlines)
		if value.hasPrefix("#") { value.removeFirst() }
		guard value.allSatisfy(\.isHexDigit) else { return nil }
		if value.count == 3 || value.count == 4 {
			value = value.map { "\($0)\($0)" }.joined()
		}
		guard value.count == 6 || value.count == 8, let raw = UInt64(value, radix: 16) else { return nil }
		if value.count == 6 {
			self.init(
				red: Double((raw >> 16) & 0xFF) / 255,
				green: Double((raw >> 8) & 0xFF) / 255,
				blue: Double(raw & 0xFF) / 255
			)
		}
		else {
			self.init(
				red: Double((raw >> 24) & 0xFF) / 255,
				green: Double((raw >> 16) & 0xFF) / 255,
				blue: Double((raw >> 8) & 0xFF) / 255,
				alpha: Double(raw & 0xFF) / 255
			)
		}
	}

	/// Builds a color from the `[r, g, b, a]` byte array the page sampler returns.
	init?(rgbaBytes: [Double]) {
		guard rgbaBytes.count == 4 else { return nil }
		self.init(
			red: rgbaBytes[0] / 255,
			green: rgbaBytes[1] / 255,
			blue: rgbaBytes[2] / 255,
			alpha: rgbaBytes[3] / 255
		)
	}

	public var hexString: String {
		let components = [red, green, blue].map { Int(($0 * 255).rounded()) }
		return String(format: "#%02X%02X%02X", components[0], components[1], components[2])
	}

	/// WCAG relative luminance.
	public var relativeLuminance: Double {
		func linear(_ channel: Double) -> Double {
			channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
		}
		return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
	}

	/// HSL saturation, 0...1.
	public var saturation: Double {
		let maxValue = max(red, green, blue)
		let minValue = min(red, green, blue)
		let lightness = (maxValue + minValue) / 2
		let delta = maxValue - minValue
		guard delta > 0.0001 else { return 0 }
		return delta / (1 - abs(2 * lightness - 1))
	}

	/// True for near-white, near-black, or mostly transparent colors: tinting with them is just noise.
	public var isNeutral: Bool {
		if alpha < 0.5 { return true }
		let luminance = relativeLuminance
		if saturation < 0.12 && (luminance > 0.85 || luminance < 0.012) { return true }
		return false
	}

	public func mixed(with other: BrowserSiteTintColor, fraction: Double) -> BrowserSiteTintColor {
		let t = Self.clamp(fraction)
		return .init(
			red: red + (other.red - red) * t,
			green: green + (other.green - green) * t,
			blue: blue + (other.blue - blue) * t,
			alpha: alpha + (other.alpha - alpha) * t
		)
	}

	/// Softens colors that would fight the glass: very bright tints are pulled down in dark mode,
	/// very dark tints are lifted a little in light mode so the toolbar label stays readable.
	public func adjusted(forDarkAppearance isDark: Bool) -> BrowserSiteTintColor {
		let luminance = relativeLuminance
		if isDark, luminance > 0.55 {
			return mixed(with: .init(red: 0, green: 0, blue: 0), fraction: min(0.45, (luminance - 0.55) * 1.2))
		}
		if isDark == false, luminance < 0.04 {
			return mixed(with: .init(red: 1, green: 1, blue: 1), fraction: 0.18)
		}
		return self
	}

	/// Whether labels drawn over this color should be light.
	public var prefersLightForeground: Bool {
		relativeLuminance < 0.4
	}

	private static func clamp(_ value: Double) -> Double {
		guard value.isFinite else { return 0 }
		return min(max(value, 0), 1)
	}
}

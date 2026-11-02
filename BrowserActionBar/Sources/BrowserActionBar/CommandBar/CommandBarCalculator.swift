import Foundation

/// Tiny, crash-safe arithmetic evaluator for inline answers (`24*7` → `168`).
///
/// Supports `+ - * / % ^`, parentheses, unary minus, decimals, and `x`/`×`/`÷`.
/// Deliberately avoids `NSExpression`, which raises Objective-C exceptions on bad input.
public enum CommandBarCalculator {
	public static func evaluate(_ input: String) -> Double? {
		let trimmed = input.trimmingCharacters(in: .whitespaces)
		guard trimmed.count <= 128 else { return nil }
		// Require at least one operator so plain numbers and words don't produce answers.
		guard trimmed.contains(where: { "+-*/%^x×÷(".contains($0) }) else { return nil }
		guard trimmed.contains(where: \.isNumber) else { return nil }

		var parser = Parser(tokens: tokenize(trimmed))
		guard let tokens = parser.tokens, !tokens.isEmpty else { return nil }
		guard let value = parser.parseExpression(), parser.isAtEnd, value.isFinite else { return nil }
		return value
	}

	public static func format(_ value: Double) -> String {
		let formatter = NumberFormatter()
		formatter.numberStyle = .decimal
		formatter.maximumFractionDigits = 10
		formatter.usesGroupingSeparator = true
		return formatter.string(from: NSNumber(value: value)) ?? String(value)
	}

	private enum Token: Equatable {
		case number(Double)
		case op(Character)
		case open
		case close
	}

	private static func tokenize(_ input: String) -> [Token]? {
		var tokens = [Token]()
		var numberBuffer = ""

		func flushNumber() -> Bool {
			guard !numberBuffer.isEmpty else { return true }
			guard let value = Double(numberBuffer) else { return false }
			tokens.append(.number(value))
			numberBuffer = ""
			return true
		}

		for character in input {
			if character.isNumber || character == "." {
				numberBuffer.append(character)
				continue
			}
			if character == "," { continue }
			guard flushNumber() else { return nil }
			switch character {
			case " ":
				continue
			case "+", "-", "*", "/", "%", "^":
				tokens.append(.op(character))
			case "x", "X", "×":
				tokens.append(.op("*"))
			case "÷":
				tokens.append(.op("/"))
			case "(":
				tokens.append(.open)
			case ")":
				tokens.append(.close)
			default:
				return nil
			}
		}
		guard flushNumber() else { return nil }
		return tokens
	}

	private struct Parser {
		let tokens: [Token]?
		private var position = 0
		private var depth = 0

		init(tokens: [Token]?) {
			self.tokens = tokens
		}

		var isAtEnd: Bool {
			position >= (tokens?.count ?? 0)
		}

		private func peek() -> Token? {
			guard let tokens, position < tokens.count else { return nil }
			return tokens[position]
		}

		private mutating func advance() {
			position += 1
		}

		// expression := term (('+' | '-') term)*
		mutating func parseExpression() -> Double? {
			guard var value = parseTerm() else { return nil }
			while case let .op(op)? = peek(), op == "+" || op == "-" {
				advance()
				guard let rhs = parseTerm() else { return nil }
				value = op == "+" ? value + rhs : value - rhs
			}
			return value
		}

		// term := power (('*' | '/' | '%') power)*
		private mutating func parseTerm() -> Double? {
			guard var value = parsePower() else { return nil }
			while case let .op(op)? = peek(), op == "*" || op == "/" || op == "%" {
				advance()
				guard let rhs = parsePower() else { return nil }
				switch op {
				case "*": value *= rhs
				case "/":
					guard rhs != 0 else { return nil }
					value /= rhs
				default:
					guard rhs != 0 else { return nil }
					value = value.truncatingRemainder(dividingBy: rhs)
				}
			}
			return value
		}

		// power := unary ('^' power)?
		private mutating func parsePower() -> Double? {
			guard let base = parseUnary() else { return nil }
			if case .op("^")? = peek() {
				advance()
				guard let exponent = parsePower() else { return nil }
				return pow(base, exponent)
			}
			return base
		}

		// unary := '-' unary | primary
		private mutating func parseUnary() -> Double? {
			if case .op("-")? = peek() {
				advance()
				return parseUnary().map { -$0 }
			}
			if case .op("+")? = peek() {
				advance()
				return parseUnary()
			}
			return parsePrimary()
		}

		// primary := number | '(' expression ')'
		private mutating func parsePrimary() -> Double? {
			switch peek() {
			case let .number(value)?:
				advance()
				return value
			case .open?:
				guard depth < 32 else { return nil }
				advance()
				depth += 1
				let value = parseExpression()
				depth -= 1
				guard case .close? = peek() else { return nil }
				advance()
				return value
			default:
				return nil
			}
		}
	}
}

import Foundation

/// Swift port of `command-score` (the fuzzy scorer behind cmdk).
///
/// Rewards continuous runs, word starts, and matches close to the start of the
/// string; lightly penalizes skipped characters, case mismatches, and trailing
/// characters. Returns a value in `0...1`, where `0` means "no match".
public enum CommandBarScorer {
	private static let scoreContinueMatch = 1.0
	private static let scoreSpaceWordJump = 0.9
	private static let scoreNonSpaceWordJump = 0.8
	private static let scoreCharacterJump = 0.17
	private static let scoreTransposition = 0.1
	private static let penaltySkipped = 0.999
	private static let penaltyCaseMismatch = 0.9999
	private static let penaltyNotComplete = 0.99

	private static let gapCharacters: Set<Character> = ["\\", "/", "_", "+", ".", "#", "\"", "@", "[", "(", "{", "&"]

	public static func score(_ candidate: String, query: String, keywords: [String] = []) -> Double {
		let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmedQuery.isEmpty else { return 1 }

		let haystack = keywords.isEmpty ? candidate : ([candidate] + keywords).joined(separator: " ")
		let string = Array(haystack)
		let abbreviation = Array(trimmedQuery)
		let lowerString = Array(formatInput(haystack))
		let lowerAbbreviation = Array(formatInput(trimmedQuery))
		guard string.count == lowerString.count, abbreviation.count == lowerAbbreviation.count else {
			// Lowercasing changed the character count (rare, e.g. "İ"); fall back to the lowered forms.
			var memo = [Int: Double]()
			return inner(
				string: lowerString,
				abbreviation: lowerAbbreviation,
				lowerString: lowerString,
				lowerAbbreviation: lowerAbbreviation,
				stringIndex: 0,
				abbreviationIndex: 0,
				memo: &memo
			)
		}

		var memo = [Int: Double]()
		return inner(
			string: string,
			abbreviation: abbreviation,
			lowerString: lowerString,
			lowerAbbreviation: lowerAbbreviation,
			stringIndex: 0,
			abbreviationIndex: 0,
			memo: &memo
		)
	}

	private static func formatInput(_ value: String) -> String {
		String(value.lowercased().map { isSpace($0) ? " " : $0 })
	}

	private static func isSpace(_ character: Character) -> Bool {
		character.isWhitespace || character == "-"
	}

	private static func isGap(_ character: Character) -> Bool {
		gapCharacters.contains(character)
	}

	private static func firstIndex(of character: Character, in characters: [Character], from start: Int) -> Int? {
		guard start < characters.count else { return nil }
		var index = start
		while index < characters.count {
			if characters[index] == character { return index }
			index += 1
		}
		return nil
	}

	private static func inner(
		string: [Character],
		abbreviation: [Character],
		lowerString: [Character],
		lowerAbbreviation: [Character],
		stringIndex: Int,
		abbreviationIndex: Int,
		memo: inout [Int: Double]
	) -> Double {
		if abbreviationIndex == abbreviation.count {
			return stringIndex == string.count ? scoreContinueMatch : penaltyNotComplete
		}

		let memoKey = stringIndex &* 4096 &+ abbreviationIndex
		if let cached = memo[memoKey] {
			return cached
		}

		let abbreviationCharacter = lowerAbbreviation[abbreviationIndex]
		let nextAbbreviationCharacter: Character? = abbreviationIndex + 1 < lowerAbbreviation.count
			? lowerAbbreviation[abbreviationIndex + 1]
			: nil
		var highScore = 0.0
		var matchIndex = firstIndex(of: abbreviationCharacter, in: lowerString, from: stringIndex)

		while let index = matchIndex {
			var score = inner(
				string: string,
				abbreviation: abbreviation,
				lowerString: lowerString,
				lowerAbbreviation: lowerAbbreviation,
				stringIndex: index + 1,
				abbreviationIndex: abbreviationIndex + 1,
				memo: &memo
			)

			if score > highScore {
				if index == stringIndex {
					score *= scoreContinueMatch
				}
				else if isGap(string[index - 1]) {
					score *= scoreNonSpaceWordJump
					let skipped = stringIndex < index - 1 ? string[stringIndex..<(index - 1)] : []
					let wordBreaks = skipped.filter(isGap).count
					if wordBreaks > 0, stringIndex > 0 {
						score *= pow(penaltySkipped, Double(wordBreaks))
					}
				}
				else if isSpace(string[index - 1]) {
					score *= scoreSpaceWordJump
					let skipped = stringIndex < index - 1 ? string[stringIndex..<(index - 1)] : []
					let spaceBreaks = skipped.filter(isSpace).count
					if spaceBreaks > 0, stringIndex > 0 {
						score *= pow(penaltySkipped, Double(spaceBreaks))
					}
				}
				else {
					score *= scoreCharacterJump
					if stringIndex > 0 {
						score *= pow(penaltySkipped, Double(index - stringIndex))
					}
				}

				if string[index] != abbreviation[abbreviationIndex] {
					score *= penaltyCaseMismatch
				}
			}

			let previousLowerCharacter: Character? = index > 0 ? lowerString[index - 1] : nil
			let shouldTryTransposition =
				(score < scoreTransposition && previousLowerCharacter != nil && previousLowerCharacter == nextAbbreviationCharacter)
				|| (nextAbbreviationCharacter == abbreviationCharacter && previousLowerCharacter != abbreviationCharacter)
			if shouldTryTransposition, abbreviationIndex + 2 <= abbreviation.count {
				let transposedScore = inner(
					string: string,
					abbreviation: abbreviation,
					lowerString: lowerString,
					lowerAbbreviation: lowerAbbreviation,
					stringIndex: index + 1,
					abbreviationIndex: abbreviationIndex + 2,
					memo: &memo
				)
				if transposedScore * scoreTransposition > score {
					score = transposedScore * scoreTransposition
				}
			}

			if score > highScore {
				highScore = score
			}

			matchIndex = firstIndex(of: abbreviationCharacter, in: lowerString, from: index + 1)
		}

		memo[memoKey] = highScore
		return highScore
	}
}

@testable import BrowserRuntime
import XCTest

final class BrowserRuntimeProfilePreferencesTests: XCTestCase {
	func testSanitizedChromiumPreferencesRemovesSeededCredentialDisablingKeys() throws {
		let preferences: [String: Any] = [
			"credentials_enable_service": false,
			"credentials_enable_autosignin": false,
			"profile": [
				"password_manager_enabled": false,
				"name": "Default",
			],
			"autofill": [
				"profile_enabled": false,
				"credit_card_enabled": false,
				"migrated": true,
			],
			"browser": [
				"has_seen_welcome_page": true,
			],
		]

		let sanitized = BrowserRuntime.sanitizedChromiumPreferences(preferences)

		XCTAssertNil(sanitized["credentials_enable_service"])
		XCTAssertNil(sanitized["credentials_enable_autosignin"])

		let profile = try XCTUnwrap(sanitized["profile"] as? [String: Any])
		XCTAssertNil(profile["password_manager_enabled"])
		XCTAssertEqual(profile["name"] as? String, "Default")

		let autofill = try XCTUnwrap(sanitized["autofill"] as? [String: Any])
		XCTAssertNil(autofill["profile_enabled"])
		XCTAssertNil(autofill["credit_card_enabled"])
		XCTAssertEqual(autofill["migrated"] as? Bool, true)

		let browser = try XCTUnwrap(sanitized["browser"] as? [String: Any])
		XCTAssertEqual(browser["has_seen_welcome_page"] as? Bool, true)
	}

	func testSanitizedChromiumPreferencesDropsEmptyContainersLeftByMigration() {
		let preferences: [String: Any] = [
			"profile": [
				"password_manager_enabled": false,
			],
		]

		let sanitized = BrowserRuntime.sanitizedChromiumPreferences(preferences)

		XCTAssertTrue(sanitized.isEmpty)
	}
}

final class BrowserRuntimeCacheRotationTests: XCTestCase {
	func testKeepsProfileWhenMarkerMatches() {
		XCTAssertFalse(BrowserRuntime.cacheRequiresRotation(
			existingMarker: "schema=1|156.0.8078.80",
			currentMarker: "schema=1|156.0.8078.80"
		))
	}

	func testKeepsProfileOnCEFUpgrade() {
		XCTAssertFalse(BrowserRuntime.cacheRequiresRotation(
			existingMarker: "schema=1|145.0.7632.117",
			currentMarker: "schema=1|156.0.8078.80"
		))
	}

	func testRotatesOnCEFDowngrade() {
		XCTAssertTrue(BrowserRuntime.cacheRequiresRotation(
			existingMarker: "schema=1|156.0.8078.80",
			currentMarker: "schema=1|145.0.7632.117"
		))
	}

	func testRotatesOnSchemaChange() {
		XCTAssertTrue(BrowserRuntime.cacheRequiresRotation(
			existingMarker: "schema=1|156.0.8078.80",
			currentMarker: "schema=2|156.0.8078.80"
		))
	}

	func testRotatesWhenMarkerMissingOrUnreadable() {
		XCTAssertTrue(BrowserRuntime.cacheRequiresRotation(existingMarker: nil, currentMarker: "schema=1|156.0.8078.80"))
		XCTAssertTrue(BrowserRuntime.cacheRequiresRotation(existingMarker: "garbage", currentMarker: "schema=1|156.0.8078.80"))
		XCTAssertTrue(BrowserRuntime.cacheRequiresRotation(existingMarker: "schema=1|", currentMarker: "schema=1|156.0.8078.80"))
	}
}

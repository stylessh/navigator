@testable import BrowserCustomization
import Foundation
import Testing

struct SitePatternTests {
	@Test func exactHostMatchesApexAndWWW() {
		let pattern: SitePattern = "github.com"
		#expect(pattern.matches(URL(string: "https://github.com/foo")!))
		#expect(pattern.matches(URL(string: "https://www.github.com/")!))
		#expect(pattern.matches(URL(string: "https://gist.github.com/")!) == false)
		#expect(pattern.matches(URL(string: "https://notgithub.com/")!) == false)
	}

	@Test func wildcardMatchesSubdomains() {
		let pattern: SitePattern = "*.github.com"
		#expect(pattern.matches(URL(string: "https://gist.github.com/")!))
		#expect(pattern.matches(URL(string: "https://github.com/")!))
		#expect(pattern.matches(URL(string: "https://evilgithub.com/")!) == false)
	}

	@Test func pathPrefixAndNonWebSchemes() {
		let pattern: SitePattern = "example.com/docs/*"
		#expect(pattern.matches(URL(string: "https://example.com/docs/intro")!))
		#expect(pattern.matches(URL(string: "https://example.com/blog")!) == false)
		#expect(SitePattern("*").matches(URL(string: "file:///tmp/a.html")!) == false)
	}

	@Test func specificityOrdersMoreSpecificLater() {
		#expect(SitePattern("*").specificity < SitePattern("*.github.com").specificity)
		#expect(SitePattern("*.github.com").specificity < SitePattern("github.com").specificity)
		#expect(SitePattern("github.com").specificity < SitePattern("github.com/settings").specificity)
	}
}

struct BoostTests {
	@Test func compiledCSSLayersPresetsZapsThenCustom() throws {
		let boost = Boost(
			id: "x",
			name: "x",
			matches: ["x.com"],
			css: "body { color: red }",
			zaps: [".ad", "#promo"],
			presets: ["unknown-preset", "no-animations"]
		)
		let css = boost.compiledCSS
		let presetRange = try #require(css.range(of: "animation-duration"))
		let zapRange = try #require(css.range(of: ".ad,\n#promo { display: none !important; }"))
		let customRange = try #require(css.range(of: "color: red"))
		#expect(presetRange.lowerBound < zapRange.lowerBound)
		#expect(zapRange.lowerBound < customRange.lowerBound)
	}

	@Test func decodesMinimalManifestWithDefaults() throws {
		let json = ##"{ "id": "hn", "matches": ["news.ycombinator.com"], "tint": "#f60" }"##
		let boost = try JSONDecoder().decode(Boost.self, from: Data(json.utf8))
		#expect(boost.isEnabled)
		#expect(boost.allowsJavaScript == false)
		#expect(boost.runAt == .commit)
		#expect(boost.tint == .custom(hex: "#FF6600"))
	}

	@Test func boostIDIsFilesystemSafe() {
		#expect(BoostID.make(fromHost: "news.ycombinator.com") == "news-ycombinator-com")
		#expect(BoostID.make(fromHost: "..") == "boost")
	}

	@Test func tintPreferenceRoundTrips() throws {
		for value in [SiteTintPreference.automatic, .off, .custom(hex: "#1DA1F2")] {
			let data = try JSONEncoder().encode([value])
			#expect(try JSONDecoder().decode([SiteTintPreference].self, from: data) == [value])
		}
		#expect(SiteTintPreference(rawValue: "nonsense") == .automatic)
	}
}

@MainActor
struct BoostStoreTests {
	private func makeStore() -> (BoostStore, URL) {
		let directory = FileManager.default.temporaryDirectory
			.appendingPathComponent("BoostStoreTests-\(UUID().uuidString)", isDirectory: true)
		return (BoostStore(directory: directory), directory)
	}

	@Test func saveWritesEditableFilesAndReloads() throws {
		let (store, directory) = makeStore()
		defer { try? FileManager.default.removeItem(at: directory) }
		let url = try #require(URL(string: "https://www.example.com/page"))
		store.updateSiteBoost(for: url) { $0.css = "h1 { color: blue }" }
		store.addZap(".cookie-banner", for: url)

		let folder = directory.appendingPathComponent("example-com")
		let css = try String(contentsOf: folder.appendingPathComponent("style.css"), encoding: .utf8)
		#expect(css == "h1 { color: blue }")
		#expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("script.js").path) == false)

		// Simulate an edit in an external editor.
		try Data("h1 { color: green }".utf8).write(to: folder.appendingPathComponent("style.css"))
		store.reload()
		#expect(store.siteBoost(for: url)?.css == "h1 { color: green }")
		#expect(store.siteBoost(for: url)?.zaps == [".cookie-banner"])
	}

	@Test func boostsForURLAreOrderedBySpecificity() throws {
		let (store, directory) = makeStore()
		defer { try? FileManager.default.removeItem(at: directory) }
		store.save(Boost(id: "specific", name: "s", matches: ["github.com"], css: "a{}"))
		store.save(Boost(id: "global", name: "g", matches: ["*"], css: "b{}"))
		store.save(Boost(id: "off", name: "o", matches: ["*"], isEnabled: false, css: "c{}"))
		let ids = store.boosts(for: try #require(URL(string: "https://github.com"))).map(\.id)
		#expect(ids == ["global", "specific"])
	}
}

struct ScriptBuilderTests {
	@Test func syncScriptEmbedsRuntimeAndSafeJSON() {
		let boost = Boost(id: "x", name: "x", matches: ["*"], css: "a::after { content: \"</script>\u{2028}\" }")
		let script = BoostScriptBuilder.syncScript(for: [boost])
		#expect(script.contains("__navigatorBoost"))
		#expect(script.contains("</script") == false)
		#expect(script.contains("\u{2028}") == false)
	}

	@Test func userScriptsRequireOptIn() {
		var boost = Boost(id: "x", name: "x", matches: ["*"], javascript: "console.log(1)")
		#expect(BoostScriptBuilder.userScripts(for: [boost], phase: .commit).isEmpty)
		boost.allowsJavaScript = true
		#expect(BoostScriptBuilder.userScripts(for: [boost], phase: .commit).count == 1)
		#expect(BoostScriptBuilder.userScripts(for: [boost], phase: .idle).isEmpty)
	}

	@Test func revisionIsStable() {
		#expect(BoostScriptBuilder.revision(of: "abc") == BoostScriptBuilder.revision(of: "abc"))
		#expect(BoostScriptBuilder.revision(of: "abc") != BoostScriptBuilder.revision(of: "abd"))
	}
}

struct CleanURLTests {
	@Test func stripsTrackingKeepsMeaningfulParams() throws {
		let url = try #require(URL(string: "https://shop.example.com/item?id=42&utm_source=x&utm_medium=y&fbclid=abc&color=red"))
		#expect(CleanURL.clean(url).absoluteString == "https://shop.example.com/item?id=42&color=red")
	}

	@Test func siIsOnlyTrackingOnYouTubeAndSpotify() throws {
		#expect(CleanURL.clean(try #require(URL(string: "https://youtu.be/abc?si=xyz"))).absoluteString == "https://youtu.be/abc")
		#expect(CleanURL.clean(try #require(URL(string: "https://example.com/?si=1"))).absoluteString == "https://example.com/?si=1")
	}

	@Test func removesQueryEntirelyWhenOnlyTracking() throws {
		#expect(CleanURL.clean(try #require(URL(string: "https://a.com/p?gclid=1#top"))).absoluteString == "https://a.com/p#top")
	}
}

struct UserActionManifestTests {
	@Test func decodesOpenURLAndScript() throws {
		let json = #"""
		[{ "id": "a", "title": "A", "placements": ["toolbar"], "run": { "type": "openURL", "template": "https://x.com/?q={selection}" } },
		 { "id": "b", "title": "B", "run": { "type": "script", "source": "return 1" } }]
		"""#
		let manifests = try JSONDecoder().decode([UserActionManifest].self, from: Data(json.utf8))
		#expect(manifests[0].run == .openURL(template: "https://x.com/?q={selection}", newTab: true))
		#expect(manifests[0].placements == [.toolbar])
		#expect(manifests[1].placements == [.commandBar])
		#expect(manifests[1].matches == ["*"])
	}

	@Test func rejectsUnknownRunType() {
		let json = #"{ "id": "a", "title": "A", "run": { "type": "native" } }"#
		#expect(throws: DecodingError.self) {
			try JSONDecoder().decode(UserActionManifest.self, from: Data(json.utf8))
		}
	}

	@Test func templateExpansionEncodesValues() {
		let context = NavigatorActionContext(url: URL(string: "https://a.com/x?y=1"), title: "Hi & bye")
		let url = UserActionManifest.expand(
			template: "https://s.com/?u={url}&t={title}&q={selection}",
			context: context,
			selection: "two words"
		)
		#expect(url?.absoluteString == "https://s.com/?u=https%3A%2F%2Fa.com%2Fx%3Fy%3D1&t=Hi%20%26%20bye&q=two%20words")
	}
}

@MainActor
struct ActionRegistryTests {
	@Test func filtersByPlacementAvailabilityAndQuery() {
		let registry = NavigatorActionRegistry()
		registry.register(NavigatorAction(
			id: "a",
			title: "Zap Element",
			systemImage: "scope",
			keywords: ["hide"],
			placements: [.toolbar, .commandBar]
		) { _, _ in })
		registry.register(NavigatorAction(
			id: "b",
			title: "Other",
			systemImage: "x",
			placements: [.commandBar],
			isAvailable: { _ in false }
		) { _, _ in })
		let context = NavigatorActionContext(url: URL(string: "https://a.com"), title: nil)
		#expect(registry.actions(for: .toolbar, context: context).map(\.id) == ["a"])
		#expect(registry.actions(for: .commandBar, context: context, matching: "hide").map(\.id) == ["a"])
		#expect(registry.actions(for: .commandBar, context: context, matching: "nope").isEmpty)
		registry.hiddenFromToolbar = ["a"]
		#expect(registry.actions(for: .toolbar, context: context).isEmpty)
	}

	@Test func builtInsDontShowOnNonWebPages() {
		let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
		let registry = NavigatorActionRegistry()
		registry.register(BuiltInActions.make(store: BoostStore(directory: directory)))
		let context = NavigatorActionContext(url: URL(string: "about:blank"), title: nil)
		#expect(registry.actions(for: .toolbar, context: context).isEmpty)
	}
}

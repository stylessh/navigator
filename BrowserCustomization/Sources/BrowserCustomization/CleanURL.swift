import Foundation

/// Removes tracking parameters from links before they're copied or shared.
public enum CleanURL {
	public static let trackingParameterPrefixes = ["utm_", "pk_", "mtm_", "hsa_", "__hs", "_hs"]
	public static let trackingParameters: Set<String> = [
		"fbclid", "gclid", "dclid", "gbraid", "wbraid", "msclkid", "yclid", "twclid", "ttclid", "li_fat_id",
		"mc_cid", "mc_eid", "igshid", "igsh", "si", "ref_src", "ref_url", "s_cid", "_ga", "_gl",
		"oly_anon_id", "oly_enc_id", "vero_id", "wickedid", "rb_clickid", "srsltid", "spm", "scm",
	]
	/// `si` is a tracking id on YouTube/Spotify but meaningful elsewhere, so it's only removed on these hosts.
	static let hostScopedParameters: [String: Set<String>] = [
		"si": ["youtube.com", "youtu.be", "open.spotify.com", "music.youtube.com"],
	]

	public static func clean(_ url: URL) -> URL {
		guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
		      let items = components.queryItems, items.isEmpty == false
		else { return url }
		let host = SiteHost.normalized(url.host) ?? ""
		let kept = items.filter { item in
			isTracking(item.name.lowercased(), host: host) == false
		}
		guard kept.count != items.count else { return url }
		components.queryItems = kept.isEmpty ? nil : kept
		return components.url ?? url
	}

	static func isTracking(_ name: String, host: String) -> Bool {
		if let hosts = hostScopedParameters[name] {
			return hosts.contains { host == $0 || host.hasSuffix("." + $0) }
		}
		if trackingParameters.contains(name) { return true }
		return trackingParameterPrefixes.contains { name.hasPrefix($0) }
	}
}

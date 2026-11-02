import BrowserRuntime
import Foundation

/// JavaScript that reads a page's color identity, plus the decoder for its JSON result.
///
/// The script posts its result back through the shared page-command channel
/// (`BrowserRuntimePageCommand`, name `siteTint.sample`, argument `payload`), tagged with a
/// token so late answers can be dropped. It also
/// returns the same JSON, for evaluation paths that hand results back directly.
///
/// Every color is normalized through a 1x1 canvas so named colors, `hsl()`, `oklch()` and
/// `color-mix()` all come back as plain RGBA bytes.
public enum BrowserSiteTintSampler {
	public static let messageKind = "siteTint"
	public static let commandName = "siteTint.sample"
	public static let payloadArgument = "payload"

	public static func script(token: Int) -> String {
		scriptTemplate
			.replacingOccurrences(of: "__TOKEN__", with: String(token))
			.replacingOccurrences(of: "__SEND__", with: BrowserRuntimePageCommand.javaScriptSendFunction)
	}

	static let scriptTemplate = #"""
	(function () {
	  function post(payload) {
	    payload.kind = 'siteTint';
	    payload.token = __TOKEN__;
	    var json = JSON.stringify(payload);
	    (__SEND__)('siteTint.sample', { payload: json });
	    return json;
	  }
	  try {
	    var canvas = document.createElement('canvas');
	    canvas.width = 1; canvas.height = 1;
	    var ctx = canvas.getContext('2d', { willReadFrequently: true });
	    function rgba(value) {
	      if (!ctx || !value) return null;
	      ctx.clearRect(0, 0, 1, 1);
	      ctx.fillStyle = 'rgba(0,0,0,0)';
	      ctx.fillStyle = String(value).trim();
	      ctx.fillRect(0, 0, 1, 1);
	      var d = ctx.getImageData(0, 0, 1, 1).data;
	      if (d[3] === 0) return null;
	      return [d[0], d[1], d[2], d[3]];
	    }
	    function opaqueBackground(el) {
	      var depth = 0;
	      while (el && el.nodeType === 1 && depth < 24) {
	        var c = rgba(getComputedStyle(el).backgroundColor);
	        if (c && c[3] >= 128) return c;
	        el = el.parentElement; depth += 1;
	      }
	      return null;
	    }
	    function at(x, y) {
	      try { return opaqueBackground(document.elementFromPoint(x, y)); } catch (e) { return null; }
	    }
	    var theme = null;
	    var metas = document.querySelectorAll('meta[name="theme-color" i]');
	    for (var i = 0; i < metas.length; i += 1) {
	      var media = metas[i].getAttribute('media');
	      if (!media || window.matchMedia(media).matches) {
	        theme = rgba(metas[i].getAttribute('content'));
	        if (theme) break;
	      }
	    }
	    var w = Math.max(1, window.innerWidth || 1);
	    var h = Math.max(1, window.innerHeight || 1);
	    var rootElement = document.documentElement;
	    var root = rootElement ? rgba(getComputedStyle(rootElement).backgroundColor) : null;
	    var body = document.body ? opaqueBackground(document.body) : null;
	    return post({
	      theme: theme,
	      bottom: at(w / 2, h - 3),
	      top: at(w / 2, 3),
	      background: body || root
	    });
	  } catch (error) {
	    return post({ error: String(error) });
	  }
	})()
	"""#

	/// Delays after a navigation at which the page is re-sampled, to catch theme-color set by
	/// scripts and headers painted after first load.
	public static let resampleDelays: [TimeInterval] = [0.15, 0.6, 1.5, 4.0]

	public struct Message: Equatable {
		public var token: Int?
		public var sample: BrowserSiteTintSample?
		public var error: String?
	}

	/// Decodes a page message. Returns nil when the payload isn't a site-tint message at all.
	public static func decodeMessage(_ json: String) -> Message? {
		guard let data = json.data(using: .utf8),
		      let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
		      payload["kind"] as? String == messageKind
		else { return nil }
		return Message(
			token: (payload["token"] as? NSNumber)?.intValue,
			sample: decode(json),
			error: payload["error"] as? String
		)
	}

	public static func decode(_ json: String) -> BrowserSiteTintSample? {
		var payloadText = json
		// Some bridges hand back the JSON string re-encoded as a JSON string literal.
		if let data = json.data(using: .utf8),
		   let unwrapped = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) as? String {
			payloadText = unwrapped
		}
		guard let data = payloadText.data(using: .utf8),
		      let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
		      payload["error"] == nil,
		      ["theme", "bottom", "top", "background"].contains(where: { payload.keys.contains($0) })
		else { return nil }

		func color(_ key: String) -> BrowserSiteTintColor? {
			guard let raw = payload[key] as? [Any] else { return nil }
			let numbers = raw.compactMap { ($0 as? NSNumber)?.doubleValue }
			return BrowserSiteTintColor(rgbaBytes: numbers)
		}
		return .init(
			themeColor: color("theme"),
			bottomEdge: color("bottom"),
			topEdge: color("top"),
			pageBackground: color("background")
		)
	}
}

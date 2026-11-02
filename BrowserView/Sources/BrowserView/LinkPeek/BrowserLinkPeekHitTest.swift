import Foundation

/// Experiment: Link Peek.
///
/// Finds the link under a point in the page, so the peek card can open from it.
/// The point and the returned rect are normalized (0...1) against the page viewport, which keeps
/// the math correct under page zoom and device scale without knowing either.
enum BrowserLinkPeekHitTest {
	struct NormalizedRect: Decodable, Equatable {
		let x: Double
		let y: Double
		let w: Double
		let h: Double
	}

	struct Payload: Decodable, Equatable {
		let found: Bool
		let href: String?
		let title: String?
		let rect: NormalizedRect?

		var link: Link? {
			guard found, let href, let url = URL(string: href) else { return nil }
			guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
			return Link(url: href, title: title?.isEmpty == false ? title : nil, normalizedRect: rect)
		}
	}

	struct Link: Equatable {
		let url: String
		let title: String?
		/// Top-left origin, normalized to the viewport.
		let normalizedRect: NormalizedRect?
	}

	/// Name of the page command that carries a hit-test result back to native code.
	static let pageCommandName = "linkPeek.hit"

	/// A JavaScript expression that evaluates to the JSON hit-test result for a point.
	/// - Parameters:
	///   - fx: horizontal position, 0 at the left edge of the viewport.
	///   - fy: vertical position, 0 at the top edge of the viewport.
	static func script(fx: Double, fy: Double) -> String {
		let x = fx.isFinite ? min(max(fx, 0), 1) : 0
		let y = fy.isFinite ? min(max(fy, 0), 1) : 0
		return "(\(hitTestFunction))(\(x), \(y))"
	}

	/// A JavaScript expression that evaluates to the JSON hit-test result for the first link
	/// visible in the viewport. Used by the debug keyboard trigger so the feature can be exercised
	/// without a pointer.
	static func firstVisibleLinkScript() -> String {
		"""
		(function () {
		  var vw = window.innerWidth || 1, vh = window.innerHeight || 1;
		  var links = document.querySelectorAll('a[href]');
		  for (var i = 0; i < links.length; i++) {
		    var r = links[i].getBoundingClientRect();
		    if (r.width > 0 && r.height > 0 && r.top >= 0 && r.left >= 0 && r.bottom <= vh && r.right <= vw
		        && /^https?:/i.test(links[i].href)) {
		      return (\(hitTestFunction))((r.left + r.width / 2) / vw, (r.top + r.height / 2) / vh);
		    }
		  }
		  return JSON.stringify({ found: false });
		})()
		"""
	}

	/// Wraps a hit-test expression so the page sends its result back through the page command channel.
	static func pageCommandScript(for expression: String, requestID: Int, sendFunction: String) -> String {
		"""
		(function () {
		  var result;
		  try { result = \(expression); } catch (e) { result = JSON.stringify({ found: false }); }
		  (\(sendFunction))('\(pageCommandName)', { id: '\(requestID)', result: result });
		})();
		"""
	}

	private static let hitTestFunction = """
	function (fx, fy) {
	  try {
	    var vw = window.innerWidth || 1, vh = window.innerHeight || 1;
	    var x = fx * vw, y = fy * vh;
	    var el = document.elementFromPoint(x, y);
	    while (el && el.shadowRoot) {
	      var inner = el.shadowRoot.elementFromPoint(x, y);
	      if (!inner || inner === el) break;
	      el = inner;
	    }
	    var a = null;
	    for (var n = el; n; n = n.parentNode || n.host || null) {
	      if (n.nodeType === 1 && (n.localName === 'a' || n.localName === 'area') && n.href) { a = n; break; }
	    }
	    if (!a) return JSON.stringify({ found: false });
	    var r = a.getBoundingClientRect();
	    var label = (a.getAttribute('aria-label') || a.title || a.textContent || '').replace(/\\s+/g, ' ').trim().slice(0, 200);
	    return JSON.stringify({
	      found: true,
	      href: String(a.href),
	      title: label,
	      rect: { x: r.left / vw, y: r.top / vh, w: r.width / vw, h: r.height / vh }
	    });
	  } catch (e) {
	    return JSON.stringify({ found: false });
	  }
	}
	"""

	static func parse(_ result: String?) -> Link? {
		guard let data = result?.data(using: .utf8) else { return nil }
		return (try? JSONDecoder().decode(Payload.self, from: data))?.link
	}
}

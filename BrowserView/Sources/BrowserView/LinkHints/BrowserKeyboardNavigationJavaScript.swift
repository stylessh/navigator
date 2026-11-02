import BrowserRuntime
import Foundation

/// Page scripts for the keyboard link hints experiment.
///
/// The work is split between the page and the app:
/// - The page knows whether a text field has focus, so it owns key detection and scrolling
///   (`makeInstallScript`). When the user presses `f`/`F` it asks the app to show hints through
///   the generic page command channel.
/// - The app owns the hint UI (native glass chips). It asks the page for clickable targets
///   (`collectTargetsScript`) and later activates the chosen one (`activateTargetScript`).
enum BrowserKeyboardNavigationJavaScript {
	static let showLinkHintsCommand = "linkHints.show"
	static let openInNewTabArgument = "newTab"
	/// Carries the collected targets back to the app (`payload` = JSON, `token` = request id).
	static let targetsCommand = "linkHints.targets"
	/// Asks the app to open `url` in a new tab after a hint was chosen with "open in new tab".
	static let openURLCommand = "linkHints.openURL"
	static let payloadArgument = "payload"
	static let tokenArgument = "token"
	static let urlArgument = "url"

	/// `CEFBridge_ExecuteJavaScriptWithResult` only reports that a script was dispatched, not
	/// its value, so scripts that need to answer the app post a page command instead.
	private static func targetsArguments(token: Int) -> String {
		"{ \(payloadArgument): payload, \(tokenArgument): \"\(token)\" }"
	}

	private static func emitCommandJavaScript(name: String, argumentsExpression: String) -> String {
		"""
		try { window.prompt("\(BrowserRuntimePageCommand.promptMessage)", JSON.stringify({ name: "\(name)", arguments: \(argumentsExpression) })); } catch (_) {}
		"""
	}

	/// Shared editable-focus test, embedded in each script so they can run independently.
	private static let isEditableFunction = """
	function __navIsEditable(el) {
	  while (el && el.shadowRoot && el.shadowRoot.activeElement) { el = el.shadowRoot.activeElement; }
	  if (!el || el === document.body || el === document.documentElement) { return false; }
	  if (el.isContentEditable) { return true; }
	  const tag = (el.tagName || "").toLowerCase();
	  if (tag === "textarea" || tag === "select") { return true; }
	  if (tag === "input") {
	    const type = (el.getAttribute("type") || "text").toLowerCase();
	    return ["button", "checkbox", "color", "file", "hidden", "image", "radio", "range", "reset", "submit"].indexOf(type) === -1;
	  }
	  const role = (el.getAttribute && el.getAttribute("role")) || "";
	  return role === "textbox" || role === "searchbox" || role === "combobox";
	}
	"""

	/// Installs the in-page key listener. Safe to evaluate many times: it replaces any
	/// previous listener so updated settings (for example `enabled: false`) take effect.
	static func makeInstallScript(enabled: Bool) -> String {
		"""
		(function() {
		  if (window.top !== window) { return "frame"; }
		  const previous = window.__navigatorKeyboardNavigation;
		  if (previous && previous.listener) {
		    window.removeEventListener("keydown", previous.listener, true);
		  }
		  if (!\(enabled ? "true" : "false")) {
		    window.__navigatorKeyboardNavigation = null;
		    return "disabled";
		  }
		  \(isEditableFunction)
		  const state = { pendingG: false, pendingGTimer: null };
		  const lineStep = 70;

		  function isScrollable(el) {
		    if (!el || el === document.body || el === document.documentElement) { return false; }
		    const style = getComputedStyle(el);
		    const overflowY = style.overflowY;
		    return (overflowY === "auto" || overflowY === "scroll" || overflowY === "overlay") &&
		      el.scrollHeight > el.clientHeight + 1;
		  }

		  function scrollTarget() {
		    const root = document.scrollingElement || document.documentElement;
		    if (root && root.scrollHeight > window.innerHeight + 1) { return null; }
		    // The document itself does not scroll (app-style layouts). Find the scroll container
		    // under the viewport center, walking up from the deepest element.
		    let el = document.elementFromPoint(window.innerWidth / 2, window.innerHeight / 2);
		    while (el) {
		      if (isScrollable(el)) { return el; }
		      el = el.parentElement;
		    }
		    return null;
		  }

		  function scrollByAmount(dy) {
		    const target = scrollTarget();
		    if (target) { target.scrollBy({ top: dy, behavior: "smooth" }); }
		    else { window.scrollBy({ top: dy, behavior: "smooth" }); }
		  }

		  function scrollToEdge(bottom) {
		    const target = scrollTarget();
		    if (target) { target.scrollTo({ top: bottom ? target.scrollHeight : 0, behavior: "smooth" }); }
		    else {
		      const root = document.scrollingElement || document.documentElement;
		      window.scrollTo({ top: bottom ? root.scrollHeight : 0, behavior: "smooth" });
		    }
		  }

		  function viewportHeight() {
		    const target = scrollTarget();
		    return target ? target.clientHeight : window.innerHeight;
		  }

		  function emit(name, args) {
		    try {
		      window.prompt("\(BrowserRuntimePageCommand.promptMessage)", JSON.stringify({ name: name, arguments: args || {} }));
		    } catch (_) {}
		  }

		  function clearPendingG() {
		    state.pendingG = false;
		    if (state.pendingGTimer) { clearTimeout(state.pendingGTimer); state.pendingGTimer = null; }
		  }

		  function listener(event) {
		    if (event.defaultPrevented || event.isComposing || event.repeat && (event.key === "f" || event.key === "F")) { return; }
		    if (event.metaKey || event.ctrlKey || event.altKey) { clearPendingG(); return; }
		    if (__navIsEditable(document.activeElement)) { clearPendingG(); return; }

		    let handled = true;
		    switch (event.key) {
		      case "f": emit("\(showLinkHintsCommand)", { "\(openInNewTabArgument)": "false" }); break;
		      case "F": emit("\(showLinkHintsCommand)", { "\(openInNewTabArgument)": "true" }); break;
		      case "j": scrollByAmount(lineStep); break;
		      case "k": scrollByAmount(-lineStep); break;
		      case "d": scrollByAmount(viewportHeight() / 2); break;
		      case "u": scrollByAmount(-viewportHeight() / 2); break;
		      case "G": scrollToEdge(true); break;
		      case "H": history.back(); break;
		      case "L": history.forward(); break;
		      case "g":
		        if (state.pendingG) { clearPendingG(); scrollToEdge(false); }
		        else {
		          state.pendingG = true;
		          state.pendingGTimer = setTimeout(clearPendingG, 800);
		        }
		        break;
		      default:
		        handled = false;
		    }
		    if (event.key !== "g") { clearPendingG(); }
		    if (handled) {
		      event.preventDefault();
		      event.stopImmediatePropagation();
		    }
		  }

		  window.addEventListener("keydown", listener, true);
		  window.__navigatorKeyboardNavigation = { listener: listener };
		  return "installed";
		})();
		"""
	}

	/// Collects visible clickable elements in the main frame and stores them on `window` so a
	/// later activation can reference them by index. Returns JSON:
	/// `{"viewport":{"width":…,"height":…},"targets":[{"x":…,"y":…,"width":…,"height":…,"kind":"link"}]}`
	static func collectTargetsScript(token: Int) -> String {
		"""
	(function() {
	  const selector = [
	    "a[href]", "button", "input:not([type=hidden])", "select", "textarea", "summary", "label[for]",
	    "[role=button]", "[role=link]", "[role=checkbox]", "[role=radio]", "[role=switch]", "[role=tab]",
	    "[role=menuitem]", "[role=menuitemcheckbox]", "[role=menuitemradio]", "[role=option]", "[role=treeitem]",
	    "[onclick]", "[contenteditable=''], [contenteditable=true]", "[tabindex]:not([tabindex='-1'])"
	  ].join(",");
	  const viewportWidth = window.innerWidth;
	  const viewportHeight = window.innerHeight;
	  const collected = [];
	  const seen = new Set();
	  const hinted = new Set();

	  function walk(root) {
	    const nodes = root.querySelectorAll(selector);
	    for (const el of nodes) { consider(el); }
	    const all = root.querySelectorAll("*");
	    for (const el of all) { if (el.shadowRoot) { walk(el.shadowRoot); } }
	  }

	  function kindOf(el) {
	    const tag = el.tagName.toLowerCase();
	    if (tag === "a") { return "link"; }
	    if (tag === "input" || tag === "textarea" || tag === "select" || el.isContentEditable) {
	      const type = (el.getAttribute("type") || "").toLowerCase();
	      if (["button", "submit", "reset", "checkbox", "radio", "image"].indexOf(type) !== -1) { return "button"; }
	      return "input";
	    }
	    return "button";
	  }

	  function visibleRect(el) {
	    const rects = el.getClientRects();
	    for (const rect of rects) {
	      if (rect.width < 3 || rect.height < 3) { continue; }
	      if (rect.bottom <= 0 || rect.right <= 0 || rect.top >= viewportHeight || rect.left >= viewportWidth) { continue; }
	      return rect;
	    }
	    return null;
	  }

	  function isOccluded(el, rect) {
	    const x = Math.min(Math.max(rect.left + Math.min(rect.width / 2, 12), 0), viewportWidth - 1);
	    const y = Math.min(Math.max(rect.top + rect.height / 2, 0), viewportHeight - 1);
	    let hit = document.elementFromPoint(x, y);
	    while (hit && hit.shadowRoot) {
	      const inner = hit.shadowRoot.elementFromPoint(x, y);
	      if (!inner || inner === hit) { break; }
	      hit = inner;
	    }
	    if (!hit) { return true; }
	    if (hit === el || el.contains(hit) || hit.contains(el)) { return false; }
	    // Labels and wrappers commonly sit on top of the real control.
	    if (hit.tagName && hit.tagName.toLowerCase() === "label" && hit.control === el) { return false; }
	    return true;
	  }

	  function consider(el) {
	    if (seen.has(el)) { return; }
	    seen.add(el);
	    if (el.disabled || el.getAttribute("aria-hidden") === "true") { return; }
	    // Skip elements nested in a link or button we already hint, e.g. a <span> inside an <a>.
	    const parentControl = el.parentElement && el.parentElement.closest("a[href], button, [role=button], [role=link]");
	    if (parentControl && hinted.has(parentControl)) { return; }
	    const style = getComputedStyle(el);
	    if (style.visibility === "hidden" || style.display === "none" || parseFloat(style.opacity) === 0) { return; }
	    const rect = visibleRect(el);
	    if (!rect || isOccluded(el, rect)) { return; }
	    hinted.add(el);
	    collected.push({ el: el, rect: rect, kind: kindOf(el) });
	  }

	  walk(document);
	  const limit = 600;
	  const items = collected.slice(0, limit);
	  window.__navigatorLinkHintTargets = items.map(function(item) { return item.el; });
	  const payload = JSON.stringify({
	    viewport: { width: viewportWidth, height: viewportHeight },
	    targets: items.map(function(item) {
	      return {
	        x: Math.max(item.rect.left, 0),
	        y: Math.max(item.rect.top, 0),
	        width: item.rect.width,
	        height: item.rect.height,
	        kind: item.kind
	      };
	    })
	  });
	  \(emitCommandJavaScript(name: targetsCommand, argumentsExpression: targetsArguments(token: token)))
	  return payload;
	})();
	"""
	}

	/// Activates the target at `index` from the last collection. Returns JSON:
	/// `{"result":"clicked"|"focused"|"openURL"|"missing","url":"…"}`.
	/// When `openInNewTab` is true and the target is a link, the page does not navigate; the app
	/// opens the returned URL in a new tab instead.
	static func activateTargetScript(index: Int, openInNewTab: Bool) -> String {
		"""
		(function() {
		  const targets = window.__navigatorLinkHintTargets || [];
		  const el = targets[\(index)];
		  window.__navigatorLinkHintTargets = null;
		  if (!el || !el.isConnected) { return JSON.stringify({ result: "missing" }); }
		  \(isEditableFunction)
		  const tag = el.tagName.toLowerCase();
		  if (\(openInNewTab ? "true" : "false") && tag === "a" && el.href) {
		    const url = el.href;
		    \(emitCommandJavaScript(name: openURLCommand, argumentsExpression: "{ \(urlArgument): url }"))
		    return JSON.stringify({ result: "openURL", url: url });
		  }
		  if (__navIsEditable(el)) {
		    el.focus({ preventScroll: true });
		    if (typeof el.select === "function" && tag === "input") { try { el.select(); } catch (_) {} }
		    if (tag === "select" && typeof el.showPicker === "function") { try { el.showPicker(); } catch (_) {} }
		    return JSON.stringify({ result: "focused" });
		  }
		  const rect = el.getBoundingClientRect();
		  const init = {
		    bubbles: true, cancelable: true, composed: true, view: window,
		    clientX: rect.left + rect.width / 2, clientY: rect.top + rect.height / 2, button: 0
		  };
		  try {
		    el.dispatchEvent(new PointerEvent("pointerover", init));
		    el.dispatchEvent(new MouseEvent("mouseover", init));
		    el.dispatchEvent(new PointerEvent("pointerdown", Object.assign({ pointerType: "mouse", isPrimary: true }, init)));
		    el.dispatchEvent(new MouseEvent("mousedown", Object.assign({ buttons: 1 }, init)));
		    if (typeof el.focus === "function") { el.focus({ preventScroll: true }); }
		    el.dispatchEvent(new PointerEvent("pointerup", Object.assign({ pointerType: "mouse", isPrimary: true }, init)));
		    el.dispatchEvent(new MouseEvent("mouseup", init));
		  } catch (_) {}
		  el.click();
		  return JSON.stringify({ result: "clicked" });
		})();
		"""
	}

	/// Clears any stored targets, used when hint mode is cancelled.
	static let clearTargetsScript = "window.__navigatorLinkHintTargets = null;"
}

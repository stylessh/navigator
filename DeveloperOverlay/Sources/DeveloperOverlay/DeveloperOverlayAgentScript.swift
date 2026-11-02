import Foundation

/// JavaScript that runs inside the page's main world to feed the overlay.
///
/// The agent is installed lazily the first time the overlay polls a page, and again after each
/// navigation (a new document drops it). It keeps bounded ring buffers of console messages and
/// network activity, each stamped with a monotonically increasing revision, so the native side can
/// ask for "everything after revision N" without the page ever pushing to us.
///
/// Every script here is a single expression whose value is a string, so the host can carry it over
/// whatever transport it has (the app wraps it and returns the value via the page-command prompt
/// channel; see `NavigatorDeveloperOverlayPageChannel`).
public enum DeveloperOverlayAgentScript {
	public static let version = 1
	public static let globalName = "__navigatorDevHUD"
	/// Returned by `poll(...)` when the agent isn't installed in the current document yet.
	public static let missingSentinel = "__navigator_devhud_missing__"

	// BEGIN AGENT
	public static let install: String = #"""
	(function () {
	  var NAME = "__navigatorDevHUD";
	  var VERSION = 1;
	  if (window[NAME] && window[NAME].version === VERSION) { return "present"; }

	  var MAX_CONSOLE = 500;
	  var MAX_NETWORK = 400;
	  var rev = 0;
	  var consoleSeq = 0;
	  var networkSeq = 0;
	  var consoleEntries = [];
	  var networkEntries = [];
	  var networkByID = {};
	  var picked = null;
	  var pickedRev = 0;
	  var picking = false;

	  function nextRev() { rev += 1; return rev; }

	  function trim(list, max, onDrop) {
	    while (list.length > max) {
	      var dropped = list.shift();
	      if (onDrop) { onDrop(dropped); }
	    }
	  }

	  function preview(value, depth, seen) {
	    depth = depth || 0;
	    seen = seen || [];
	    var type = typeof value;
	    if (value === null) { return "null"; }
	    if (value === undefined) { return "undefined"; }
	    if (type === "string") { return depth === 0 ? value : JSON.stringify(value); }
	    if (type === "number" || type === "boolean" || type === "bigint") { return String(value); }
	    if (type === "symbol") { return value.toString(); }
	    if (type === "function") { return "ƒ " + (value.name || "anonymous") + "()"; }
	    if (value instanceof Error) { return (value.name || "Error") + ": " + value.message; }
	    if (typeof Element !== "undefined" && value instanceof Element) {
	      var desc = "<" + value.tagName.toLowerCase();
	      if (value.id) { desc += " id=\"" + value.id + "\""; }
	      if (value.classList && value.classList.length) { desc += " class=\"" + Array.prototype.join.call(value.classList, " ") + "\""; }
	      return desc + ">";
	    }
	    if (seen.indexOf(value) !== -1) { return "[Circular]"; }
	    if (depth > 2) { return Array.isArray(value) ? "[…]" : "{…}"; }
	    seen.push(value);
	    try {
	      if (Array.isArray(value)) {
	        var items = value.slice(0, 20).map(function (item) { return preview(item, depth + 1, seen); });
	        if (value.length > 20) { items.push("… " + (value.length - 20) + " more"); }
	        return "[" + items.join(", ") + "]";
	      }
	      var keys = Object.keys(value);
	      var parts = keys.slice(0, 20).map(function (key) {
	        var inner;
	        try { inner = preview(value[key], depth + 1, seen); } catch (e) { inner = "?"; }
	        return key + ": " + inner;
	      });
	      if (keys.length > 20) { parts.push("…"); }
	      var ctor = value.constructor && value.constructor.name;
	      var prefix = ctor && ctor !== "Object" ? ctor + " " : "";
	      return prefix + "{" + parts.join(", ") + "}";
	    } catch (e) {
	      return Object.prototype.toString.call(value);
	    } finally {
	      seen.pop();
	    }
	  }

	  function formatArgs(args) {
	    var list = Array.prototype.slice.call(args);
	    if (typeof list[0] === "string" && list[0].indexOf("%") !== -1) {
	      var format = list.shift();
	      format = format.replace(/%[sdifoOc]/g, function (token) {
	        if (!list.length) { return token; }
	        var next = list.shift();
	        if (token === "%c") { return ""; }
	        if (token === "%d" || token === "%i") { return String(parseInt(next, 10)); }
	        if (token === "%f") { return String(parseFloat(next)); }
	        return preview(next, token === "%s" ? 0 : 1);
	      });
	      list.unshift(format);
	    }
	    var text = list.map(function (item) { return preview(item, 0); }).join(" ");
	    return text.length > 4000 ? text.slice(0, 4000) + "…" : text;
	  }

	  function callSite() {
	    try {
	      var stack = (new Error()).stack || "";
	      var lines = stack.split("\n").slice(1);
	      for (var i = 0; i < lines.length; i += 1) {
	        var line = lines[i];
	        if (line.indexOf(NAME) !== -1 || line.indexOf("<anonymous>") !== -1) { continue; }
	        var match = line.match(/(https?:\/\/[^\s)]+|file:\/\/[^\s)]+)/);
	        if (match) {
	          var parts = match[1].split("/");
	          return parts[parts.length - 1];
	        }
	      }
	    } catch (e) {}
	    return null;
	  }

	  function pushConsole(level, text, source) {
	    consoleSeq += 1;
	    consoleEntries.push({ id: consoleSeq, rev: nextRev(), level: level, text: text, source: source, ts: Date.now() });
	    trim(consoleEntries, MAX_CONSOLE);
	  }

	  ["log", "info", "warn", "error", "debug"].forEach(function (level) {
	    var original = console[level];
	    if (typeof original !== "function") { return; }
	    console[level] = function () {
	      try { pushConsole(level, formatArgs(arguments), callSite()); } catch (e) {}
	      return original.apply(this, arguments);
	    };
	  });

	  window.addEventListener("error", function (event) {
	    if (event.target && event.target !== window && event.target.tagName) {
	      var target = event.target;
	      var url = target.src || target.href || "";
	      pushConsole("error", "Failed to load " + target.tagName.toLowerCase() + ": " + url, null);
	      return;
	    }
	    var location = event.filename ? event.filename.split("/").pop() + ":" + event.lineno : null;
	    pushConsole("error", "Uncaught " + (event.error ? preview(event.error) : event.message), location);
	  }, true);

	  window.addEventListener("unhandledrejection", function (event) {
	    pushConsole("error", "Unhandled promise rejection: " + preview(event.reason), null);
	  });

	  // Network --------------------------------------------------------------

	  function upsertNetwork(entry) {
	    entry.rev = nextRev();
	    if (!networkByID[entry.id]) {
	      networkByID[entry.id] = entry;
	      networkEntries.push(entry);
	      trim(networkEntries, MAX_NETWORK, function (dropped) { delete networkByID[dropped.id]; });
	    }
	    return entry;
	  }

	  function absoluteURL(input) {
	    try {
	      var raw = typeof input === "string" ? input : (input && input.url) || String(input);
	      return new URL(raw, location.href).href;
	    } catch (e) {
	      return String(input);
	    }
	  }

	  function now() { return performance.now(); }

	  // Skip timing entries for requests the fetch / XHR hooks already report.
	  var hookedURLs = {};

	  if (typeof window.fetch === "function") {
	    var originalFetch = window.fetch;
	    window.fetch = function (input, init) {
	      networkSeq += 1;
	      var url = absoluteURL(input);
	      var method = ((init && init.method) || (input && input.method) || "GET").toUpperCase();
	      var entry = upsertNetwork({ id: "f" + networkSeq, kind: "fetch", method: method, url: url, start: now() });
	      hookedURLs[url] = (hookedURLs[url] || 0) + 1;
	      var promise;
	      try {
	        promise = originalFetch.apply(this, arguments);
	      } catch (error) {
	        entry.error = String(error);
	        entry.duration = now() - entry.start;
	        upsertNetwork(entry);
	        throw error;
	      }
	      return promise.then(function (response) {
	        entry.status = response.status;
	        entry.duration = now() - entry.start;
	        entry.mime = response.headers.get("content-type");
	        var length = parseInt(response.headers.get("content-length") || "", 10);
	        if (!isNaN(length)) { entry.size = length; }
	        upsertNetwork(entry);
	        return response;
	      }, function (error) {
	        entry.error = error && error.name === "AbortError" ? "Aborted" : String(error);
	        entry.duration = now() - entry.start;
	        upsertNetwork(entry);
	        throw error;
	      });
	    };
	  }

	  if (typeof XMLHttpRequest !== "undefined") {
	    var originalOpen = XMLHttpRequest.prototype.open;
	    var originalSend = XMLHttpRequest.prototype.send;
	    XMLHttpRequest.prototype.open = function (method, url) {
	      this.__navigatorDevHUD = { method: String(method || "GET").toUpperCase(), url: absoluteURL(url) };
	      return originalOpen.apply(this, arguments);
	    };
	    XMLHttpRequest.prototype.send = function () {
	      var info = this.__navigatorDevHUD;
	      if (info) {
	        networkSeq += 1;
	        var entry = upsertNetwork({ id: "x" + networkSeq, kind: "xhr", method: info.method, url: info.url, start: now() });
	        hookedURLs[info.url] = (hookedURLs[info.url] || 0) + 1;
	        var xhr = this;
	        xhr.addEventListener("loadend", function () {
	          entry.status = xhr.status;
	          entry.duration = now() - entry.start;
	          try { entry.mime = xhr.getResponseHeader("content-type"); } catch (e) {}
	          if (xhr.status === 0) { entry.error = "Network error"; }
	          upsertNetwork(entry);
	        });
	      }
	      return originalSend.apply(this, arguments);
	    };
	  }

	  function kindForInitiator(initiator, name) {
	    switch (initiator) {
	      case "script": return "script";
	      case "link": case "css": return /\.(woff2?|ttf|otf)(\?|$)/i.test(name) ? "font" : "stylesheet";
	      case "img": case "image": return "image";
	      case "video": case "audio": return "media";
	      case "navigation": return "document";
	      default:
	        if (/\.(woff2?|ttf|otf)(\?|$)/i.test(name)) { return "font"; }
	        if (/\.(png|jpe?g|gif|webp|avif|svg|ico)(\?|$)/i.test(name)) { return "image"; }
	        if (/\.css(\?|$)/i.test(name)) { return "stylesheet"; }
	        if (/\.m?js(\?|$)/i.test(name)) { return "script"; }
	        return "other";
	    }
	  }

	  function recordTiming(timing) {
	    var initiator = timing.initiatorType;
	    if (initiator === "fetch" || initiator === "xmlhttprequest" || initiator === "beacon") {
	      if (hookedURLs[timing.name]) {
	        hookedURLs[timing.name] -= 1;
	        return;
	      }
	      // Requests made before the agent was installed only exist as timing entries.
	    }
	    networkSeq += 1;
	    var kind = initiator === "fetch" ? "fetch" : (initiator === "xmlhttprequest" ? "xhr" : kindForInitiator(initiator, timing.name));
	    upsertNetwork({
	      id: "t" + networkSeq,
	      kind: kind,
	      method: "GET",
	      url: timing.name,
	      start: timing.startTime,
	      duration: timing.duration,
	      status: typeof timing.responseStatus === "number" && timing.responseStatus > 0 ? timing.responseStatus : null,
	      size: timing.transferSize > 0 ? timing.transferSize : (timing.encodedBodySize > 0 ? timing.encodedBodySize : null)
	    });
	  }

	  try {
	    var navigation = performance.getEntriesByType("navigation")[0];
	    if (navigation) { recordTiming(navigation); }
	    if (typeof PerformanceObserver !== "undefined") {
	      var observer = new PerformanceObserver(function (list) { list.getEntries().forEach(recordTiming); });
	      observer.observe({ type: "resource", buffered: true });
	    }
	  } catch (e) {}

	  // Element picker -------------------------------------------------------

	  var highlight = null;
	  var label = null;
	  var hovered = null;

	  function ensureHighlight() {
	    if (highlight) { return; }
	    highlight = document.createElement("div");
	    highlight.setAttribute("data-navigator-devhud", "highlight");
	    highlight.style.cssText = [
	      "position:fixed", "pointer-events:none", "z-index:2147483646", "box-sizing:border-box",
	      "border:1.5px solid rgba(10,132,255,0.95)", "background:rgba(10,132,255,0.14)",
	      "border-radius:3px", "transition:all 120ms cubic-bezier(0.2,0.9,0.3,1.2)", "display:none"
	    ].join(";");
	    label = document.createElement("div");
	    label.setAttribute("data-navigator-devhud", "label");
	    label.style.cssText = [
	      "position:fixed", "pointer-events:none", "z-index:2147483647", "padding:3px 7px",
	      "font:500 11px -apple-system,BlinkMacSystemFont,sans-serif", "color:white",
	      "background:rgba(10,132,255,0.95)", "border-radius:6px", "white-space:nowrap",
	      "box-shadow:0 4px 14px rgba(0,0,0,0.25)", "transition:all 120ms ease-out", "display:none"
	    ].join(";");
	    (document.body || document.documentElement).appendChild(highlight);
	    (document.body || document.documentElement).appendChild(label);
	  }

	  function removeHighlight() {
	    if (highlight && highlight.parentNode) { highlight.parentNode.removeChild(highlight); }
	    if (label && label.parentNode) { label.parentNode.removeChild(label); }
	    highlight = null;
	    label = null;
	  }

	  function isOwnNode(node) {
	    return node && node.getAttribute && node.getAttribute("data-navigator-devhud") !== null;
	  }

	  function shortName(element) {
	    var name = element.tagName.toLowerCase();
	    if (element.id) { name += "#" + element.id; }
	    var classes = Array.prototype.slice.call(element.classList || [], 0, 2);
	    if (classes.length) { name += "." + classes.join("."); }
	    return name;
	  }

	  function cssEscape(value) {
	    return window.CSS && CSS.escape ? CSS.escape(value) : value.replace(/[^a-zA-Z0-9_-]/g, "\\$&");
	  }

	  function selectorFor(element) {
	    if (element.id) { return "#" + cssEscape(element.id); }
	    var parts = [];
	    var current = element;
	    while (current && current.nodeType === 1 && parts.length < 5) {
	      var part = current.tagName.toLowerCase();
	      if (current.id) {
	        parts.unshift("#" + cssEscape(current.id));
	        break;
	      }
	      var classes = Array.prototype.slice.call(current.classList || [], 0, 2).map(cssEscape);
	      if (classes.length) { part += "." + classes.join("."); }
	      var parent = current.parentElement;
	      if (parent) {
	        var siblings = Array.prototype.filter.call(parent.children, function (child) { return child.tagName === current.tagName; });
	        if (siblings.length > 1) { part += ":nth-of-type(" + (siblings.indexOf(current) + 1) + ")"; }
	      }
	      parts.unshift(part);
	      if (current.tagName === "BODY" || current.tagName === "HTML") { break; }
	      current = parent;
	    }
	    return parts.join(" > ");
	  }

	  function edges(style, prefix, suffix) {
	    suffix = suffix || "";
	    return {
	      t: parseFloat(style[prefix + "Top" + suffix]) || 0,
	      r: parseFloat(style[prefix + "Right" + suffix]) || 0,
	      b: parseFloat(style[prefix + "Bottom" + suffix]) || 0,
	      l: parseFloat(style[prefix + "Left" + suffix]) || 0
	    };
	  }

	  function describe(element) {
	    var rect = element.getBoundingClientRect();
	    var style = getComputedStyle(element);
	    var family = (style.fontFamily || "").split(",")[0].replace(/["']/g, "").trim();
	    var text = (element.innerText || element.textContent || "").replace(/\s+/g, " ").trim();
	    var styles = {
	      display: style.display,
	      position: style.position,
	      font: style.fontWeight + " " + style.fontSize + "/" + style.lineHeight + " " + family,
	      color: style.color,
	      background: style.backgroundColor,
	      radius: style.borderRadius,
	      opacity: style.opacity
	    };
	    if (style.gap && style.gap !== "normal") { styles.gap = style.gap; }
	    if (style.zIndex && style.zIndex !== "auto") { styles["z-index"] = style.zIndex; }
	    return {
	      selector: selectorFor(element),
	      tag: element.tagName.toLowerCase(),
	      id: element.id || null,
	      classes: Array.prototype.slice.call(element.classList || []),
	      rect: { x: rect.left, y: rect.top, w: rect.width, h: rect.height },
	      margin: edges(style, "margin"),
	      padding: edges(style, "padding"),
	      border: edges(style, "border", "Width"),
	      styles: styles,
	      text: text ? text.slice(0, 140) : null,
	      children: element.children ? element.children.length : 0
	    };
	  }

	  function moveHighlight(element) {
	    ensureHighlight();
	    var rect = element.getBoundingClientRect();
	    highlight.style.display = "block";
	    highlight.style.left = rect.left + "px";
	    highlight.style.top = rect.top + "px";
	    highlight.style.width = rect.width + "px";
	    highlight.style.height = rect.height + "px";
	    label.style.display = "block";
	    label.textContent = shortName(element) + "  " + Math.round(rect.width) + " × " + Math.round(rect.height);
	    var labelTop = rect.top - 26;
	    if (labelTop < 4) { labelTop = rect.bottom + 6; }
	    label.style.top = labelTop + "px";
	    label.style.left = Math.max(4, Math.min(rect.left, window.innerWidth - 220)) + "px";
	  }

	  function onMove(event) {
	    var element = document.elementFromPoint(event.clientX, event.clientY);
	    if (!element || isOwnNode(element) || element === hovered) { return; }
	    hovered = element;
	    moveHighlight(element);
	  }

	  function swallow(event) {
	    event.preventDefault();
	    event.stopPropagation();
	    if (event.stopImmediatePropagation) { event.stopImmediatePropagation(); }
	  }

	  function onClick(event) {
	    swallow(event);
	    var element = document.elementFromPoint(event.clientX, event.clientY) || hovered;
	    if (element && !isOwnNode(element)) {
	      picked = describe(element);
	      pickedRev = nextRev();
	      pickedElement = element;
	      moveHighlight(element);
	    }
	    stopPicking(true);
	  }

	  function onKey(event) {
	    if (event.key === "Escape") {
	      swallow(event);
	      stopPicking(false);
	    }
	  }

	  var pickedElement = null;

	  function startPicking() {
	    if (picking) { return; }
	    picking = true;
	    hovered = null;
	    ensureHighlight();
	    document.addEventListener("mousemove", onMove, true);
	    document.addEventListener("click", onClick, true);
	    document.addEventListener("mousedown", swallow, true);
	    document.addEventListener("mouseup", swallow, true);
	    document.addEventListener("keydown", onKey, true);
	    document.documentElement.style.cursor = "crosshair";
	  }

	  function stopPicking(keepHighlight) {
	    if (!picking) { return; }
	    picking = false;
	    document.removeEventListener("mousemove", onMove, true);
	    document.removeEventListener("click", onClick, true);
	    document.removeEventListener("mousedown", swallow, true);
	    document.removeEventListener("mouseup", swallow, true);
	    document.removeEventListener("keydown", onKey, true);
	    document.documentElement.style.cursor = "";
	    if (!keepHighlight) { removeHighlight(); }
	  }

	  function clearPicked() {
	    picked = null;
	    pickedElement = null;
	    pickedRev = nextRev();
	    removeHighlight();
	  }

	  function inspectSelector(selector) {
	    var element = document.querySelector(selector);
	    if (!element) { return "not found"; }
	    stopPicking(true);
	    picked = describe(element);
	    pickedRev = nextRev();
	    pickedElement = element;
	    moveHighlight(element);
	    return "ok";
	  }

	  function refreshPicked() {
	    if (!pickedElement || !pickedElement.isConnected) { return; }
	    picked = describe(pickedElement);
	    pickedRev = nextRev();
	    moveHighlight(pickedElement);
	  }

	  window.addEventListener("scroll", function () { if (pickedElement && !picking) { moveHighlight(pickedElement); } }, true);
	  window.addEventListener("resize", function () { if (pickedElement && !picking) { refreshPicked(); } });

	  // Console prompt -------------------------------------------------------

	  function report(value) {
	    if (value && typeof value.then === "function") {
	      value.then(function (resolved) {
	        pushConsole("result", "Promise resolved: " + preview(resolved, 1), null);
	      }, function (error) {
	        pushConsole("error", "Promise rejected: " + preview(error, 1), null);
	      });
	      return JSON.stringify({ ok: true, text: "Promise {<pending>}" });
	    }
	    return JSON.stringify({ ok: true, text: preview(value, 1) });
	  }

	  function evaluate(source) {
	    try {
	      return report((0, eval)(source));
	    } catch (error) {
	      // A CSP without 'unsafe-eval' blocks eval; native then re-sends the source inlined.
	      var blocked = !!(error && error.name === "EvalError");
	      return JSON.stringify({ ok: false, blocked: blocked, text: preview(error, 0) });
	    }
	  }

	  // Runs a function built natively from the user's source (the CSP-safe path).
	  function evaluateInline(run) {
	    try {
	      return report(run());
	    } catch (error) {
	      return JSON.stringify({ ok: false, text: preview(error, 0) });
	    }
	  }

	  // Polling --------------------------------------------------------------

	  // The page's own accent, used to tint the overlay glass (meta theme-color, else the body background).
	  function isColorful(css) {
	    var m = /rgba?\(\s*(\d+)[,\s]+(\d+)[,\s]+(\d+)/.exec(css);
	    if (!m) { return false; }
	    var r = +m[1] / 255, g = +m[2] / 255, b = +m[3] / 255;
	    var max = Math.max(r, g, b), min = Math.min(r, g, b);
	    return max > 0 && (max - min) / max > 0.25;
	  }

	  function themeColor() {
	    try {
	      var meta = document.querySelector('meta[name="theme-color"]:not([media]), meta[name="theme-color"]');
	      if (meta && meta.content) {
	        var probe = document.createElement("span");
	        probe.style.color = meta.content;
	        probe.style.display = "none";
	        document.documentElement.appendChild(probe);
	        var resolved = getComputedStyle(probe).color;
	        probe.parentNode.removeChild(probe);
	        if (resolved) { return resolved; }
	      }
	      // Otherwise the color of whatever sits along the top edge (a site header or nav bar).
	      // Probe a few rows, since body margins (8px on HN) push the bar below the very top, and
	      // prefer a colorful fill over a neutral page wrapper.
	      var rows = [4, 12, 24, 40];
	      var neutral = null;
	      for (var r = 0; r < rows.length; r += 1) {
	        var top = document.elementFromPoint(Math.floor(window.innerWidth / 2), rows[r]);
	        for (var node = top, depth = 0; node && node.nodeType === 1 && depth < 6; node = node.parentElement, depth += 1) {
	          if (node === document.body || node === document.documentElement) { break; }
	          var fill = getComputedStyle(node).backgroundColor;
	          if (!fill || fill === "rgba(0, 0, 0, 0)" || fill === "transparent") { continue; }
	          if (isColorful(fill)) { return fill; }
	          if (!neutral) { neutral = fill; }
	        }
	      }
	      if (neutral) { return neutral; }
	      var candidates = [document.body, document.documentElement];
	      for (var i = 0; i < candidates.length; i += 1) {
	        if (!candidates[i]) { continue; }
	        var background = getComputedStyle(candidates[i]).backgroundColor;
	        if (background && background !== "rgba(0, 0, 0, 0)" && background !== "transparent") { return background; }
	      }
	    } catch (e) {}
	    return null;
	  }

	  function drain(since) {
	    since = since || 0;
	    var consoleOut = [];
	    var networkOut = [];
	    for (var i = 0; i < consoleEntries.length; i += 1) {
	      if (consoleEntries[i].rev > since) { consoleOut.push(consoleEntries[i]); }
	    }
	    for (var j = 0; j < networkEntries.length; j += 1) {
	      if (networkEntries[j].rev > since) { networkOut.push(networkEntries[j]); }
	    }
	    return JSON.stringify({
	      v: VERSION,
	      rev: rev,
	      console: consoleOut,
	      network: networkOut,
	      picked: pickedRev > since ? { value: picked } : null,
	      picking: picking,
	      url: location.href,
	      title: document.title,
	      theme: themeColor(),
	      viewport: { w: window.innerWidth, h: window.innerHeight, dpr: window.devicePixelRatio || 1 }
	    });
	  }

	  window[NAME] = {
	    version: VERSION,
	    drain: drain,
	    evaluate: evaluate,
	    evaluateInline: evaluateInline,
	    startPicking: startPicking,
	    stopPicking: function () { stopPicking(false); },
	    clearPicked: clearPicked,
	    inspectSelector: inspectSelector,
	    refreshPicked: refreshPicked
	  };
	  return "installed";
	})()
	"""#
	// END AGENT

	/// Polls the agent for everything newer than `revision`.
	/// Evaluates to the JSON payload, or `missingSentinel` when the document has no agent.
	public static func poll(since revision: Int) -> String {
		"""
		(window.\(globalName) && window.\(globalName).version === \(version)) \
		? window.\(globalName).drain(\(max(0, revision))) : "\(missingSentinel)"
		"""
	}

	/// Calls one agent method, installing the agent first if the document doesn't have it yet.
	public static func call(_ method: String, arguments: [String] = []) -> String {
		let argumentList = arguments.map(jsStringLiteral).joined(separator: ", ")
		return """
		(function () { \
		if (!(window.\(globalName) && window.\(globalName).version === \(version))) { \(install); } \
		var result = window.\(globalName).\(method)(\(argumentList)); \
		return result === undefined ? "ok" : result; \
		})()
		"""
	}

	/// Selects the first element matching `selector`, as if it had been picked.
	public static func inspect(selector: String) -> String {
		call("inspectSelector", arguments: [selector])
	}

	public static func evaluate(_ source: String) -> String {
		call("evaluate", arguments: [source])
	}

	/// The same evaluation with `source` inlined as an expression instead of passed to `eval`, for
	/// pages whose CSP forbids `unsafe-eval` (injected scripts aren't subject to the page's CSP).
	/// Statements don't parse here; the caller reports that as a timeout.
	public static func evaluateInline(_ source: String) -> String {
		"""
		(function () { \
		if (!(window.\(globalName) && window.\(globalName).version === \(version))) { \(install); } \
		return window.\(globalName).evaluateInline(function () { return (
		\(source)
		); }); \
		})()
		"""
	}

	public static let startPicking = call("startPicking")
	public static let stopPicking = call("stopPicking")
	public static let clearPicked = call("clearPicked")
	public static let refreshPicked = call("refreshPicked")

	/// Encodes a Swift string as a JavaScript string literal (JSON is a subset of JS literals,
	/// except for U+2028/U+2029 which we escape explicitly).
	public static func jsStringLiteral(_ value: String) -> String {
		guard
			let data = try? JSONSerialization.data(withJSONObject: [value], options: [.fragmentsAllowed]),
			var encoded = String(data: data, encoding: .utf8)
		else {
			return "\"\""
		}
		// Strip the surrounding array brackets.
		encoded.removeFirst()
		encoded.removeLast()
		return encoded
			.replacingOccurrences(of: "\u{2028}", with: "\\u2028")
			.replacingOccurrences(of: "\u{2029}", with: "\\u2029")
	}
}

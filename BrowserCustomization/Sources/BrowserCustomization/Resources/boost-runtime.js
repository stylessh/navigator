// Navigator boost runtime. Injected into the main frame of every page that has a boost.
// Idempotent: evaluating it again only upgrades the runtime when VERSION changes.
// Native code talks to it through window.__navigatorBoost (see BoostScriptBuilder.swift).
(function () {
  "use strict";
  var VERSION = 2;
  // Captured at install so a page that overrides window.prompt can't intercept native messages.
  var nativePrompt = window.prompt;
  var PAGE_COMMAND = "__navigatorPageCommand__";
  var existing = window.__navigatorBoost;
  if (existing && existing.version >= VERSION) { return; }

  var sheets = new Map();        // id -> { sheet, styleEl, revision }
  var ranScripts = new Map();    // id -> revision already executed in this document
  var stickyObserver = null;
  var stickyScheduled = false;
  var picker = null;
  var pendingPick = null;

  var supportsAdopted = (function () {
    try { return "adoptedStyleSheets" in Document.prototype && typeof CSSStyleSheet === "function" && !!new CSSStyleSheet().replaceSync; }
    catch (e) { return false; }
  })();

  // ---------- Styles ----------

  function applySheet(id, css, revision) {
    var current = sheets.get(id);
    if (current && current.revision === revision) { return; }
    if (supportsAdopted) {
      var sheet = current && current.sheet ? current.sheet : new CSSStyleSheet();
      try { sheet.replaceSync(css); } catch (e) { /* invalid CSS is ignored rule by rule */ }
      if (!current) { document.adoptedStyleSheets = document.adoptedStyleSheets.concat([sheet]); }
      sheets.set(id, { sheet: sheet, styleEl: null, revision: revision });
    } else {
      var el = current && current.styleEl ? current.styleEl : document.createElement("style");
      el.setAttribute("data-navigator-boost", id);
      el.textContent = css;
      if (!el.isConnected) { (document.head || document.documentElement).appendChild(el); }
      sheets.set(id, { sheet: null, styleEl: el, revision: revision });
    }
  }

  function removeSheet(id) {
    var current = sheets.get(id);
    if (!current) { return; }
    if (current.sheet) {
      document.adoptedStyleSheets = document.adoptedStyleSheets.filter(function (s) { return s !== current.sheet; });
    }
    if (current.styleEl) { current.styleEl.remove(); }
    sheets.delete(id);
  }

  // ---------- Sticky bar tagging (for the "hide sticky bars" preset) ----------

  function tagStickyElements() {
    stickyScheduled = false;
    var vw = window.innerWidth, vh = window.innerHeight;
    var all = document.body ? document.body.getElementsByTagName("*") : [];
    for (var i = 0; i < all.length; i++) {
      var el = all[i];
      if (el.hasAttribute("data-navigator-sticky")) { continue; }
      var pos = getComputedStyle(el).position;
      if (pos !== "fixed" && pos !== "sticky") { continue; }
      var r = el.getBoundingClientRect();
      var wide = r.width >= vw * 0.6;
      var edge = r.top <= 4 || r.bottom >= vh - 4;
      var bar = r.height > 0 && r.height <= vh * 0.35;
      if (wide && edge && bar) { el.setAttribute("data-navigator-sticky", ""); }
    }
  }

  function scheduleStickyTagging() {
    if (stickyScheduled) { return; }
    stickyScheduled = true;
    if (window.requestIdleCallback) { window.requestIdleCallback(tagStickyElements, { timeout: 300 }); }
    else { window.setTimeout(tagStickyElements, 200); }
  }

  function setStickyTagging(enabled) {
    if (enabled && !stickyObserver) {
      stickyObserver = new MutationObserver(scheduleStickyTagging);
      stickyObserver.observe(document.documentElement, { childList: true, subtree: true });
      window.addEventListener("scroll", scheduleStickyTagging, { passive: true });
      scheduleStickyTagging();
    } else if (!enabled && stickyObserver) {
      stickyObserver.disconnect();
      stickyObserver = null;
      window.removeEventListener("scroll", scheduleStickyTagging);
      var tagged = document.querySelectorAll("[data-navigator-sticky]");
      for (var i = 0; i < tagged.length; i++) { tagged[i].removeAttribute("data-navigator-sticky"); }
    }
  }

  // ---------- Selector generation (for the zap picker) ----------

  function cssEscape(value) {
    return window.CSS && CSS.escape ? CSS.escape(value) : String(value).replace(/[^a-zA-Z0-9_-]/g, "\\$&");
  }

  // Classes that look generated (CSS modules, hashes, utility soup) make brittle selectors.
  function isStableClass(name) {
    if (name.length > 32 || name.length < 2) { return false; }
    if (/[0-9a-f]{5,}/i.test(name)) { return false; }
    if (/^(css|sc|jsx|emotion|svelte)-/.test(name)) { return false; }
    if (/__[a-zA-Z0-9]{5}$/.test(name)) { return false; }
    if (/[:\[\]\/]/.test(name)) { return false; }
    return true;
  }

  function isUnique(selector) {
    try { return document.querySelectorAll(selector).length === 1; } catch (e) { return false; }
  }

  function stepFor(el) {
    var tag = el.tagName.toLowerCase();
    if (el.id && /^[a-zA-Z][\w-]*$/.test(el.id) && !/\d{3,}/.test(el.id)) {
      return { selector: "#" + cssEscape(el.id), anchored: true };
    }
    var stableAttrs = ["data-testid", "data-test", "aria-label", "role", "name"];
    for (var i = 0; i < stableAttrs.length; i++) {
      var value = el.getAttribute(stableAttrs[i]);
      if (value && value.length <= 40) {
        var attrSel = tag + "[" + stableAttrs[i] + "=\"" + value.replace(/"/g, "\\\"") + "\"]";
        if (isUnique(attrSel)) { return { selector: attrSel, anchored: true }; }
      }
    }
    var classes = Array.prototype.filter.call(el.classList, isStableClass).slice(0, 3);
    var base = tag + classes.map(function (c) { return "." + cssEscape(c); }).join("");
    var parent = el.parentElement;
    if (parent) {
      // Disambiguate among siblings that the tag+class selector can't tell apart.
      var lookalikes = Array.prototype.filter.call(parent.children, function (c) {
        try { return c.matches(base); } catch (e) { return false; }
      });
      if (lookalikes.length > 1) {
        var sameTag = Array.prototype.filter.call(parent.children, function (c) { return c.tagName === el.tagName; });
        base += ":nth-of-type(" + (sameTag.indexOf(el) + 1) + ")";
      }
    }
    return { selector: base, anchored: false };
  }

  function selectorFor(el) {
    if (!el || el.nodeType !== 1) { return ""; }
    var parts = [];
    var node = el;
    for (var depth = 0; node && node.nodeType === 1 && depth < 6; depth++) {
      if (node === document.body || node === document.documentElement) { break; }
      var step = stepFor(node);
      parts.unshift(step.selector);
      var candidate = parts.join(" > ");
      if (step.anchored || isUnique(candidate)) { return candidate; }
      node = node.parentElement;
    }
    return parts.join(" > ");
  }

  // ---------- Zap picker ----------

  function startPicker(accent) {
    if (picker) { return "active"; }
    pendingPick = null;
    var host = document.createElement("navigator-boost-picker");
    host.style.cssText = "all: initial; position: fixed; inset: 0; z-index: 2147483647; pointer-events: none;";
    var root = host.attachShadow({ mode: "closed" });
    var color = accent || "#0A84FF";
    root.innerHTML =
      "<style>" +
      ".box{position:fixed;border-radius:6px;background:" + color + "22;outline:2px solid " + color + ";" +
      "transition:all .18s cubic-bezier(.2,1.3,.4,1);pointer-events:none}" +
      ".tag{position:fixed;font:600 11px -apple-system,system-ui;color:#fff;background:" + color + ";" +
      "padding:3px 7px;border-radius:6px;white-space:nowrap;max-width:60vw;overflow:hidden;text-overflow:ellipsis;" +
      "transition:all .18s cubic-bezier(.2,1.3,.4,1);pointer-events:none}" +
      // Top-center: the floating toolbar owns the bottom edge of the window.
      ".hint{position:fixed;left:50%;top:18px;transform:translateX(-50%);font:500 12px -apple-system,system-ui;" +
      "color:#fff;background:rgba(20,20,22,.78);backdrop-filter:blur(20px);padding:8px 14px;border-radius:999px}" +
      "</style><div class=box></div><div class=tag></div>" +
      "<div class=hint>Click to hide · ↑ widen · ↓ narrow · Esc to cancel</div>";
    (document.body || document.documentElement).appendChild(host);
    var box = root.querySelector(".box");
    var tag = root.querySelector(".tag");
    var target = null;
    var trail = [];

    function show(el) {
      target = el;
      if (!el) { box.style.opacity = "0"; tag.style.opacity = "0"; return; }
      var r = el.getBoundingClientRect();
      box.style.opacity = "1"; tag.style.opacity = "1";
      box.style.left = r.left + "px"; box.style.top = r.top + "px";
      box.style.width = r.width + "px"; box.style.height = r.height + "px";
      tag.textContent = selectorFor(el);
      tag.style.left = Math.max(4, r.left) + "px";
      tag.style.top = (r.top > 24 ? r.top - 22 : r.bottom + 4) + "px";
    }

    function onMove(event) {
      var el = document.elementFromPoint(event.clientX, event.clientY);
      if (el && el !== host && el !== target) { trail = []; show(el); }
    }
    function swallow(event) { event.preventDefault(); event.stopPropagation(); event.stopImmediatePropagation(); }
    function onClick(event) {
      swallow(event);
      if (target) { finish(selectorFor(target)); }
    }
    function onKey(event) {
      if (event.key === "Escape") { swallow(event); finish(""); }
      else if (event.key === "ArrowUp" && target && target.parentElement && target.parentElement !== document.body) {
        swallow(event); trail.push(target); show(target.parentElement);
      } else if (event.key === "ArrowDown" && trail.length) {
        swallow(event); show(trail.pop());
      } else if (event.key === "Enter" && target) {
        swallow(event); finish(selectorFor(target));
      }
    }

    function finish(selector) {
      window.removeEventListener("mousemove", onMove, true);
      window.removeEventListener("click", onClick, true);
      window.removeEventListener("mousedown", swallow, true);
      window.removeEventListener("mouseup", swallow, true);
      window.removeEventListener("keydown", onKey, true);
      host.remove();
      picker = null;
      pendingPick = { selector: selector, cancelled: selector === "" };
      post("boost.pick", { selector: selector, cancelled: selector === "" ? "true" : "false" });
    }

    window.addEventListener("mousemove", onMove, true);
    window.addEventListener("click", onClick, true);
    window.addEventListener("mousedown", swallow, true);
    window.addEventListener("mouseup", swallow, true);
    window.addEventListener("keydown", onKey, true);
    picker = { finish: finish };
    return "started";
  }

  // ---------- Page -> native ----------

  // Native code can't read evaluation results, so the page posts them back as page commands.
  // Arguments must be strings.
  function post(name, args) {
    try { nativePrompt.call(window, PAGE_COMMAND, JSON.stringify({ name: name, arguments: args || {} })); }
    catch (e) { /* no native host (tests, or prompt blocked) */ }
  }

  function report(token, fn) {
    var args = { token: String(token) };
    try {
      var value = fn();
      if (value === null || value === undefined) { args.isNull = "true"; args.value = ""; }
      else { args.value = typeof value === "string" ? value : JSON.stringify(value); }
    } catch (error) {
      args.error = String(error && error.message || error);
    }
    post("boost.result", args);
    return "reported";
  }

  // ---------- Public API ----------

  var api = {
    version: VERSION,

    // entries: [{ id, css, revision, tagSticky }]. Anything not listed is removed.
    sync: function (entries) {
      var keep = new Set();
      var wantsSticky = false;
      entries.forEach(function (entry) {
        keep.add(entry.id);
        applySheet(entry.id, entry.css || "", entry.revision);
        if (entry.tagSticky) { wantsSticky = true; }
      });
      Array.from(sheets.keys()).forEach(function (id) { if (!keep.has(id)) { removeSheet(id); } });
      setStickyTagging(wantsSticky);
      return "ok";
    },

    // Runs fn at most once per (document, id, revision).
    runOnce: function (id, revision, fn) {
      if (ranScripts.get(id) === revision) { return "skipped"; }
      ranScripts.set(id, revision);
      try { fn(); return "ran"; }
      catch (error) { console.error("[Navigator boost " + id + "]", error); return "error:" + (error && error.message); }
    },

    activeIDs: function () { return Array.from(sheets.keys()); },

    startPicker: startPicker,
    cancelPicker: function () { if (picker) { picker.finish(""); } return "ok"; },
    // Returns "" while picking, otherwise JSON { selector, cancelled } exactly once.
    takePick: function () {
      if (!pendingPick) { return picker ? "" : JSON.stringify({ selector: "", cancelled: true, idle: true }); }
      var result = JSON.stringify(pendingPick);
      pendingPick = null;
      return result;
    },
    selectorFor: selectorFor,
    post: post,
    report: report,
    countMatches: function (selector) {
      try { return document.querySelectorAll(selector).length; } catch (e) { return -1; }
    },
  };

  if (existing) {
    // Upgrade path: carry over applied sheets from an older runtime.
    try { existing.sync([]); } catch (e) {}
  }
  Object.defineProperty(window, "__navigatorBoost", { value: api, configurable: true, writable: false, enumerable: false });
})();

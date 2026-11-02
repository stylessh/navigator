# Site customization and extensibility (experiment)

Status: prototype behind **Settings → Experiments → Site boosts & actions** (on by default).
Branch: `claude/project-thread-vu6gsw`, stacked on the floating toolbar branch.

## Goal

Let people reshape any site, and add their own browser actions, without a browser extension
store and without AI. It should feel like Arc Boosts: quick to start (one click hides something),
with a path to full CSS/JS for people who want it. And it should be calm: everything is a plain
file you can version, diff and edit in your own editor.

## What exists in this prototype

| Piece | Where | What it does |
| --- | --- | --- |
| Boost model and store | `BrowserCustomization/…/Boost.swift`, `BoostStore.swift` | Per-site CSS, presets, zapped selectors, opt-in JS and a tint preference. Each boost is saved as a folder of files. |
| Page runtime | `Resources/boost-runtime.js` | An idempotent script that applies styles through `adoptedStyleSheets`, runs user scripts once per revision, tags sticky bars, and runs the element picker. |
| Script builder | `BoostScriptBuilder.swift` | Turns boosts into the JS strings that native code evaluates, with JSON-escaped payloads and stable FNV revisions. |
| Action registry (plugin API) | `NavigatorActions.swift` | `NavigatorAction` with placements (`toolbar`, `commandBar`, `pageMenu`), availability, and `perform(context, performer)`. |
| Built-in actions | `BuiltInActions.swift` | Zap Element (⌥⌘Z), Customize This Site (⌥⌘B), Toggle Site Boost, Copy Clean Link (⌥⇧⌘C), and one toggle per preset. |
| User actions | `UserActionManifest.swift` | JSON manifests in `~/Library/Application Support/Navigator/Actions/`, run as `openURL` templates or page `script`s. Two examples are seeded on first launch. |
| Panel UI | `BrowserCustomizationUI/` | The glass panel (Liquid Glass on macOS 26, with `.ultraThinMaterial` as the macOS 15 fallback). It has spring-driven chips, rows and the entrance. |
| Browser glue | `BrowserView/…/SiteCustomization/` | Page lifecycle hooks, injection, picker polling, the panel window, and the `NavigatorActionPerformer` implementation. |
| App glue | `Navigator/BrowserRootViewController+SiteCustomization.swift` | Toasts, mapping toolbar actions into the floating toolbar's trailing slot, and shortcuts. |

### Boost files

```
~/Library/Application Support/Navigator/Boosts/
  news-ycombinator-com/
    boost.json   {"id","name","matches":["news.ycombinator.com"],"enabled":true,
                  "presets":["readable-width"],"zaps":[".ad"],"tint":"#FF6600",
                  "allowJavaScript":false,"runAt":"commit"}
    style.css
    script.js    (ignored unless allowJavaScript is true)
```

Match patterns: `*`, `host.com` (with `www.`), `*.host.com` (apex and subdomains), and
`host.com/path*`. When several boosts match a page, they apply from least to most specific, so a
site boost beats a global one in the cascade.

### Injection lifecycle

1. **Commit** (address change): sync styles, then run `runAt: commit` scripts.
2. **Load end** (loading goes from true to false): sync again, because some SPAs reset `<head>` while booting, then run `runAt: idle` scripts.
3. **Edit** (panel or external editor): re-sync every live tab, so changes show up with no reload.

Sync is declarative. Native code sends the full list of boosts for the page, and the runtime adds,
updates or removes sheets to match it. That's why turning a boost off works without a reload.
Pages that never had a matching boost get no script at all.

`adoptedStyleSheets` matters here because it isn't subject to `style-src` CSP, so boosts still
apply on strict sites like GitHub. The JS test suite checks this against a strict CSP.

## Decisions and trade-offs

- **CSS-first, JS opt-in per site.** User JS runs in the page's main world with full access, so
  it's off until the person flips a clearly labeled switch for that site.
- **Files over a database.** Boosts sync with dotfiles, iCloud Drive or git for free. A 500 ms
  fingerprint poll reloads them; FSEvents would be the production path.
- **Results come back as page commands.** Neither CEF evaluate path returns values reliably (the
  browser-process one only reports `{"dispatched":true}`), so the runtime posts results back through
  the shared page-command channel (`window.prompt("__navigatorPageCommand__", json)`, the same
  channel link hints uses). The runtime posts `boost.pick` when the picker finishes, and
  `boost.result` (with a token) for `evaluateInPage`, which match counts, `{selection}` and
  script actions use. The runtime keeps its own copy of `window.prompt` from install time, so a page
  that overrides `prompt` can't intercept them.
- **Injection uses `frame->ExecuteJavaScript` on commit, not document start.** That can cause a
  brief flash of unstyled content on heavy pages. The fix is to inject the sync script from
  `OnContextCreated` in the renderer process, where the camera shim is already installed.
- **The registry knows nothing about UI.** The toolbar, command bar and page menu each ask for
  `actions(for: placement, context:)`. The toolbar thread's trailing accessory slot is fed
  from this registry, and the command-bar thread can do the same.
- **Tint.** A boost's `tint` (`auto` / `off` / `#hex`) is published through
  `SiteCustomizationCenter.onTintPreferenceChange`. The site-tint experiment exposes
  `BrowserSiteTintStore.setOverride(_:forHost:)`. Once both branches land, the bridge is a few lines:

  ```swift
  center.onTintPreferenceChange = { host, preference in
      switch preference {
      case .automatic: BrowserSiteTintStore.setOverride(nil, forHost: host)
      case .off: BrowserSiteTintStore.setOverride(.disabled, forHost: host)
      case let .custom(hex): BrowserSiteTintStore.setOverride(BrowserSiteTintColor(hex: hex).map { .color($0) }, forHost: host)
      }
  }
  ```

## Plugin API, next steps

1. **Declarative manifests (shipped here).** Safe and portable, and enough for "open this page in
   X" or small page scripts.
2. **Command-bar integration.** Whichever of this PR and the command bar PR (#6) merges second
   maps actions into `AppViewModel.commandBarCommands()`. Pass every action with an empty query,
   because the bar does its own fuzzy ranking:
   `CommandBarCommand(id: "site:\(action.id)", title: action.title, symbolName: action.systemImage,
   keywords: action.keywords, shortcut: action.shortcutHint) { siteCustomization.perform(actionID: action.id) }`.
3. **Page menu.** A right-click "Page" submenu built from the `.pageMenu` placement.
4. **Native plugin bundles (design only).** `.navigatorplugin` bundles that load in a separate
   XPC helper and talk over a narrow, versioned protocol (`NavigatorActionPerformer` is that
   protocol's first draft). Never load them in-process.
5. **Boost gallery and sharing.** Export a boost folder as a single `.navigatorboost` file, and
   preview it before installing (CSS diff, plus a warning if it has JS).

## More ideas to try

- **Per-site defaults beyond styling:** zoom level, reader mode, autoplay, and whether
  links open in a peek.
- **Boost "lenses":** temporary, unsaved boosts that a shortcut toggles, like "hide everything
  except the article" while reading.
- **Smart zap suggestions:** after a zap, show how many similar elements exist and offer
  "hide all like this" (selector without `:nth-of-type`).
- **Scoped user CSS variables:** a tiny token layer (`--nav-accent`, `--nav-font`) the page
  can use, set from the panel.

## Testing

- `node BrowserCustomization/JSTests/boost-runtime.test.js` runs the page runtime in headless
  Chromium: CSP, sync and removal, run-once, sticky tagging, selector generation, the picker
  (hover, widen, click, Escape), and SPA body swaps. It needs the `playwright` npm package.
- `swift test` in `BrowserCustomization/` covers patterns, decoding, the store's round-trip
  through files, script escaping, Clean Link, manifests, and the registry.

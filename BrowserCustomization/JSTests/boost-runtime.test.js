// Exercises boost-runtime.js in real headless Chromium (same engine as CEF).
// Run: node BrowserCustomization/JSTests/boost-runtime.test.js
const { chromium } = require("playwright");
const fs = require("fs");
const path = require("path");
const assert = require("assert");

const runtime = fs.readFileSync(path.join(__dirname, "../Sources/BrowserCustomization/Resources/boost-runtime.js"), "utf8");

const PAGE = `<!doctype html><html><head>
<meta http-equiv="Content-Security-Policy" content="style-src 'self'; script-src 'self' 'unsafe-inline'">
</head><body>
<header id="top">Sticky header</header>
<main><div class="card">One</div><div class="card promo-x8f7a2c">Two</div><div class="card">Three</div>
<aside data-testid="sidebar-ad">Ad</aside><p><span>deep</span></p></main>
</body></html>`;

let failures = 0;
async function test(name, fn) {
  try { await fn(); console.log("ok   " + name); }
  catch (error) { failures++; console.log("FAIL " + name + "\n     " + (error && error.stack || error)); }
}

(async () => {
  const browser = await chromium.launch();
  const page = await browser.newPage({ viewport: { width: 1000, height: 700 } });
  await page.setContent(PAGE);
  // The CSP blocks inline style attributes, so position the header through CSSOM (which CSP allows).
  await page.evaluate(() => Object.assign(document.querySelector("#top").style, { position: "fixed", top: "0", left: "0", right: "0", height: "60px" }));
  await page.evaluate(() => { document.querySelector("main").style.marginTop = "100px"; });
  const install = () => page.evaluate(runtime);
  const sync = (entries) => page.evaluate((e) => window.__navigatorBoost.sync(e), entries);
  const display = (sel) => page.evaluate((s) => getComputedStyle(document.querySelector(s)).display, sel);

  await test("installs idempotently", async () => {
    await install(); await install();
    assert.strictEqual(await page.evaluate(() => window.__navigatorBoost.version), 1);
  });

  await test("applies CSS despite a strict style-src CSP (adoptedStyleSheets)", async () => {
    await sync([{ id: "a", css: "main .card { display: none !important }", revision: "1" }]);
    assert.strictEqual(await display(".card"), "none");
  });

  await test("updates in place and removes boosts not listed", async () => {
    await sync([{ id: "a", css: "aside { display: none }", revision: "2" }]);
    assert.strictEqual(await display(".card"), "block");
    assert.strictEqual(await display("aside"), "none");
    await sync([]);
    assert.strictEqual(await display("aside"), "block");
    assert.deepStrictEqual(await page.evaluate(() => window.__navigatorBoost.activeIDs()), []);
  });

  await test("runOnce runs a script once per revision", async () => {
    const results = await page.evaluate(() => {
      window.__count = 0;
      const b = window.__navigatorBoost, f = () => { window.__count++; };
      return [b.runOnce("s", "1", f), b.runOnce("s", "1", f), b.runOnce("s", "2", f), window.__count];
    });
    assert.deepStrictEqual(results, ["ran", "skipped", "ran", 2]);
  });

  await test("runOnce contains user script errors", async () => {
    const r = await page.evaluate(() => window.__navigatorBoost.runOnce("bad", "1", () => { throw new Error("boom"); }));
    assert.strictEqual(r, "error:boom");
  });

  await test("tags sticky bars for the hide-sticky preset", async () => {
    await sync([{ id: "s", css: "[data-navigator-sticky] { display: none !important }", revision: "1", tagSticky: true }]);
    await page.waitForFunction(() => document.querySelector("[data-navigator-sticky]"), null, { timeout: 2000 });
    assert.strictEqual(await display("#top"), "none");
    await sync([]);
    assert.strictEqual(await page.evaluate(() => document.querySelectorAll("[data-navigator-sticky]").length), 0);
  });

  await test("selectorFor prefers ids and stable attributes, skips hashed classes", async () => {
    const sels = await page.evaluate(() => {
      const b = window.__navigatorBoost;
      return [b.selectorFor(document.querySelector("#top")),
              b.selectorFor(document.querySelector("aside")),
              b.selectorFor(document.querySelectorAll(".card")[1]),
              b.selectorFor(document.querySelector("span"))];
    });
    assert.strictEqual(sels[0], "#top");
    assert.strictEqual(sels[1], 'aside[data-testid="sidebar-ad"]');
    assert.ok(!sels[2].includes("promo-x8f7a2c"), "hashed class leaked: " + sels[2]);
    for (const s of sels) {
      assert.strictEqual(await page.evaluate((x) => document.querySelectorAll(x).length, s), 1, "not unique: " + s);
    }
  });

  await test("zap picker: hover, widen with ArrowUp, click returns selector once", async () => {
    assert.strictEqual(await page.evaluate(() => window.__navigatorBoost.startPicker("#FF2D55")), "started");
    assert.strictEqual(await page.evaluate(() => window.__navigatorBoost.takePick()), "");
    const box = await page.locator("span").boundingBox();
    await page.mouse.move(box.x + 2, box.y + 2);
    await page.keyboard.press("ArrowUp"); // span -> p
    await page.keyboard.press("Enter");
    const pick = JSON.parse(await page.evaluate(() => window.__navigatorBoost.takePick()));
    assert.strictEqual(pick.cancelled, false);
    assert.strictEqual(await page.evaluate((s) => document.querySelector(s).tagName, pick.selector), "P");
    const again = JSON.parse(await page.evaluate(() => window.__navigatorBoost.takePick()));
    assert.strictEqual(again.idle, true);
    assert.strictEqual(await page.evaluate(() => document.querySelector("navigator-boost-picker")), null);
  });

  await test("zap picker: click does not reach the page", async () => {
    await page.evaluate(() => { window.__clicked = 0; document.querySelector(".card").addEventListener("click", () => window.__clicked++); });
    await page.evaluate(() => window.__navigatorBoost.startPicker());
    await page.locator(".card").first().click();
    const pick = JSON.parse(await page.evaluate(() => window.__navigatorBoost.takePick()));
    assert.ok(pick.selector.length > 0);
    assert.strictEqual(await page.evaluate(() => window.__clicked), 0);
  });

  await test("zap picker: Escape cancels", async () => {
    await page.evaluate(() => window.__navigatorBoost.startPicker());
    await page.keyboard.press("Escape");
    const pick = JSON.parse(await page.evaluate(() => window.__navigatorBoost.takePick()));
    assert.strictEqual(pick.cancelled, true);
  });

  await test("countMatches reports invalid selectors as -1", async () => {
    assert.strictEqual(await page.evaluate(() => window.__navigatorBoost.countMatches(".card")), 3);
    assert.strictEqual(await page.evaluate(() => window.__navigatorBoost.countMatches("[[")), -1);
  });

  await test("styles survive a full SPA body swap", async () => {
    await sync([{ id: "a", css: ".card { color: rgb(255, 0, 0) }", revision: "9" }]);
    await page.evaluate(() => { document.body.innerHTML = '<div class="card">new</div>'; });
    assert.strictEqual(await page.evaluate(() => getComputedStyle(document.querySelector(".card")).color), "rgb(255, 0, 0)");
  });

  await browser.close();
  console.log(failures ? `\n${failures} failing` : "\nall passing");
  process.exit(failures ? 1 : 0);
})();

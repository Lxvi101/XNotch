// Browser end-to-end test of encrypted drops against a running server, in headless Chromium.
// Not part of `cargo test` (it needs a server and a browser):
//
//   PUBLIC_URL=http://127.0.0.1:8791 PORT=8791 API_TOKEN=test-token-0123456789 DATA_DIR=$(mktemp -d) \
//     cargo run &
//   XNE_URL=http://127.0.0.1:8791 XNE_TOKEN=test-token-0123456789 \
//     PLAYWRIGHT_CORE=/path/to/node_modules/playwright-core [CHROMIUM=/path/to/chrome] \
//     node tests/e2ee/browser.mjs
//
// To include a drop made by the Swift app, first run the Swift live test with
// XNE_SWIFT_DROP=/tmp/xne-swift-drop.json (see CloudServerTests), then pass the same variable here.
//
// It uploads like the Mac app would (with the independent encoder in reference.mjs), then
// checks what a recipient's browser does: decrypts names and files, refuses wrong, missing
// and damaged keys, never hands over a tampered or truncated file, keeps the key across the
// password form, and talks to nobody but the server.

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { createRequire } from "node:module";

import { SEGMENT, hex, pattern, randomBytes, seal, sha256 } from "./reference.mjs";

const URL_BASE = process.env.XNE_URL ?? "http://127.0.0.1:8791";
const TOKEN = process.env.XNE_TOKEN ?? "test-token-0123456789";
const { chromium } = createRequire(import.meta.url)(process.env.PLAYWRIGHT_CORE ?? "playwright-core");

async function api(method, path, body, json = false) {
  const headers = { Authorization: `Bearer ${TOKEN}` };
  if (json) headers["Content-Type"] = "application/json";
  const response = await fetch(URL_BASE + path, { method, headers, body });
  const text = await response.text();
  assert.ok(response.ok, `${method} ${path}: ${response.status} ${text}`);
  return text ? JSON.parse(text) : null;
}

async function makeDrop({ title, files, password }) {
  const created = await api("POST", "/api/drops", JSON.stringify({ e2ee: 1, expires_in: 3600, password }), true);
  assert.equal(created.e2ee, 1);
  const key = randomBytes(32);
  const entries = [];
  const sealedFiles = [];
  for (const file of files) {
    const id = hex(randomBytes(16));
    const sealed = await seal(file.data, { key, kind: "file", dropId: created.id, objectId: id });
    await api("PUT", `/api/drops/${created.id}/files/${id}`, sealed);
    entries.push({ id, name: file.name, size: file.data.length });
    sealedFiles.push(sealed);
  }
  const manifest = new TextEncoder().encode(JSON.stringify({ v: 1, title, files: entries }));
  await api("PUT", `/api/drops/${created.id}/manifest`, await seal(manifest, { key, kind: "manifest", dropId: created.id }));
  return { ...created, key, fragment: Buffer.from(key).toString("base64url"), entries, sealedFiles };
}

const executablePath =
  process.env.CHROMIUM ??
  `${process.env.HOME}/Library/Caches/ms-playwright/chromium_headless_shell-1223/chrome-headless-shell-mac-arm64/chrome-headless-shell`;
const browser = await chromium.launch({ executablePath });
const origin = new URL(URL_BASE).origin;
let failures = 0;

async function check(name, body) {
  const context = await browser.newContext({ acceptDownloads: true });
  const page = await context.newPage();
  const foreign = [];
  const errors = [];
  page.on("request", (r) => {
    const url = r.url();
    if (!url.startsWith(origin) && !url.startsWith("blob:") && !url.startsWith("data:")) foreign.push(url);
  });
  page.on("pageerror", (e) => errors.push(String(e)));
  try {
    await body(page, context);
    assert.deepEqual(foreign, [], "requests to other origins");
    assert.deepEqual(errors, [], "uncaught page errors");
    console.log(`ok - ${name}`);
  } catch (e) {
    failures++;
    console.log(`not ok - ${name}\n  ${String(e.stack || e).split("\n").join("\n  ")}`);
  } finally {
    await context.close();
  }
}

async function downloadVia(page, index) {
  const [download] = await Promise.all([
    page.waitForEvent("download", { timeout: 20000 }),
    page.locator("#files button").nth(index).click()
  ]);
  return { name: download.suggestedFilename(), bytes: readFileSync(await download.path()) };
}

async function expectNoDownload(page, index, messagePart) {
  let downloaded = false;
  page.on("download", () => (downloaded = true));
  await page.locator("#files button").nth(index).click();
  const size = page.locator("#files .size").nth(index);
  await size.filter({ hasText: messagePart }).waitFor({ timeout: 20000 });
  await page.waitForTimeout(500);
  assert.equal(downloaded, false, "a download started anyway");
}

const big = pattern(3 * SEGMENT + 4321);
const small = new TextEncoder().encode("Hello from XNotch 🎉\n");
const drop = await makeDrop({
  title: "Quarterly <b>numbers</b>",
  files: [
    { name: "Résumé final.txt", data: small },
    { name: "big/../data.bin", data: big },
    { name: "empty.txt", data: new Uint8Array(0) }
  ]
});

await check("decrypts the manifest and every file", async (page) => {
  const response = await page.goto(`${drop.url}#${drop.fragment}`);
  const html = await response.text();
  for (const secret of ["Quarterly", "Résumé", "data.bin", drop.fragment]) assert.ok(!html.includes(secret), secret);
  await page.locator("#files li").nth(2).waitFor();
  assert.equal(await page.locator("#title").textContent(), "Quarterly <b>numbers</b>");
  assert.equal(await page.locator("#title b").count(), 0, "title must be text, not HTML");
  assert.match(await page.title(), /^Quarterly <b>numbers<\/b> · /);
  assert.equal(await page.locator("#details").textContent(), " · 3 files · 3.2 MB");
  assert.deepEqual(await page.locator("#files .name").allTextContents(), ["Résumé final.txt", "big_.._data.bin", "empty.txt"]);

  const first = await downloadVia(page, 0);
  assert.equal(first.name, "Résumé final.txt");
  assert.equal(sha256(first.bytes), sha256(small));
  const second = await downloadVia(page, 1);
  assert.equal(second.name, "big_.._data.bin");
  assert.equal(sha256(second.bytes), sha256(big));
  const third = await downloadVia(page, 2);
  assert.equal(third.bytes.length, 0);
  assert.match(await page.locator("#files .size").nth(1).textContent(), /Decrypted/);
});

await check("a link without its key explains what is missing", async (page) => {
  await page.goto(drop.url);
  await page.locator("#notice").filter({ hasText: "missing its key" }).waitFor();
  assert.equal(await page.locator("#files li").count(), 0);
});

await check("a damaged key is reported as damaged", async (page) => {
  await page.goto(`${drop.url}#${drop.fragment.slice(0, 40)}`);
  await page.locator("#notice").filter({ hasText: "damaged" }).waitFor();
});

await check("a wrong key opens nothing", async (page) => {
  await page.goto(`${drop.url}#${Buffer.from(randomBytes(32)).toString("base64url")}`);
  await page.locator("#notice").filter({ hasText: "doesn't open these files" }).waitFor();
  assert.equal(await page.locator("#files li").count(), 0);
});

await check("a tampered or truncated file is never handed over", async (page) => {
  const tampered = await makeDrop({ title: "T", files: [{ name: "a.bin", data: big }, { name: "b.bin", data: big }] });
  const flipped = Uint8Array.from(tampered.sealedFiles[0]);
  flipped[flipped.length - 100] ^= 1; // inside the last segment: earlier segments do decrypt
  await api("PUT", `/api/drops/${tampered.id}/files/${tampered.entries[0].id}`, flipped);
  const cut = tampered.sealedFiles[1].subarray(0, tampered.sealedFiles[1].length - SEGMENT);
  await api("PUT", `/api/drops/${tampered.id}/files/${tampered.entries[1].id}`, cut);

  await page.goto(`${tampered.url}#${tampered.fragment}`);
  await page.locator("#files li").nth(1).waitFor();
  await expectNoDownload(page, 0, "changed or damaged");
  await expectNoDownload(page, 1, "incomplete or altered");
});

await check("large files stream to disk, and a failure discards the partial file", async (page, context) => {
  const tampered = await makeDrop({ title: "Disk", files: [{ name: "ok.bin", data: big }, { name: "bad.bin", data: big }] });
  const flipped = Uint8Array.from(tampered.sealedFiles[1]);
  flipped[flipped.length - 1] ^= 1;
  await api("PUT", `/api/drops/${tampered.id}/files/${tampered.entries[1].id}`, flipped);

  // Forces the File System Access path for small files, and stands in for the save dialog.
  await context.route(`${tampered.url}`, async (route) => {
    const response = await route.fetch();
    const body = (await response.text()).replace('<div id="e2ee" ', '<div id="e2ee" data-memory-limit="1" ');
    await route.fulfill({ response, body });
  });
  await page.addInitScript(() => {
    window.__saved = [];
    window.showSaveFilePicker = async (options) => {
      const file = { name: options.suggestedName, parts: [], closed: false, aborted: false };
      window.__saved.push(file);
      return {
        createWritable: async () => ({
          write: async (chunk) => file.parts.push(new Uint8Array(chunk)),
          close: async () => (file.closed = true),
          abort: async () => (file.aborted = true)
        })
      };
    };
  });
  await page.goto(`${tampered.url}#${tampered.fragment}`);
  await page.locator("#files li").nth(1).waitFor();
  await page.locator("#files button").nth(0).click();
  await page.locator("#files .size").nth(0).filter({ hasText: "Decrypted" }).waitFor();
  await page.locator("#files button").nth(1).click();
  await page.locator("#files .size").nth(1).filter({ hasText: "changed or damaged" }).waitFor();

  const saved = await page.evaluate(async () =>
    Promise.all(
      window.__saved.map(async (f) => {
        const digest = await crypto.subtle.digest("SHA-256", await new Blob(f.parts).arrayBuffer());
        const hash = Array.from(new Uint8Array(digest), (b) => b.toString(16).padStart(2, "0")).join("");
        return { name: f.name, closed: f.closed, aborted: f.aborted, hash, writes: f.parts.length };
      })
    )
  );
  assert.equal(saved.length, 2);
  assert.deepEqual(
    { name: saved[0].name, closed: saved[0].closed, aborted: saved[0].aborted, hash: saved[0].hash },
    { name: "ok.bin", closed: true, aborted: false, hash: sha256(big) }
  );
  assert.ok(saved[0].writes >= 4, "written segment by segment");
  assert.deepEqual({ closed: saved[1].closed, aborted: saved[1].aborted }, { closed: false, aborted: true });
});

await check("the key survives the password form, even after a wrong guess", async (page) => {
  const locked = await makeDrop({ title: "Locked", files: [{ name: "s.txt", data: small }], password: "open sesame" });
  await page.goto(`${locked.url}#${locked.fragment}`);
  await page.locator("input[name=password]").fill("wrong");
  await page.locator("button[type=submit]").click();
  await page.locator(".error").waitFor();
  assert.ok(page.url().endsWith(`#${locked.fragment}`), page.url());
  await page.locator("input[name=password]").fill("open sesame");
  await page.locator("button[type=submit]").click();
  await page.locator("#files li").first().waitFor();
  assert.ok(page.url().endsWith(`/${locked.id}#${locked.fragment}`), page.url());
  assert.equal(await page.locator("#title").textContent(), "Locked");
  const file = await downloadVia(page, 0);
  assert.equal(sha256(file.bytes), sha256(small));
});

await check("files appear only once the manifest is uploaded", async (page) => {
  const created = await api("POST", "/api/drops", JSON.stringify({ e2ee: 1 }), true);
  await page.goto(`${created.url}#${Buffer.from(randomBytes(32)).toString("base64url")}`);
  await page.locator("#notice").filter({ hasText: "once they finish uploading" }).waitFor();
});

await check("legacy plaintext drops still work", async (page) => {
  const created = await api("POST", "/api/drops", JSON.stringify({ title: "Plain drop" }), true);
  await api("PUT", `/api/drops/${created.id}/files/plain.txt`, small);
  await page.goto(created.url);
  assert.equal(await page.locator("h1").textContent(), "Plain drop");
  const [download] = await Promise.all([page.waitForEvent("download"), page.locator("a.pill").click()]);
  assert.equal(sha256(readFileSync(await download.path())), sha256(small));
});

if (process.env.XNE_SWIFT_DROP) {
  // Written by CloudServerTests.testEncryptedUploadIsOpaqueToTheServer: a drop the Swift app encrypted.
  const swift = JSON.parse(readFileSync(process.env.XNE_SWIFT_DROP, "utf8"));
  await check("decrypts a drop uploaded by the Swift app", async (page) => {
    await page.goto(swift.link);
    await page.locator("#files li").nth(swift.files.length - 1).waitFor();
    assert.equal(await page.locator("#title").textContent(), swift.title);
    assert.deepEqual(await page.locator("#files .name").allTextContents(), swift.files.map((f) => f.name));
    for (let i = 0; i < swift.files.length; i++) {
      const file = await downloadVia(page, i);
      assert.equal(file.name, swift.files[i].name);
      assert.equal(sha256(file.bytes), swift.sha256[i], swift.files[i].name);
    }
  });
}

await browser.close();
console.log(failures ? `${failures} failed` : "all passed");
process.exit(failures ? 1 : 0);

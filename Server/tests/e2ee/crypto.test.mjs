// Cross-language checks of XNotch Cloud E2EE v1: `node --test Server/tests/e2ee/`.
// `cargo test` runs this too when Node is installed (tests/e2ee.rs).
//
// - The shared vectors were produced by the Swift encoder (CryptoKit). An independent
//   Web Crypto encoder (reference.mjs) must reproduce them byte for byte.
// - The browser's decoder (src/assets/e2ee-core.js, loaded as served) must open them,
//   and must reject every kind of tampering before releasing the affected bytes.

import assert from "node:assert/strict";
import test from "node:test";

import {
  SEGMENT,
  chunked,
  decryptAll,
  fromHex,
  hex,
  loadCore,
  loadVectors,
  pattern,
  randomBytes,
  seal,
  sha256,
  vectorPlaintext
} from "./reference.mjs";

const XNE = loadCore();
const { vectors } = loadVectors();
const KEY = fromHex("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f");
const DROP = "a1B2c3D4";
const OBJECT = "00112233445566778899aabbccddeeff";
const once = (bytes) => {
  let given = false;
  return async () => (given ? null : ((given = true), bytes));
};

async function rejects(promise, code, label) {
  await assert.rejects(promise, (e) => {
    assert.equal(e.code, code, `${label}: expected ${code}, got ${e.code} (${e.message})`);
    return true;
  });
}

test("independent encoder reproduces the Swift vectors byte for byte", async () => {
  assert.ok(vectors.length >= 6);
  for (const v of vectors) {
    const sealed = await seal(vectorPlaintext(v), {
      key: fromHex(v.key),
      kind: v.kind,
      dropId: v.drop_id,
      objectId: v.object_id,
      salt: fromHex(v.salt)
    });
    assert.equal(sealed.length, v.ciphertext_size, v.name);
    assert.equal(sha256(sealed), v.ciphertext_sha256, v.name);
    if (v.ciphertext_hex) assert.equal(hex(sealed), v.ciphertext_hex, v.name);
  }
});

test("browser decoder opens every vector, however the bytes are chunked", async () => {
  for (const v of vectors) {
    const key = XNE.parseKey("#" + v.key_fragment);
    assert.equal(hex(key), v.key);
    const plaintext = vectorPlaintext(v);
    const sealed = await seal(plaintext, {
      key,
      kind: v.kind,
      dropId: v.drop_id,
      objectId: v.object_id,
      salt: fromHex(v.salt)
    });
    assert.equal(sha256(sealed), v.ciphertext_sha256, v.name);
    const options = { kind: v.kind, dropId: v.drop_id, objectId: v.object_id, size: plaintext.length };
    for (const seed of [1, 7, 42]) {
      const out = await decryptAll(XNE, key, options, chunked(sealed, seed));
      assert.equal(sha256(out), sha256(plaintext), `${v.name} seed ${seed}`);
    }
    const whole = await XNE.decryptBytes(key, { kind: v.kind, dropId: v.drop_id, objectId: v.object_id }, sealed);
    assert.equal(sha256(whole), sha256(plaintext), v.name);
    if (v.kind === "manifest") {
      const manifest = XNE.parseManifest(whole);
      assert.equal(manifest.title, "Résumé final.pdf");
      assert.deepEqual(JSON.parse(JSON.stringify(manifest.files)), [
        { id: OBJECT, name: "Résumé final.pdf", size: 13 }
      ]);
    }
  }
});

test("sizes: ciphertext length maps back to exactly one plaintext size", () => {
  for (const size of [0, 1, SEGMENT - 1, SEGMENT, SEGMENT + 1, 5 * SEGMENT, 5 * SEGMENT + 3]) {
    assert.equal(XNE.plaintextSize(XNE.ciphertextSize(size)), size, `size ${size}`);
  }
  // A full segment followed by an empty last one is never valid (it would allow truncation games).
  assert.equal(XNE.plaintextSize(38 + (SEGMENT + 16) + 16), -1);
  for (const bad of [0, 37, 38, 53, -1, 1.5, Number.MAX_SAFE_INTEGER + 2]) assert.equal(XNE.plaintextSize(bad), -1);
  assert.equal(XNE.ciphertextSize(SEGMENT), 38 + SEGMENT + 16);
  assert.equal(XNE.ciphertextSize(SEGMENT + 1), 38 + SEGMENT + 1 + 32);
});

test("keys: only a canonical 43-character base64url fragment is accepted", () => {
  const fragment = "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8";
  assert.equal(hex(XNE.parseKey(fragment)), hex(KEY));
  assert.equal(XNE.encodeKey(KEY), fragment);
  const cases = {
    "": "missing-key",
    "#": "missing-key",
    "#k=abc": "bad-key",
    [fragment.slice(0, 42)]: "bad-key",
    [fragment + "A"]: "bad-key",
    [fragment.replace("A", "+")]: "bad-key",
    [fragment.slice(0, 42) + "9"]: "bad-key" // same bytes, spare bits set
  };
  for (const [input, code] of Object.entries(cases)) {
    assert.throws(() => XNE.parseKey(input), (e) => e.code === code, JSON.stringify(input));
  }
});

test("nonces are the 11-byte STREAM counter plus last flag", () => {
  assert.equal(hex(XNE.nonce(0, false)), "000000000000000000000000");
  assert.equal(hex(XNE.nonce(0x0102, true)), "000000000000000000010201");
  assert.equal(hex(XNE.nonce(2 ** 40 + 5, false)), "000000000001000000000500");
});

test("tampering, truncation and reordering are rejected", async () => {
  const plaintext = pattern(2 * SEGMENT + 5);
  const sealed = await seal(plaintext, { key: KEY, kind: "file", dropId: DROP, objectId: OBJECT });
  const options = { kind: "file", dropId: DROP, objectId: OBJECT, size: plaintext.length };
  const full = SEGMENT + 16;
  const header = sealed.subarray(0, 38);
  const [first, second, last] = [
    sealed.subarray(38, 38 + full),
    sealed.subarray(38 + full, 38 + 2 * full),
    sealed.subarray(38 + 2 * full)
  ];
  const join = (...parts) => Buffer.concat(parts.map((p) => Buffer.from(p)));

  for (const offset of [6, 37, 38, 38 + 1000, 38 + full - 1, 38 + full, sealed.length - 1]) {
    const changed = Uint8Array.from(sealed);
    changed[offset] ^= 1;
    await rejects(decryptAll(XNE, KEY, options, chunked(changed)), "auth", `flip at ${offset}`);
  }
  const flip = (offset, value) => {
    const changed = Uint8Array.from(sealed);
    changed[offset] = value;
    return changed;
  };
  await rejects(decryptAll(XNE, KEY, options, once(flip(0, 0))), "format", "magic");
  await rejects(decryptAll(XNE, KEY, options, once(flip(4, 2))), "version", "version");
  await rejects(decryptAll(XNE, KEY, options, once(flip(5, 2))), "format", "kind");

  const attacks = {
    "dropped last segment": [join(header, first, second), "truncated"],
    "last segment cut by a byte": [sealed.subarray(0, sealed.length - 1), "truncated"],
    "header only": [header, "truncated"],
    "empty": [new Uint8Array(0), "truncated"],
    "swapped segments": [join(header, second, first, last), "auth"],
    "middle segment replayed": [join(header, first, first, last), "auth"],
    "extra byte after the last segment": [join(sealed, [0]), "trailing"],
    "extra segment after the last": [join(sealed, last), "trailing"]
  };
  for (const [name, [bytes, code]] of Object.entries(attacks)) {
    await rejects(decryptAll(XNE, KEY, options, chunked(bytes, 3)), code, name);
  }

  // Claiming the file is shorter ends at a segment not marked last: rejected, not cut short.
  await rejects(decryptAll(XNE, KEY, { ...options, size: 2 * SEGMENT }, once(sealed)), "auth", "shorter size");
  await rejects(decryptAll(XNE, KEY, { ...options, size: SEGMENT }, once(sealed)), "auth", "one segment");
});

test("no plaintext of a failing segment is released, and earlier output is flagged unverified by rejection", async () => {
  const plaintext = pattern(3 * SEGMENT);
  const sealed = await seal(plaintext, { key: KEY, kind: "file", dropId: DROP, objectId: OBJECT });
  const changed = Uint8Array.from(sealed);
  changed[38 + 2 * (SEGMENT + 16) + 10] ^= 1; // inside the third (last) segment
  const released = [];
  await rejects(
    XNE.decrypt(KEY, { kind: "file", dropId: DROP, objectId: OBJECT, size: plaintext.length }, once(changed), async (p) =>
      released.push(p.length)
    ),
    "auth",
    "third segment"
  );
  assert.deepEqual(released, [SEGMENT, SEGMENT]);
});

test("ciphertext only opens with its key, drop, object and kind", async () => {
  const plaintext = new TextEncoder().encode("hello");
  const sealed = await seal(plaintext, { key: KEY, kind: "file", dropId: DROP, objectId: OBJECT });
  const options = { kind: "file", dropId: DROP, objectId: OBJECT, size: 5 };
  assert.equal(Buffer.from(await decryptAll(XNE, KEY, options, once(sealed))).toString(), "hello");
  await rejects(decryptAll(XNE, randomBytes(32), options, once(sealed)), "auth", "wrong key");
  await rejects(decryptAll(XNE, KEY, { ...options, dropId: "a1B2c3D5" }, once(sealed)), "auth", "other drop");
  await rejects(
    decryptAll(XNE, KEY, { ...options, objectId: "ffeeddccbbaa99887766554433221100" }, once(sealed)),
    "auth",
    "other object (file swapped within the drop)"
  );
  await rejects(decryptAll(XNE, KEY, { ...options, kind: "manifest" }, once(sealed)), "format", "as manifest");
  await rejects(decryptAll(XNE, KEY.subarray(0, 16), options, once(sealed)), "bad-key", "short key");
});

test("manifest validation keeps hostile names and shapes out of the page", async () => {
  const parse = (value) => XNE.parseManifest(new TextEncoder().encode(JSON.stringify(value)));
  const id = OBJECT;
  const ok = parse({ v: 1, title: "  Trip\u0000/<b>  ", files: [{ id, name: "../a\\b‮.txt\n", size: 3 }] });
  assert.equal(ok.title, "Trip_/<b>");
  assert.equal(ok.files[0].name, ".._a_b‮.txt_");
  assert.equal(parse({ v: 1, files: [{ id, name: "..", size: 0 }] }).files[0].name, "file");
  assert.equal(parse({ v: 1, title: "x".repeat(500), files: [] }).title.length, 200);
  assert.equal(parse({ v: 1, files: [{ id, name: "é".repeat(400), size: 1 }] }).files[0].name.length, 255);

  const bad = [
    { v: 2, files: [] },
    { v: 1 },
    { v: 1, files: {} },
    { v: 1, files: [{ id: "ABC", name: "a", size: 1 }] },
    { v: 1, files: [{ id, name: "a", size: -1 }] },
    { v: 1, files: [{ id, name: "a", size: 1.5 }] },
    { v: 1, files: [{ id, name: "a", size: 2 ** 53 }] },
    { v: 1, files: [{ id, name: 5, size: 1 }] },
    { v: 1, files: [{ id, name: "a", size: 1 }, { id, name: "b", size: 1 }] },
    { v: 1, files: Array.from({ length: 10001 }, (_, i) => ({ id: i.toString(16).padStart(32, "0"), name: "a", size: 1 })) }
  ];
  for (const value of bad) assert.throws(() => parse(value), (e) => e.code === "manifest", JSON.stringify(value).slice(0, 80));
  assert.throws(() => XNE.parseManifest(new Uint8Array([0xff, 0xfe])), (e) => e.code === "manifest");
  assert.throws(() => XNE.parseManifest(new TextEncoder().encode("null")), (e) => e.code === "manifest");
});

test("manifest decryption is bound to the drop id", async () => {
  const json = new TextEncoder().encode(JSON.stringify({ v: 1, files: [] }));
  const sealed = await seal(json, { key: KEY, kind: "manifest", dropId: DROP });
  assert.deepEqual(
    JSON.parse(JSON.stringify(XNE.parseManifest(await XNE.decryptBytes(KEY, { kind: "manifest", dropId: DROP }, sealed)))),
    { title: "", files: [] }
  );
  await rejects(XNE.decryptBytes(KEY, { kind: "manifest", dropId: "zzzzzzzz" }, sealed), "auth", "other drop");
  await rejects(XNE.decryptBytes(KEY, { kind: "manifest", dropId: DROP }, sealed.subarray(0, 50)), "truncated", "cut");
  assert.equal(XNE.MAX_MANIFEST_BYTES, 38 + 262144 + 16);
});

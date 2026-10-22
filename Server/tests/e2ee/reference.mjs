// Test helpers for XNotch Cloud E2EE v1 (spec: Server/docs/E2EE.md).
//
// `seal` is a second encoder, written from the spec on Web Crypto, independent of the
// Swift encoder (CryptoKit) and of the browser decoder it is tested against. It shares
// no code with `src/assets/e2ee-core.js`.

import { readFileSync } from "node:fs";
import { createHash, webcrypto } from "node:crypto";
import { fileURLToPath } from "node:url";
import vm from "node:vm";

export const SEGMENT = 1 << 20;
const TAG = 16;
const HEADER = 38;

const here = (path) => fileURLToPath(new URL(path, import.meta.url));

/// Evaluates the page's decryption core exactly as the server inlines it.
export function loadCore() {
  const source = readFileSync(here("../../src/assets/e2ee-core.js"), "utf8");
  const context = vm.createContext({ crypto: webcrypto, TextEncoder, TextDecoder, atob, btoa, Uint8Array, Error });
  vm.runInContext(source + "\n;globalThis.XNE = XNE;", context, { filename: "e2ee-core.js" });
  return context.XNE;
}

export function loadVectors() {
  return JSON.parse(readFileSync(here("vectors.json"), "utf8"));
}

export function pattern(size) {
  const bytes = new Uint8Array(size);
  for (let i = 0; i < size; i++) bytes[i] = (i * 31 + 7) & 0xff;
  return bytes;
}

export const hex = (bytes) => Buffer.from(bytes).toString("hex");
export const fromHex = (text) => new Uint8Array(Buffer.from(text, "hex"));
export const sha256 = (bytes) => createHash("sha256").update(bytes).digest("hex");

export function vectorPlaintext(vector) {
  return vector.plaintext_utf8 != null
    ? new TextEncoder().encode(vector.plaintext_utf8)
    : pattern(vector.plaintext_pattern_size);
}

export function randomBytes(n) {
  return webcrypto.getRandomValues(new Uint8Array(n));
}

/// Encrypts one object. `kind` is "file" or "manifest"; `salt` defaults to random.
export async function seal(plaintext, { key, kind, dropId, objectId, salt = randomBytes(32) }) {
  const kindByte = kind === "manifest" ? 2 : 1;
  const header = new Uint8Array(HEADER);
  header.set([0x58, 0x4e, 0x43, 0x45, 1, kindByte]);
  header.set(salt, 6);
  const infoText = `XNotch Cloud E2EE v1\0${kind}\0${dropId}` + (kind === "file" ? `\0${objectId}` : "");
  const ikm = await webcrypto.subtle.importKey("raw", key, "HKDF", false, ["deriveBits"]);
  const bits = await webcrypto.subtle.deriveBits(
    { name: "HKDF", hash: "SHA-256", salt, info: new TextEncoder().encode(infoText) },
    ikm,
    256
  );
  const aes = await webcrypto.subtle.importKey("raw", bits, "AES-GCM", false, ["encrypt"]);

  const count = plaintext.length === 0 ? 1 : Math.ceil(plaintext.length / SEGMENT);
  const out = new Uint8Array(HEADER + plaintext.length + count * TAG);
  out.set(header);
  let at = HEADER;
  for (let i = 0; i < count; i++) {
    const iv = new Uint8Array(12);
    new DataView(iv.buffer).setBigUint64(3, BigInt(i)); // bytes 3..10: low 64 bits of the 88-bit counter
    iv[11] = i === count - 1 ? 1 : 0;
    const part = plaintext.subarray(i * SEGMENT, Math.min(plaintext.length, (i + 1) * SEGMENT));
    const sealed = new Uint8Array(
      await webcrypto.subtle.encrypt({ name: "AES-GCM", iv, additionalData: header, tagLength: 128 }, aes, part)
    );
    out.set(sealed, at);
    at += sealed.length;
  }
  return out;
}

/// Splits bytes into random-sized chunks, the way a network stream might deliver them.
export function chunked(bytes, seed = 1) {
  let state = seed;
  const chunks = [];
  for (let at = 0; at < bytes.length; ) {
    state = (state * 1103515245 + 12345) & 0x7fffffff;
    const size = 1 + (state % 200000);
    chunks.push(bytes.slice(at, at + size));
    at += size;
  }
  let i = 0;
  return async () => (i < chunks.length ? chunks[i++] : null);
}

/// Runs the core's streaming decrypt and collects what it releases.
export async function decryptAll(XNE, key, options, read) {
  const parts = [];
  await XNE.decrypt(key, options, read, async (part) => parts.push(part));
  return Buffer.concat(parts);
}

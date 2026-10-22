// XNotch Cloud E2EE v1: decryption primitives for the drop page (spec: Server/docs/E2EE.md).
// Only the browser's Web Crypto API does cryptography here; this file frames bytes and
// checks what it is given. It has no DOM code, so Node runs it as-is in the tests.
var XNE = (function () {
  "use strict";

  var SEGMENT = 1048576; // plaintext bytes per segment; the last may be shorter
  var TAG = 16;
  var SALT = 32;
  var HEADER = 4 + 1 + 1 + SALT; // "XNCE", version, kind, salt
  var MAGIC = [0x58, 0x4e, 0x43, 0x45];
  var VERSION = 1;
  var KIND = { file: 1, manifest: 2 };
  var MAX_MANIFEST_PLAINTEXT = 262144;
  var MAX_MANIFEST_BYTES = HEADER + MAX_MANIFEST_PLAINTEXT + TAG;
  var MAX_FILES = 10000;
  var MAX_TITLE = 200;
  var MAX_NAME = 255;
  var INFO_PREFIX = "XNotch Cloud E2EE v1";

  function fail(code, message) {
    var error = new Error(message);
    error.code = code;
    return error;
  }

  function subtle() {
    var c = typeof crypto !== "undefined" ? crypto : null;
    if (!c || !c.subtle) throw fail("no-crypto", "This browser can't decrypt here (Web Crypto needs HTTPS).");
    return c.subtle;
  }

  // The key is the whole URL fragment: 32 bytes as unpadded base64url (43 characters).
  function parseKey(fragment) {
    var text = String(fragment || "");
    if (text.charAt(0) === "#") text = text.slice(1);
    if (text === "") throw fail("missing-key", "This link is missing its key.");
    if (!/^[A-Za-z0-9_-]{43}$/.test(text)) throw fail("bad-key", "This link's key is malformed.");
    var binary = atob(text.replace(/-/g, "+").replace(/_/g, "/") + "=");
    var key = new Uint8Array(binary.length);
    for (var i = 0; i < binary.length; i++) key[i] = binary.charCodeAt(i);
    // 43 characters carry 258 bits; the spare 2 must be zero, so each key has one spelling.
    if (key.length !== 32 || encodeKey(key) !== text) throw fail("bad-key", "This link's key is malformed.");
    return key;
  }

  function encodeKey(key) {
    var binary = "";
    for (var i = 0; i < key.length; i++) binary += String.fromCharCode(key[i]);
    return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
  }

  function segmentCount(plaintextSize) {
    return plaintextSize === 0 ? 1 : Math.ceil(plaintextSize / SEGMENT);
  }

  function ciphertextSize(plaintextSize) {
    return HEADER + plaintextSize + segmentCount(plaintextSize) * TAG;
  }

  // The plaintext size a ciphertext length stands for, or -1 if no valid object has it.
  function plaintextSize(ciphertextLength) {
    if (!Number.isSafeInteger(ciphertextLength) || ciphertextLength < HEADER + TAG) return -1;
    var body = ciphertextLength - HEADER;
    var size = body - Math.ceil(body / (SEGMENT + TAG)) * TAG;
    return size >= 0 && ciphertextSize(size) === ciphertextLength ? size : -1;
  }

  function info(kind, dropId, objectId) {
    var text = INFO_PREFIX + "\u0000" + (kind === KIND.manifest ? "manifest" : "file") + "\u0000" + dropId;
    if (kind === KIND.file) text += "\u0000" + objectId;
    return new TextEncoder().encode(text);
  }

  // 11-byte big-endian segment counter, then 1 when it is the last segment (STREAM).
  function nonce(index, last) {
    var bytes = new Uint8Array(12);
    var n = index;
    for (var i = 10; i >= 0 && n > 0; i--) {
      bytes[i] = n % 256;
      n = Math.floor(n / 256);
    }
    bytes[11] = last ? 1 : 0;
    return bytes;
  }

  function parseHeader(header, kind) {
    for (var i = 0; i < MAGIC.length; i++) {
      if (header[i] !== MAGIC[i]) throw fail("format", "This isn't an XNotch encrypted file.");
    }
    if (header[4] !== VERSION) throw fail("version", "This file uses a newer encryption format. Update the server.");
    if (header[5] !== kind) throw fail("format", "This encrypted object is of the wrong kind.");
    return header.slice(6, HEADER);
  }

  function deriveKey(rawKey, salt, infoBytes) {
    var s = subtle();
    return s.importKey("raw", rawKey, "HKDF", false, ["deriveKey"]).then(function (ikm) {
      return s.deriveKey(
        { name: "HKDF", hash: "SHA-256", salt: salt, info: infoBytes },
        ikm,
        { name: "AES-GCM", length: 256 },
        false,
        ["decrypt"]
      );
    });
  }

  // Pulls exact byte counts from `read`, an async function returning Uint8Array chunks
  // and null at the end. At most one chunk is held beyond what was asked for.
  function Reader(read) {
    this.read = read;
    this.chunk = null;
    this.offset = 0;
    this.done = false;
  }

  Reader.prototype.fill = async function (target, length) {
    var filled = 0;
    while (filled < length) {
      if (!this.chunk || this.offset === this.chunk.length) {
        if (this.done) return filled;
        var next = await this.read();
        if (next == null) {
          this.done = true;
          return filled;
        }
        this.chunk = next instanceof Uint8Array ? next : new Uint8Array(next);
        this.offset = 0;
        continue;
      }
      var take = Math.min(length - filled, this.chunk.length - this.offset);
      target.set(this.chunk.subarray(this.offset, this.offset + take), filled);
      this.offset += take;
      filled += take;
    }
    return filled;
  };

  Reader.prototype.atEnd = async function () {
    var probe = new Uint8Array(1);
    return (await this.fill(probe, 1)) === 0;
  };

  // Decrypts one object, streaming. `options`: kind ("file"/"manifest"), dropId, objectId
  // (files), size: the expected plaintext size. `write(plaintext)` gets each segment only
  // after the segment authenticated; anything after the last segment is an error, and a
  // missing last segment can't pass because its nonce marks it as last. So the caller must
  // treat output as unverified until this resolves, and discard it if it rejects.
  async function decrypt(rawKey, options, read, write) {
    var kind = KIND[options.kind];
    var size = options.size;
    if (!kind) throw fail("format", "Unknown object kind.");
    if (!Number.isSafeInteger(size) || size < 0) throw fail("format", "Invalid size.");
    if (rawKey.length !== 32) throw fail("bad-key", "This link's key is malformed.");

    var reader = new Reader(read);
    var header = new Uint8Array(HEADER);
    if ((await reader.fill(header, HEADER)) < HEADER) throw fail("truncated", "The encrypted file is cut short.");
    var salt = parseHeader(header, kind);
    var key = await deriveKey(rawKey, salt, info(kind, options.dropId, options.objectId));

    var segments = segmentCount(size);
    var buffer = new Uint8Array(Math.min(size, SEGMENT) + TAG);
    var s = subtle();
    for (var index = 0; index < segments; index++) {
      var last = index === segments - 1;
      var length = (last ? size - SEGMENT * (segments - 1) : SEGMENT) + TAG;
      if ((await reader.fill(buffer, length)) < length) throw fail("truncated", "The encrypted file is cut short.");
      var plaintext;
      try {
        plaintext = await s.decrypt(
          { name: "AES-GCM", iv: nonce(index, last), additionalData: header, tagLength: 128 },
          key,
          buffer.subarray(0, length)
        );
      } catch (e) {
        throw fail("auth", "The encrypted data didn't authenticate.");
      }
      await write(new Uint8Array(plaintext), index);
    }
    if (!(await reader.atEnd())) throw fail("trailing", "The encrypted file has extra data at the end.");
    return size;
  }

  // Decrypts a whole in-memory object whose plaintext size follows from its length.
  async function decryptBytes(rawKey, options, bytes) {
    var size = plaintextSize(bytes.length);
    if (size < 0) throw fail("truncated", "The encrypted data has an impossible length.");
    var out = new Uint8Array(size);
    var at = 0;
    var given = false;
    await decrypt(
      rawKey,
      { kind: options.kind, dropId: options.dropId, objectId: options.objectId, size: size },
      async function () {
        if (given) return null;
        given = true;
        return bytes;
      },
      async function (part) {
        out.set(part, at);
        at += part.length;
      }
    );
    return out;
  }

  // Control characters (C0, DEL, C1) never reach the page, nor path separators a file name.
  function cleanText(value, max, isName) {
    var pattern = isName ? /[\u0000-\u001f\u007f-\u009f\/\\]/g : /[\u0000-\u001f\u007f-\u009f]/g;
    return Array.from(String(value).replace(pattern, "_").trim()).slice(0, max).join("");
  }

  // Validates decrypted manifest JSON: {"v":1,"title"?:string,"files":[{"id","name","size"}]}.
  function parseManifest(bytes) {
    var json;
    try {
      json = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(bytes));
    } catch (e) {
      throw fail("manifest", "The list of files is unreadable.");
    }
    if (!json || typeof json !== "object" || json.v !== 1 || !Array.isArray(json.files)) {
      throw fail("manifest", "The list of files is unreadable.");
    }
    if (json.files.length > MAX_FILES) throw fail("manifest", "The drop lists too many files.");
    var title = typeof json.title === "string" ? cleanText(json.title, MAX_TITLE, false) : "";
    var seen = Object.create(null);
    var files = json.files.map(function (f) {
      if (!f || typeof f !== "object" || typeof f.id !== "string" || !/^[0-9a-f]{32}$/.test(f.id) || seen[f.id]) {
        throw fail("manifest", "The list of files is unreadable.");
      }
      seen[f.id] = true;
      if (typeof f.name !== "string" || !Number.isSafeInteger(f.size) || f.size < 0) {
        throw fail("manifest", "The list of files is unreadable.");
      }
      var name = cleanText(f.name, MAX_NAME, true);
      if (name === "" || name === "." || name === "..") name = "file";
      return { id: f.id, name: name, size: f.size };
    });
    return { title: title, files: files };
  }

  return {
    SEGMENT: SEGMENT,
    TAG: TAG,
    HEADER: HEADER,
    MAX_MANIFEST_PLAINTEXT: MAX_MANIFEST_PLAINTEXT,
    MAX_MANIFEST_BYTES: MAX_MANIFEST_BYTES,
    parseKey: parseKey,
    encodeKey: encodeKey,
    ciphertextSize: ciphertextSize,
    plaintextSize: plaintextSize,
    info: info,
    nonce: nonce,
    decrypt: decrypt,
    decryptBytes: decryptBytes,
    parseManifest: parseManifest
  };
})();

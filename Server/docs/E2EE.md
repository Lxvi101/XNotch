# XNotch Cloud end-to-end encryption

XNotch encrypts Cloud links on the Mac before uploading. The server stores ciphertext and
never receives the key. Recipients decrypt in their browser. This document specifies the
format (`XNotch Cloud E2EE v1`) and says plainly what it protects and what it does not.

Implementations:

- Encrypting (Mac): `Extensions/Cloud/Sources/Cloud/DropCrypto.swift` (CryptoKit), driven by `DropUploader.swift`.
- Decrypting (browser): `Server/src/assets/e2ee-core.js` (Web Crypto) and `e2ee-page.js`, inlined into the drop page.
- Server: `Server/src/e2ee.rs` (limits and names). The server does no cryptography for these drops.

## What it protects, and what it doesn't

**Protected.** File contents, file names and the drop title are encrypted and authenticated.
This holds against anyone who has the server's storage but not the link: the host, the
bucket provider, backups and snapshots, a leaked volume or bucket, or an operator browsing
the data directory. Changed, swapped, reordered or truncated ciphertext is detected.

**Not protected:**

1. **An actively malicious or compromised web server.** The page that decrypts is served by
   the same server, so whoever controls the server at the moment someone opens a link can
   send a page that reads the key from the URL and sends it back. It could also show a
   page that just asks for a password. Encryption keeps files private from storage and
   from a server that behaves as written. It does not keep them private from a server
   that serves hostile code to recipients. There is no fix for this inside a web page:
   only a separately verified client (an app or browser extension) could close it.
2. **Anyone with the whole link.** The key is in the link. Whoever has the link (chat
   history, email, browser history and sync, a link preview bot that keeps the fragment,
   a shoulder) can decrypt. A drop password adds a server-side gate, but the server checks
   that password; it is not part of the key (see "Passwords" below).
3. **Metadata.** The server sees: how many files a drop has; each file's ciphertext size
   (plaintext size plus 38 bytes plus 16 bytes per MiB, so effectively the exact size);
   the manifest size; creation, upload and download times; IP addresses and user agents;
   expiry; whether a password is set; and, when the link is created, the drop password itself.
4. **Revocation is only as good as deletion.** Deleting a drop removes the ciphertext from
   the server. It cannot take back the key. Anyone who already downloaded the ciphertext,
   or who holds a backup or snapshot of the storage, can still decrypt it with the link.
   See SECURITY.md about expiry and physical erasure.
5. **Key loss is permanent.** Only the link holds the key: the server can't recover it, and
   XNotch keeps it only in its local list of links. If the part after `#` is lost or
   mangled, the files can't be decrypted by anyone.
6. **The sender's Mac.** The Mac keeps recent links, keys included, in the XNotch
   preferences so that "Copy link" works later. Anyone with access to that macOS account can read them.

## Keys and links

- Per drop, the Mac generates a random 256-bit key (`SymmetricKey(size: .bits256)`, from the
  system CSPRNG). A new key is made for every drop, and keys are never reused.
- The link is `https://server/{id}#{key}`, where `{key}` is the key as unpadded base64url:
  exactly 43 characters. Decoders accept only the canonical spelling (the two spare bits are
  zero) and reject anything else.
- Browsers never send the fragment in HTTP requests or in `Referer` headers. The page reads
  it from `location.hash`. The drop page also sends `Referrer-Policy: no-referrer`.
- The key never goes to the server: not in the create request, not in the manifest, and not
  in any header. The Swift tests check the bytes sent for it.

## Object format

Every encrypted object (each file, and the drop's manifest) has the same layout:

```
header   = "XNCE" (58 4E 43 45) || version (0x01) || kind (0x01 file, 0x02 manifest) || salt (32 random bytes)
segments = seg_0 || seg_1 || ... || seg_{n-1}
seg_i    = AES-256-GCM(object_key, nonce_i, plaintext_i, aad = header)   (ciphertext || 16-byte tag)
```

- **Segment size**: every plaintext segment is exactly 1 MiB (1,048,576 bytes), except the last,
  which holds 1 to 1,048,576 bytes. It holds 0 bytes only when the whole object is empty.
  So `n = max(1, ceil(size / 1 MiB))`, and the ciphertext length is
  `38 + size + 16 * n`. Each ciphertext length maps back to exactly one plaintext size
  (or to none).
- **Object key**: `HKDF-SHA256(ikm = drop key, salt = header salt, info, L = 32)` (RFC 5869), with
  - manifest: `info = "XNotch Cloud E2EE v1" || 0x00 || "manifest" || 0x00 || drop_id`
  - file: `info = "XNotch Cloud E2EE v1" || 0x00 || "file" || 0x00 || drop_id || 0x00 || object_id`

  Every object gets a fresh random salt, so every object gets its own key. The info
  string binds the key to the drop and to the object name. A file served under a different
  name, from a different drop, or as the manifest fails authentication.
- **Nonces** follow the STREAM construction (Hoang, Reyhanitabar, Rogaway, Vizár, "Online
  Authenticated-Encryption and its Nonce-Reuse Misuse-Resistance", CRYPTO 2015), laid out as
  in the [age format](https://github.com/C2SP/C2SP/blob/main/age.md#payload): an 11-byte
  big-endian segment counter starting at 0, then one byte that is `0x01` for the last
  segment and `0x00` otherwise. Each (key, nonce) pair is used once: the keys are unique per
  object, and the counter is unique per segment.
- **Associated data**: the 38-byte header, for every segment. The magic, version, kind
  and salt are all authenticated.

What this rules out: reordering or duplicating segments (wrong counter), dropping segments at
the end (the new final segment isn't marked last), appending data (the decoder knows where
the last segment ends and rejects anything after it), cross-object or cross-drop swaps
(different key), and downgrades or kind confusion (header in AAD and in the HKDF info).

Primitives: AES-256-GCM (NIST SP 800-38D) with 96-bit nonces and 128-bit tags, and HKDF-SHA256
(RFC 5869). The Web Crypto API (W3C) and Apple CryptoKit provide both. No custom cipher,
MAC or KDF is used. AES-GCM was chosen over ChaCha20-Poly1305 because Web Crypto has no
ChaCha20-Poly1305, and a JavaScript implementation would mean shipping hand-written crypto
to the browser.

Limits: the format allows 2^88 segments per object. The implementations count to at least 2^53 segments (8 EiB), far beyond any file. Each object key encrypts at most
`size / 1 MiB` messages, far below the AES-GCM usage limits.

## Manifest

The manifest is UTF-8 JSON, encrypted as a single segment (at most 256 KiB of plaintext, so
at most 262,198 bytes of ciphertext):

```json
{"files":[{"id":"00112233445566778899aabbccddeeff","name":"Résumé.pdf","size":48213}],"title":"Résumé.pdf","v":1}
```

- `v` must be 1. `title` is optional (at most 200 characters are shown). `files` holds at most
  10,000 entries.
- `id` is the object name the file's ciphertext is stored under: 16 random bytes as 32
  lowercase hex characters. Names must be unique.
- `size` is the plaintext size. The browser computes the expected ciphertext length from it,
  rejects a response whose `Content-Length` disagrees, and decrypts exactly that many segments.
- The browser displays names and titles as text only, never as HTML. It replaces control
  characters (and `/`, `\` in names) with `_` and gives empty or dot names a neutral fallback.
  Decrypted files are always downloaded as `application/octet-stream`, so the browser never
  renders them in the server's origin.

## Server protocol

- `GET /api/info` lists `"e2ee": [1]`. Servers from before this field don't support encrypted drops.
- `POST /api/drops` with `{"e2ee": 1}` creates an encrypted drop, and the response echoes
  `"e2ee": 1`. A title with `e2ee` is refused (`400`), so it can't be stored by mistake.
- `PUT /api/drops/{id}/files/{object_id}` accepts only 32-character lowercase hex names in
  encrypted drops. The server stores them as `application/octet-stream` and never shows them inline.
- `PUT /api/drops/{id}/manifest` stores the manifest (`400` for unencrypted drops, `413` above 262,198 bytes).
- `GET /{id}` serves a page that holds only the drop id and expiry. Its CSP allows the inline
  scripts (by nonce) and `connect-src 'self'`, and nothing from other origins.
  `GET /{id}/-/manifest` and `GET /{id}/{object_id}` serve the ciphertext. Password-protected
  drops still need the unlock cookie for all three (the manifest answers `403` without it).

### Failing closed

The Mac app encrypts by default (Settings → Cloud Links → "End-to-end encrypt links"). While
that setting is on, the app never falls back to plaintext:

1. If `/api/info` lacks `e2ee: [1]` (an old server), nothing is created or uploaded.
2. If the server URL is plain `http` on a non-loopback host, the upload is refused. Browsers
   only expose Web Crypto in secure contexts (HTTPS, or `localhost`/`127.0.0.1`), so
   recipients couldn't decrypt those links.
3. If the created drop doesn't echo `e2ee: 1` (for example, a proxy changed the request),
   the drop is deleted before any file is sent.
4. If any step fails after the drop exists, the drop is deleted.

If a server is later downgraded to a version without `e2ee`, its encrypted drops show their
opaque object names and download as ciphertext: nothing is revealed, but they can't be
decrypted until the server is upgraded again.

The Mac writes each encrypted file to a temporary file (ciphertext only) before uploading,
so an upload briefly needs free disk space equal to the file's size. Encryption reads about
two segments at a time, so memory stays small whatever the file size.

Turning the setting off makes plain, server-readable links, as before. Links made earlier,
and drops from older clients, keep working unchanged.

## Decrypting in the browser

- Everything runs in inline scripts served by the drop's own server. There are no third-party
  scripts, CDNs, fonts or analytics. The only requests are to the drop's own origin.
- Wrong key: the manifest fails authentication, and the page says the key doesn't open the
  files. A missing or malformed fragment gets its own message. A newer format version asks
  for a server update.
- Files are fetched with `fetch()` and decrypted one segment at a time, holding about one
  segment (1 MiB plus a network chunk) of ciphertext at once. Each segment's plaintext is
  produced only after its tag verified. Truncation and trailing data are detected at the end.
- **No plaintext reaches the user before the whole file has authenticated.** There are two paths:
  - **Up to 1 GiB, any modern browser:** verified segments are collected in `Blob`s. The
    download (a `blob:` URL with `download`) starts only after the final segment and the
    end-of-stream check pass. On failure, the page drops the parts and nothing is saved. Memory: about
    the file's size. Chromium can page large blobs to disk; Safari and Firefox mostly keep
    them in RAM. Mobile Safari may run out of memory well below 1 GiB.
  - **Above 1 GiB:** only browsers with the File System Access API (`showSaveFilePicker`;
    desktop Chrome and Edge) can save the file. Segments are written to the picker's
    writable stream, which writes into a temporary swap file. `close()` moves it into place
    only after full authentication; on any failure `abort()` deletes the swap file and the
    chosen file is untouched. Memory stays bounded at about one segment. Other browsers get
    a message to use desktop Chrome or Edge.
- Streaming straight into the browser's download manager (for example through a service
  worker) was rejected: it would save unauthenticated plaintext before the end of the file
  is checked.
- The key stays in the address bar so that reloading works. The password form carries the
  fragment through its redirect, so a protected encrypted link still decrypts after unlocking.

## Passwords

Drop passwords stay what they were: a server-side gate (Argon2id hash, unlock cookie). For an
encrypted drop, the password and the key are independent. The password stops someone who has
the link from even downloading the ciphertext, as long as the server is honest. It adds
nothing against someone holding the storage plus the link. The server receives the password
when the drop is created.

## Tests

- `Extensions/Cloud/Tests/CloudTests/DropCryptoTests.swift`: round trips at segment
  boundaries, tampering at every region, truncation, reordering, extra data, wrong
  key/drop/object/kind, canonical keys, manifest limits, and the shared vectors.
- `Server/tests/e2ee/vectors.json`: known-answer vectors produced by the Swift encoder
  (regenerate with `XNE_WRITE_VECTORS=1 swift test --filter testVectors`, only when the format changes).
- `Server/tests/e2ee/crypto.test.mjs` (also run by `cargo test` via `tests/e2ee_js.rs`): an
  independent Web Crypto encoder reproduces the Swift vectors byte for byte, and the
  browser decoder exactly as served opens them, however the stream is chunked. It also
  rejects tampering and releases no plaintext from a failing segment.
- `Extensions/Cloud/Tests/CloudTests/DropUploaderTests.swift`: fail-closed behavior against
  fake old and misbehaving servers. Only ciphertext and opaque names are sent, never the key.
- `Server/tests/api.rs`: the server's encrypted-drop API, page, CSP, password gate and legacy compatibility.
- `Server/tests/e2ee/browser.mjs`: headless Chromium against a running server. It covers
  decryption and downloads, missing/damaged/wrong keys, tampered and truncated files (no
  download), the large-file disk path (commit and abort), the password form keeping the key,
  legacy drops, no foreign requests, and a drop uploaded by the Swift app.

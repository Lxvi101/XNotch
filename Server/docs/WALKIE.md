# Walkie

Walkie puts the people you talk to most in the notch. Hold a face to record a voice
note, written down on your Mac as you speak; it plays on their Mac when you let go.
You can also drop files on a face, send a screenshot, or hand over a to-do with a reminder.

It runs on the same XNotch Cloud server as Cloud Links, and everything is sealed on the
Mac before it leaves. This document describes the format (`XNotch Walkie v1`), what the
server sees, and what the design does and doesn't protect.

Implementations:

- Mac: `Extensions/Walkie/Sources/Walkie/WalkieCrypto.swift`, `PostQuantum.swift` and `HPKE.swift`,
  plus `WalkieWire.swift` (message bodies and invites) and `WalkieClient.swift` (HTTP and WebSocket).
  It runs on **macOS 14 and later**, Sequoia included. X-Wing and ML-DSA-65 come from the BoringSSL
  inside Apple's swift-crypto. HPKE (RFC 9180, base mode) is built from CryptoKit's HKDF and AES-GCM.
  CryptoKit has the same post-quantum types only from macOS 26, so `PostQuantumTests` checks that the
  two agree byte for byte: keys from the same seeds, CryptoKit's HPKE opening ours and ours opening
  CryptoKit's, and signatures verifying both ways.
- Server: `Server/src/walkie.rs`. The server does no cryptography on messages.

## In one paragraph

Every Mac has a mailbox on a server. Contacts post sealed messages to it with a send
token they got from an invite. Sealing uses HPKE (RFC 9180) with the **X-Wing** KEM
(ML-KEM-768 combined with X25519), HKDF-SHA256 and AES-256-GCM, so reading a message needs
breaking *both* the post-quantum and the classical key exchange. Every message is signed
with **ML-DSA-65 and Ed25519**, and both signatures must verify. The server stores and
forwards opaque bytes, and deletes them once they're fetched or after `WALKIE_RETENTION_DAYS`.

## Keys

Each Mac generates once, from the system CSPRNG, and keeps in its login Keychain
(`dev.levi.XNotch.walkie`, this device only):

| Key | Use |
| --- | --- |
| X-Wing (ML-KEM-768 + X25519) | Receiving: HPKE recipient key |
| ML-DSA-65 | Signing (post-quantum half) |
| Ed25519 | Signing (classical half) |
| Mailbox secret, 32 bytes | Reading its own mailbox |
| Send token, 32 bytes | What contacts present to post to it |

The **box id** is `hex(SHA-256("XNotch Walkie box v1" || 0x00 || secret))`. The server
checks the secret by hashing it, so it never stores it. The server keeps
`hex(SHA-256("XNotch Walkie post v1" || 0x00 || token))` of the send token. If the
mailbox is listed in the directory, it also keeps the token itself.

The **fingerprint** of a set of public keys is
`SHA-256("XNotch Walkie fp v1" || 0x00 || for each of kem, mldsa, ed: u32be(len) || key)`.

## Cards

A card says who someone is and how to reach them: `{v, name, avatar?, server, box, keys
{kem, mldsa, ed}, created}` as JSON. It is signed with the hybrid signature over
`"XNotch Walkie card v1" || 0x00 || card JSON`. The server holds the latest signed card
of each mailbox and serves it only to holders of the send token.

## Invites

```
xnotch-walkie:<base64url of {"s": server URL, "b": box id, "t": send token (hex), "f": fingerprint (hex)}>
```

Adding someone from an invite fetches their card and **rejects it unless its keys match
the invite's fingerprint**. A server that swaps the card is caught. Those contacts are
marked verified. An invite is not a secret in the usual sense: it lets the holder write
to you, and nothing more.

Contacts added from the server's directory (`GET /api/walkie/directory`, for holders of
the API token) and people who write first are **not** verified. Their keys could have
been chosen by whoever runs the server. Settings → Walkie shows a 60-digit **safety
number** for each person, computed from both fingerprints in a fixed order, so both sides
see the same digits. Compare it in person or on a call, then mark the contact verified.
Keys are pinned on first contact: a later card with different keys for the same mailbox
is ignored.

## Envelopes

```
sealed    = "XNWK" || 0x01 || u16be len(enc) || enc || ct
ct        = HPKE-Seal(suite = X-Wing / HKDF-SHA256 / AES-256-GCM,
                      pkR = recipient X-Wing key,
                      info = "XNotch Walkie v1" || recipient box (32 bytes),
                      aad = "XNWK" || 0x01,
                      pt = plaintext)
plaintext = sender box (32 bytes) || u16be len(sig) || sig || body
sig       = Ed25519(m) || ML-DSA-65(m),  m = "XNotch Walkie msg v1" || 0x00 || recipient box || SHA-256(enc) || body
```

- The recipient's box id is in the HPKE `info`, so a message opens only for the
  mailbox it was sealed for.
- The signature covers the recipient's box and the KEM ciphertext, so a recipient can't
  re-seal a signed message to a third person under the original sender's name
  (tested in `testSignaturesDontTransferToAnotherRecipient`).
- The sender's identity is inside the encryption: the server can't read who a message is from.
- A message is accepted only if its sender is a known contact whose pinned keys verify
  the signature. The exception is a first message: it can introduce its sender with
  a signed card that matches the sender box and verifies the message itself. Such a
  sender shows as **New** until you accept them, and nothing they send plays or reaches
  the tray before that.

## Message bodies

```
body = u32be len(header) || header JSON || attachment_0 || attachment_1 || …
```

The header holds `kind` (`voice`, `files`, `text`, `todo`, `todoDone`, `talking`, `menuBar`, `live`), an id,
a time, and per kind the transcript, duration, loudness samples, file names and sizes,
reminder time, or to-do reference. Voice notes carry one AAC (`.m4a`) attachment.
File messages carry one attachment per file. File names are reduced to a single path
component before anything is written to disk. Until someone has written back, messages
also carry an `intro`: our signed card and our send token, so they can reply.

`talking` messages are **signals**: tiny sealed envelopes posted to
`/signals`. The server passes them to whoever is listening and never stores them. They
make a face ripple on the other Mac while someone holds yours. They are dropped if older
than two minutes.

`menuBar` messages are stored like any other. `active` says whether the sender has the
recipient in their menu bar. Nothing shows in the chat. They're sent once per change, and again on
the next connect if sending failed.

## Live talk

Two people who have each other in the menu bar can talk live: the listener hears the
speaker while they speak, not after. Everything goes through `/signals`, so nothing is stored.

1. For each listener the speaker makes a random 16-byte **session** id and a random
   AES-256 **key**, and sends a `live` signal sealed and signed like any envelope:
   `ref` = session (hex), `key` = the key, `active` = true.
2. The microphone is encoded as Opus (48 kHz, mono, 24 kbit/s, 20 ms packets). Every
   100 ms, five packets go out as one frame per listener:

```
frame   = "XNWL" || 0x01 || session (16) || u32be seq || flags || AES-256-GCM(key, packets)
            (nonce || ciphertext || tag; the AAD is everything before it)
packets = u16be count || (u16be len || Opus packet)…
flags   = 0x01 on the last frame
```

The listener plays a talk only if the speaker is in **their own** menu bar. A `live`
signal from anyone else is dropped, so nobody can make your Mac speak unless you put
them there. Frames are played in `seq` order. A missing frame is waited for 250 ms, then
skipped. A talk with no frames for 3 s ends.

Because only the speaker and the listener know the key, a frame that opens came from the
speaker. Each listener gets their own key, so one listener can't forge frames for another.
Like signals, live audio has the protections in the next section. The server sees a session
id, sizes and timing (roughly when and how long someone talks), and never the audio.

## The server's view

**Protected:** voice, transcripts, file names and contents, text, to-dos and reminders,
and who sent each message. Anyone holding the storage (host, bucket provider, backups)
gets ciphertext only. So does an operator, or someone with the API token.

**Not protected:**

1. **Metadata.** The server sees which mailbox receives how many messages of what size
   and when, which IP addresses post and listen, which mailboxes are online, and when
   someone is holding a face (signals are timed, though sealed). Two Macs on the same
   server also reveal that they are in touch, through timing.
2. **Unverified contacts.** Whoever runs the server can put its own keys in the directory
   or in a card for an unverified contact. Verify safety numbers, or add people by invite.
3. **The Macs themselves.** Messages and files are stored readable in
   `~/Library/Application Support/XNotch/ExtensionData/walkie` so they can be replayed and
   opened. The keys are in the login Keychain. Anyone with your unlocked macOS account
   can read both.
4. **No forward secrecy per message.** Each message uses a fresh KEM encapsulation, but all
   are sealed to the recipient's long-term X-Wing key. Someone who later steals that key
   and kept old ciphertext can read it. Messages are deleted from the server after
   they're fetched, which narrows this to copies taken while a message waited.
5. **Transcripts** are made by macOS's on-device speech recognizer. Walkie refuses to
   transcribe when on-device recognition isn't available, rather than send audio to a server.

## Server API

All bodies are JSON unless noted. `{box}` is 64 lowercase hex characters.

| Route | Auth | What |
| --- | --- | --- |
| `PUT /api/walkie/boxes/{box}` | API token **and** `X-Walkie-Secret: <secret hex>` | Register or update: `{"post_token", "card", "listed"}`. |
| `DELETE /api/walkie/boxes/{box}` | API token and secret | Remove the mailbox and everything waiting in it. |
| `GET /api/walkie/directory` | API token | Listed mailboxes: `[{"box", "card", "post_token"}]`. |
| `GET /api/walkie/boxes/{box}/card` | `Bearer <send token>` | `{"card"}`. |
| `POST /api/walkie/boxes/{box}/messages` | `Bearer <send token>` | Sealed bytes (`application/octet-stream`), at most `WALKIE_MAX_MESSAGE`. `201 {"id", "delivered"}`; `429` while `WALKIE_MAX_PENDING` messages wait. |
| `POST /api/walkie/boxes/{box}/signals` | `Bearer <send token>` | Sealed bytes, at most 16 KiB, passed to listeners only. `202 {"delivered"}`. |
| `POST /api/walkie/presence` | send token per entry | `{"boxes": [{"box", "token"}]}` (up to 64) → `{"boxes": [{"box", "online", "last_seen"?}]}`. Entries with a wrong token are left out. |
| `GET /api/walkie/boxes/{box}/messages` | `Bearer <secret>` | `{"messages": [{"id", "size"}]}`, oldest first. |
| `GET /api/walkie/boxes/{box}/messages/{id}` | `Bearer <secret>` | The sealed bytes. |
| `DELETE /api/walkie/boxes/{box}/messages/{id}` | `Bearer <secret>` | After it was opened. |
| `GET /api/walkie/boxes/{box}/listen` | `Bearer <secret>` (header) | WebSocket. Text frames `{"type":"message","id","size"}` or `{"type":"resync"}`; binary frames are signals. Pings every 20 s. A mailbox shows as online while a socket listens. |

Message ids are 16 hex digits of the arrival time in milliseconds followed by 16 random
hex digits. Only the posting routes, presence and the socket skip the API token, so a
contact on another server can still reach you.

Settings: `WALKIE` (`on`), `WALKIE_MAX_MESSAGE` (32 MiB), `WALKIE_RETENTION_DAYS` (7),
`WALKIE_MAX_PENDING` (500). See the [reference](REFERENCE.md#configuration).

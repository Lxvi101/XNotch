# XNotch Cloud reference

Details for operators and client authors. To set up a server, start with the
[self-hosting guide](SELF_HOSTING.md).

- [Configuration](#configuration)
- [Rate limiting and client identity](#rate-limiting-and-client-identity)
- [Relay](#relay)
- [API](#api)
- [Storage layout](#storage-layout)
- [Development](#development)

## Configuration

All settings are environment variables; [`.env.example`](../.env.example) lists them
with comments. Empty values count as unset.

| Variable | Default | Notes |
| --- | --- | --- |
| `PUBLIC_URL` | required | Base URL of the server, e.g. `https://drop.example.com`. Links are `{PUBLIC_URL}/{id}`. |
| `API_TOKEN` | required | At least 16 characters. The Mac app sends it as a Bearer token. |
| `PORT` | `8080` | Listens on `0.0.0.0`. |
| `SITE_NAME` | `XNotch Cloud` | Shown on pages and in `/api/info`. |
| `STORAGE` | `local` | `local` or `s3`. |
| `DATA_DIR` | `/data` | Folder for local storage. |
| `S3_BUCKET` | | Required for `s3`. |
| `S3_ENDPOINT` | | For non-AWS providers, e.g. `https://s3.eu-central-003.backblazeb2.com`. `http://` is allowed (MinIO on a LAN). |
| `S3_REGION` | `us-east-1` | Use the provider's region (`auto` for R2). |
| `S3_ACCESS_KEY_ID` / `S3_SECRET_ACCESS_KEY` | | Credentials. |
| `S3_PREFIX` | | Optional folder inside the bucket. |
| `S3_VIRTUAL_HOSTED_STYLE` | `false` | Requests are path-style by default so B2 and MinIO work. |
| `MAX_FILE_SIZE` | `5368709120` | Bytes per file (5 GiB). |
| `DEFAULT_EXPIRY` | `86400` | Seconds, used when the app does not ask for an expiry. |
| `MAX_EXPIRY` | `2592000` | Longest allowed lifetime in seconds (30 days). |
| `ID_LENGTH` | `8` | Characters in a drop id, 6 to 32. |
| `RELAY` | `on` | `on` or `off`. When off, every relay route returns `404` and `/api/info` says `"relay": false`. |
| `RELAY_MAX_MESSAGE` | `8388608` | Largest relayed WebSocket message in bytes (8 MiB), 1024 to 268435456. Larger messages close that socket with `1009`. |
| `RELAY_MAX_PAIRS` | `64` | Phones connected at once (waiting for or paired with a Mac). Beyond this a phone is closed with `4503`. |
| `RELAY_MAX_WAITING` | `256` | Waiting Mac sockets across all rooms. Beyond this a new Mac socket is closed with `4503`. |
| `RELAY_PHONE_WAIT` | `10` | Seconds a phone waits for a Mac before it is closed with `4404` (0 to 300). |
| `RELAY_IDLE_TIMEOUT` | `1800` | Seconds without a data message in either direction before a pair is closed. |
| `TRUSTED_PROXIES` | empty | Comma-separated proxy IPs/CIDRs. Empty uses socket peers only; see below. |
| `RATE_LIMIT_PUBLIC_PER_MINUTE` / `RATE_LIMIT_PUBLIC_BURST` | `120` / `60` | Public pages, downloads, unknown paths; password posts also use this bucket. |
| `RATE_LIMIT_PASSWORD_PER_MINUTE` / `RATE_LIMIT_PASSWORD_BURST` | `10` / `5` | Public POST/password attempts across all drop IDs, including invalid forms/drops. |
| `RATE_LIMIT_API_PER_MINUTE` / `RATE_LIMIT_API_BURST` | `120` / `60` | API authentication and management, including uploads and invalid tokens. |
| `RATE_LIMIT_RELAY_PER_MINUTE` / `RATE_LIMIT_RELAY_BURST` | `30` / `20` | Relay upgrade attempts, including invalid rooms/handshakes. |
| `RATE_LIMIT_MAX_CLIENTS` | `10000` | Maximum tracked client IPs, 1 to 1000000. New clients receive `429` when full. |
| `RATE_LIMIT_IDLE_SECONDS` | `900` | Idle expiry, 1 to 86400 seconds; must cover every bucket's full refill time. |
| `PASSWORD_CONCURRENCY` | `4` | Shared Argon2 creation/verification slots, 1 to 64; no waiting queue. |
| `RUST_LOG` | `info` | Log level. Set `LOG_FORMAT=json` for JSON log lines. |

## Rate limiting and client identity

Limits apply per client IP and per process. Each token bucket starts with `BURST`
tokens, refills continuously at `PER_MINUTE`, and never exceeds `BURST`. Both values
must be integers from 1 to 1000000. Public password posts consume both the public
and password budgets; API and relay admission have their own budgets. Admission is
checked before authentication, body parsing, storage access or WebSocket upgrades.

- **Rejections** return JSON with **429**, a positive `Retry-After` in seconds, and
  `Cache-Control: no-store`. `GET /healthz` (and HEAD) is exempt, even when the
  client table is full. Accepted uploads/downloads and upgraded sockets are never
  interrupted by request limits; relay capacity, message and idle limits still apply.
- **Client table.** Bounded, with one bounded expiry-index entry per IP. Idle entries
  expire after `RATE_LIMIT_IDLE_SECONDS` and are reclaimed incrementally on later
  requests (at most 64 removals per request). That timeout must be at least the
  longest full refill time, `60 * BURST / PER_MINUTE`, so expiry cannot reset a
  depleted budget early. Live entries are never evicted to make room: at capacity,
  unknown clients fail closed with 429 and an estimated retry time, while known
  clients keep their limits. Rejected attempts refresh idle time. Missing socket
  metadata in an embedded router or a poisoned limiter lock also fails closed.
- **Password work.** Creating and verifying passwords share `PASSWORD_CONCURRENCY`
  blocking-job slots (about 19 MiB per Argon2 run with default parameters). When all
  are busy, requests get 429 with `Retry-After: 1` immediately; there is no queue.
  A cancelled request keeps its slot until the blocking job actually finishes.

**Direct access:** leave `TRUSTED_PROXIES` empty. The socket peer IP is the identity;
ports are ignored and IPv4-mapped IPv6 is normalized. `X-Forwarded-For`, `Forwarded`
and `X-Real-IP` cannot change it.

**Reverse proxies:** set `TRUSTED_PROXIES` to literal IP addresses or CIDRs of only
proxies you control, for example `127.0.0.1,::1,10.42.0.8/32`. Hostnames, malformed
entries, `/0`, and lists over 128 entries or 8192 bytes fail startup. Only a request
from a trusted socket peer may use `X-Forwarded-For`. Its plain-IP chain is walked
right to left, stopping at the first untrusted hop, so an attacker-controlled prefix
is ignored. Multiple header lines are processed in order. Missing, malformed,
over-2048-byte or over-32-hop chains fall back to the socket peer. Other forwarded
headers are never used. Configure every trusted proxy to replace client-supplied
forwarding headers or append the actual immediate peer, and restrict backend access.
Never trust all private networks or a shared subnet containing untrusted containers.

**Bundled Caddy HTTPS overlay:** it pins Caddy to `172.30.254.2` and the backend to
`172.30.254.3` on a dedicated `172.30.254.0/29` bridge, and sets `TRUSTED_PROXIES`
to just the Caddy address. The Caddyfile replaces X-Forwarded-For with its socket
peer; Caddy's [forwarding-header rules](https://caddyserver.com/docs/caddyfile/directives/reverse_proxy#defaults)
describe its default spoofing protections. Do not attach untrusted containers. If the
subnet conflicts, change the bridge subnet, both static addresses and the trust entry
together in [`deploy/compose.https.yml`](../deploy/compose.https.yml). This assumes
Caddy receives internet traffic directly. Behind another load balancer or CDN, design
and test that proxy's trust and header configuration explicitly; otherwise clients
share its IP. For Dokploy/Traefik, configure the actual ingress peer IP/CIDR
yourself; leaving trust empty safely groups all traffic through that proxy into one
client budget.

These controls slow guessing, enumeration and request bursts. They do not provide
identity or tenant isolation, bandwidth or total-storage quotas, upload concurrency
limits, or distributed DDoS protection. Clients behind NAT share an IP budget;
IPv6 address rotation or botnets can fill the table and deny new clients. State
resets on restart and is not shared across replicas. Keep ingress connection,
body-size and concurrency controls, resource monitoring and storage budgets.

## Relay

The relay lets the XNotch iPhone app talk to the Mac when they are not on the same
network. Neither side needs an open port: both connect **out** to this server over a
WebSocket, and the server pairs them and pipes messages between them.

- **End-to-end encrypted.** XNotch encrypts every relay payload with a key from the
  phone-to-Mac pairing. The server never sees plaintext and does not parse what it
  forwards; it only counts bytes.
- **Rooms.** A room is 64 lowercase hex characters (256 bits) derived by both apps
  from their pairing key. The Mac registers it with the API token; after that,
  knowing the room id is the credential for connecting. Rooms are stored at
  `relay/rooms/{room}` and survive restarts.
- **Pairing.** The Mac keeps a few sockets waiting in its room (at most 8; a 9th
  replaces the oldest). A phone takes the oldest waiting Mac socket. If none is
  waiting, the phone waits up to `RELAY_PHONE_WAIT` seconds for one.
- **Forwarding.** Binary and text messages are forwarded verbatim, one at a time:
  the server awaits each send, so a slow side slows the other down instead of
  filling memory. When either side closes, the other is closed too.
- **Keep-alive.** The server pings every socket every 20 seconds, so proxies and
  NAT routers keep idle connections open. Pairs with no data message for
  `RELAY_IDLE_TIMEOUT` seconds are closed.
- **Logs** show pair and unpair events with only the first 6 characters of a room
  id. Request logs shorten relay room ids the same way.

For proxy timeouts, see [Other reverse proxies](SELF_HOSTING.md#other-reverse-proxies).

### Close codes

| Code | Reason | When |
| --- | --- | --- |
| `1000` | | The other side left, the pair was idle for `RELAY_IDLE_TIMEOUT`, or the room was deleted. |
| `1009` | `message too big` | This socket sent a message larger than `RELAY_MAX_MESSAGE`. |
| `4404` | `mac offline` | A phone found no waiting Mac within `RELAY_PHONE_WAIT`. |
| `4409` | `replaced` | A waiting Mac socket was replaced by a newer one (more than 8 in the room). |
| `4503` | `relay busy` | `RELAY_MAX_PAIRS` (phones) or `RELAY_MAX_WAITING` (Macs) reached. |

### Relay resources

Each relayed message is held in memory whole while it passes through (read buffer
plus write buffer). The theoretical worst case is roughly
`RELAY_MAX_PAIRS × 4 × RELAY_MAX_MESSAGE` (64 × 4 × 8 MiB, about 2 GiB), if every
pair sends maximum-size messages in both directions at the same moment. Real use is
far lower: an idle or waiting socket costs a few KB, and a pair moving small messages
a few tens of KB. On a small machine such as a Raspberry Pi, lower `RELAY_MAX_PAIRS`
or `RELAY_MAX_MESSAGE`. Relay traffic counts against the server's bandwidth in both
directions.

## API

Authenticated endpoints need `Authorization: Bearer <API_TOKEN>`; a missing or wrong
token returns `401`. All API responses are JSON. Errors look like
`{"error": "message"}` with a matching status code. Timestamps are RFC 3339 in UTC
with whole seconds, e.g. `2026-10-14T09:30:00Z`. Every route except `/healthz` may
return `429` from the [rate limits](#rate-limiting-and-client-identity).

```sh
export URL=https://drop.example.com TOKEN=your-api-token
```

### `GET /healthz`

No auth. Returns `200` with the text `ok`.

### `GET /api/info`

```sh
curl -H "Authorization: Bearer $TOKEN" $URL/api/info
```
```json
{"name":"XNotch Cloud","version":"0.1.0","max_file_size":5368709120,"default_expiry_seconds":86400,"max_expiry_seconds":2592000,"relay":true,"passwords":true}
```
`relay` is `false` when `RELAY=off`. `passwords` says the server supports drop passwords.

### `POST /api/drops`

Body (all fields optional; an empty body is fine):
`{"expires_in": 3600, "title": "Holiday photos", "password": "correct horse"}`.
`expires_in` is in seconds, defaults to `DEFAULT_EXPIRY` and is clamped to
`[60, MAX_EXPIRY]`. The response always carries the effective `expires_at`.
Titles are trimmed and cut to 200 characters; an empty title counts as none.
With a `password` (at most 1024 bytes, else `400`; empty means none), visitors must
enter it before they see the page or download anything. Only an Argon2id hash is stored.

```sh
curl -X POST -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"expires_in": 3600, "title": "Holiday photos"}' $URL/api/drops
```
`201`:
```json
{"id":"8122cbAZ","url":"https://drop.example.com/8122cbAZ","expires_at":"2026-10-14T09:30:00Z","protected":false}
```
`protected` is `true` when the drop has a password. Older servers ignore `password`
and leave `protected` out, so check it before handing out a link meant to be locked.

### `PUT /api/drops/{id}/files/{name}`

The raw request body is the file. `name` is percent-encoded in the path. Names must
not be empty, `.` or `..`, contain `/`, `\` or control characters, or exceed 255 bytes
(`400`). Uploading an existing name replaces the file. Unknown or expired drop: `404`.
Too large: `413` (checked from `Content-Length` up front and again while streaming).

```sh
curl -X PUT -H "Authorization: Bearer $TOKEN" --data-binary @"Report 1.pdf" \
  "$URL/api/drops/8122cbAZ/files/Report%201.pdf"
```
`201`:
```json
{"name":"Report 1.pdf","size":48213,"url":"https://drop.example.com/8122cbAZ/Report%201.pdf"}
```

The content type is guessed from the file extension; if there is none, a specific
`Content-Type` request header is used, otherwise `application/octet-stream`.

### `DELETE /api/drops/{id}`

Deletes the drop and its files. `204` on success, `404` if it does not exist
(or had already expired).

```sh
curl -X DELETE -H "Authorization: Bearer $TOKEN" $URL/api/drops/8122cbAZ
```

### `GET /api/drops`

Active drops, newest first.

```sh
curl -H "Authorization: Bearer $TOKEN" $URL/api/drops
```
```json
[{"id":"8122cbAZ","url":"https://drop.example.com/8122cbAZ","title":"Holiday photos",
  "created_at":"2026-10-14T08:30:00Z","expires_at":"2026-10-14T09:30:00Z","protected":false,
  "files":[{"name":"Report 1.pdf","size":48213}]}]
```
`title` is `null` when not set.

### `PUT /api/relay/rooms/{room}`

Registers a relay room. `room` must be 64 lowercase hex characters (`400` otherwise).
Idempotent: registering an existing room changes nothing. `204` with no body.

```sh
curl -X PUT -H "Authorization: Bearer $TOKEN" $URL/api/relay/rooms/$ROOM
```

### `DELETE /api/relay/rooms/{room}`

Unregisters a room and closes all of its sockets (waiting and paired) with `1000`.
`204` even if the room was unknown. Invalid room: `400`.

### `GET /api/relay/rooms/{room}/connect?role=mac|phone`

WebSocket endpoint. **No token**: knowing the room id is the credential. Checked
before the upgrade, as JSON errors: invalid room `400`, missing or unknown `role`
`400`, room not registered `404`. With `RELAY=off` every relay route returns `404`.

- `role=mac`: the socket waits in the room. It learns it has been paired only when
  the first message from the phone arrives; the server sends it nothing else
  (apart from pings). Messages a Mac sends while still waiting are discarded.
- `role=phone`: paired with the oldest waiting Mac socket, or closed with `4404`
  after `RELAY_PHONE_WAIT`. The phone may send its first message right away; if it
  arrives while the phone is still waiting, the server holds it (one message) and
  delivers it once paired.

See [Relay](#relay) for forwarding, limits and close codes.

```sh
# For example with websocat:
websocat "wss://drop.example.com/api/relay/rooms/$ROOM/connect?role=mac"
```

### `GET /{id}`

Public HTML page for the drop. Unknown or expired drops get a styled 404 page.
For a drop with a password, it is a password form instead that shows nothing about
the drop (not even its title) until the password is entered. Pages are served with a
strict `Content-Security-Policy`, `Referrer-Policy: no-referrer`,
`X-Frame-Options: DENY` and `noindex`; user text is HTML-escaped.

### `POST /{id}`

The password form (`application/x-www-form-urlencoded`, field `password`). A right
password answers `303` to `/{id}` with an `HttpOnly`, `SameSite=Lax` cookie scoped to
`/{id}` that lasts until the drop expires (`Secure` when `PUBLIC_URL` is https). A wrong
one answers `403` with the form again, after a 750 ms delay. Drops without a password
just redirect.

### `GET /{id}/{name}`

For a locked drop without its unlock cookie, `303` to `/{id}`. Otherwise streams the
file as a download (`Content-Disposition: attachment` with an RFC 5987 `filename*`).
With `?inline=1`, raster images, video, audio, PDF and plain text are shown inline;
everything else (including SVG and HTML) is still an attachment. Single
`Range: bytes=...` requests return `206`, so videos can seek and downloads can
resume. Every response carries `X-Content-Type-Options: nosniff`.

## Storage layout

```
drops/{id}/meta.json        id, title, created_at, expires_at, files [{name, size, content_type}],
                            and for locked drops password_hash (Argon2id) and unlock_key
drops/{id}/files/{name}     file contents
relay/rooms/{room}          {"created_at": "..."} for each registered relay room
```

There is no database; the metadata files are the source of truth. The server
expects to be the only instance writing to its storage. Expiry is enforced on every
read; a sweeper runs at startup and every 10 minutes and deletes expired drops.

## Development

From `Server` (Rust 1.88 or newer):

```sh
cargo test
cargo clippy --all-targets -- -D warnings
cargo fmt --check
```

Code map: `config` (environment), `ids` (drop ids), `names` (file name rules,
encoding, content types), `password` (drop passwords and unlock cookies),
`rate_limit` (per-client admission and proxy trust), `range` (Range header), `model`
(metadata), `storage` (object_store backends, sweeper), `api` (JSON API), `relay`
(WebSocket relay), `public` and `pages` (drop page and downloads). Tests:
`tests/api.rs` drives the router directly; `tests/relay.rs` runs a real listener
with WebSocket clients; `tests/rate_limit.rs` covers limits and client identity.

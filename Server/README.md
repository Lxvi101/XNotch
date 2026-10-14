# XNotch Cloud

A small, self-hostable file-drop server. It backs the **Cloud** button in XNotch:
the Mac uploads files from its shelf and gets a short public link that expires,
like `https://drop.example.com/8122cbAZ`.

- One static binary (Rust, about 7 MB), no database.
- Stores files on local disk or in any S3-compatible bucket (AWS S3, Backblaze B2,
  Cloudflare R2, MinIO).
- Runs on a small VPS or a Raspberry Pi (arm64). Deploys with Dokploy or plain Docker.
- Uploads are streamed straight to storage, so large files do not use much memory.
- Optional password per drop: the page and every file stay locked until it is entered.
- Clean, dark drop page with image previews. Downloads support resuming and video seeking.
- Expired drops stop working immediately and are deleted within 10 minutes.
- A WebSocket [relay](#relay) lets the XNotch iPhone app reach the Mac when the two are
  on different networks. Payloads are end-to-end encrypted; the server only pipes bytes.

## Quick start

```sh
cd Server
cp .env.example .env
# Edit .env: set PUBLIC_URL and API_TOKEN (openssl rand -base64 32)
# Uncomment the `ports:` lines in docker-compose.yml to reach it on localhost:8080
docker compose up -d --build
curl http://localhost:8080/healthz   # ok
```

Without Compose:

```sh
docker build -t xnotch-cloud Server
docker run -d --name xnotch-cloud -p 8080:8080 -v xnotch-data:/data \
  -e PUBLIC_URL=http://localhost:8080 -e API_TOKEN=change-me-to-a-long-secret \
  xnotch-cloud
```

Without Docker (Rust 1.88 or newer): `PUBLIC_URL=http://localhost:8080 API_TOKEN=... DATA_DIR=./data cargo run --release`.

In XNotch, enter the server URL (`PUBLIC_URL`) and the API token, then use **Test connection**.

## Configuration

All settings are environment variables. Empty values count as unset.

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
| `RUST_LOG` | `info` | Log level. Set `LOG_FORMAT=json` for JSON log lines. |

## Deploy with Dokploy

### Application (Dockerfile)

1. **Create Application** in a project.
2. **General → Provider:** your Git provider, this repository, branch of choice.
3. **Build Type:** Dockerfile. **Docker File:** `Server/Dockerfile`. **Docker Context Path:** `Server`.
4. **Environment:** at least
   ```
   PUBLIC_URL=https://drop.example.com
   API_TOKEN=<openssl rand -base64 32>
   ```
   plus any of the settings above (for S3, see the B2 example below).
5. **Domains:** add `drop.example.com`, **Container Port** `8080`, enable **HTTPS** (Let's Encrypt).
   Point the DNS record at the server first.
6. **Advanced → Volumes:** add a **Volume mount** (named volume), e.g. name `xnotch-data`,
   mount path `/data`. Not needed when `STORAGE=s3`.
7. **Deploy.** Dokploy builds on the server, so a Raspberry Pi gets an arm64 image.

The container runs as uid 65532. Named volumes get the right owner automatically.
If you use a **bind mount** instead, run `sudo chown -R 65532:65532 /path/on/host` first;
the server refuses to start if `/data` is not writable.

### Compose

1. **Create Compose** service, select the repository, **Compose Path** `./Server/docker-compose.yml`.
2. **Environment:** the same variables as above (Dokploy writes them to `.env`).
3. **Domains:** service `xnotch-cloud`, port `8080`, HTTPS on.
4. **Deploy.** The compose file only `expose`s port 8080; Traefik routes the domain to it.

## Backblaze B2

1. Create a **private** bucket, e.g. `my-xnotch-drops`. Note its endpoint, e.g.
   `s3.eu-central-003.backblazeb2.com`; the region is the middle part, `eu-central-003`.
2. **Application Keys → Add a New Application Key**, restricted to that bucket,
   with read and write access. Copy the `keyID` and `applicationKey`.
3. Set:
   ```
   STORAGE=s3
   S3_BUCKET=my-xnotch-drops
   S3_ENDPOINT=https://s3.eu-central-003.backblazeb2.com
   S3_REGION=eu-central-003
   S3_ACCESS_KEY_ID=<keyID>
   S3_SECRET_ACCESS_KEY=<applicationKey>
   ```

Other providers work the same way:
**Cloudflare R2:** `S3_ENDPOINT=https://<account-id>.r2.cloudflarestorage.com`, `S3_REGION=auto`.
**AWS S3:** leave `S3_ENDPOINT` empty and set `S3_REGION`.
**MinIO:** `S3_ENDPOINT=http://minio:9000`.

Files are streamed through the server in both directions, so the bucket can stay
private. Consider a bucket lifecycle rule that aborts incomplete multipart uploads
after a day, in case the server is killed mid-upload.

## Raspberry Pi

- Use a 64-bit OS (Raspberry Pi OS 64-bit or Ubuntu arm64). 32-bit is not tested.
- The first build compiles all dependencies and takes 10 to 20 minutes on a Pi 4.
  Later builds reuse the cached dependency layer unless `Cargo.toml`/`Cargo.lock` change.
- At runtime the server uses a few MB of RAM, plus up to about 24 MB per upload
  in progress when `STORAGE=s3` (multipart buffers), plus relay messages in
  flight (see [Relay resources](#resources)).
- For local storage, prefer an SSD over the SD card.

## Relay

The relay lets the XNotch iPhone app talk to the Mac when they are not on the same
network. Neither side needs an open port: both connect **out** to this server over a
WebSocket, the server pairs them and pipes messages between them.

- **End-to-end encrypted.** XNotch encrypts every payload with a key from the
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

### Behind Dokploy, Traefik or another proxy

WebSockets pass through Traefik (and so Dokploy) without extra configuration: the
same domain, port 8080 and HTTPS setup as above. Clients connect with `wss://`.
If relay connections drop at a fixed interval (for example every 60 seconds),
look at the proxy's read or idle timeouts; in Traefik v3 that is
`entryPoints.<name>.transport.respondingTimeouts.readTimeout` (`0` disables it).
Cloudflare's proxy also passes WebSockets; the 20-second pings stay well inside
its idle timeout.

### Close codes

| Code | Reason | When |
| --- | --- | --- |
| `1000` | | The other side left, the pair was idle for `RELAY_IDLE_TIMEOUT`, or the room was deleted. |
| `1009` | `message too big` | This socket sent a message larger than `RELAY_MAX_MESSAGE`. |
| `4404` | `mac offline` | A phone found no waiting Mac within `RELAY_PHONE_WAIT`. |
| `4409` | `replaced` | A waiting Mac socket was replaced by a newer one (more than 8 in the room). |
| `4503` | `relay busy` | `RELAY_MAX_PAIRS` (phones) or `RELAY_MAX_WAITING` (Macs) reached. |

### Resources

Each relayed message is held in memory whole while it passes through (read
buffer plus write buffer), so the theoretical worst case is roughly
`RELAY_MAX_PAIRS × 4 × RELAY_MAX_MESSAGE` (64 × 4 × 8 MiB, about 2 GiB) if every
pair sends maximum-size messages in both directions at the same moment. Real use
is far lower: an idle or waiting socket costs a few KB, and a pair moving small
messages a few tens of KB. On a small machine such as a
Raspberry Pi, lower `RELAY_MAX_PAIRS` or `RELAY_MAX_MESSAGE`. Relay traffic counts
against the server's bandwidth in both directions.

## API

Authenticated endpoints need `Authorization: Bearer <API_TOKEN>`; a missing or wrong
token returns `401`. All API responses are JSON. Errors look like
`{"error": "message"}` with a matching status code. Timestamps are RFC 3339 in UTC
with whole seconds, e.g. `2026-10-14T09:30:00Z`.

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
the drop (not even its title) until the password is entered.

### `POST /{id}`

The password form (`application/x-www-form-urlencoded`, field `password`). A right
password answers `303` to `/{id}` with an `HttpOnly`, `SameSite=Lax` cookie scoped to
`/{id}` that lasts until the drop expires (`Secure` when `PUBLIC_URL` is https). A wrong
one answers `403` with the form again, after a short delay. Drops without a password
just redirect.

### `GET /{id}/{name}`

For a locked drop without its unlock cookie, `303` to `/{id}`. Otherwise streams the file as a download (`Content-Disposition: attachment` with an RFC 5987
`filename*`). With `?inline=1`, raster images, video, audio, PDF and plain text are
shown inline; everything else (including SVG and HTML) is still an attachment.
Single `Range: bytes=...` requests return `206`, so videos can seek and downloads
can resume. Every response carries `X-Content-Type-Options: nosniff`.

## Storage layout

```
drops/{id}/meta.json        id, title, created_at, expires_at, files [{name, size, content_type}],
                            and for locked drops password_hash (Argon2id) and unlock_key
drops/{id}/files/{name}     file contents
relay/rooms/{room}          {"created_at": "..."} for each registered relay room
```

There is no database; the metadata files are the source of truth. The server
expects to be the only instance writing to its storage.

## Security notes

- **The API token is the only credential.** Use a long random value
  (`openssl rand -base64 32`), only over HTTPS. It is compared in constant time.
  Rotate it by changing `API_TOKEN` and redeploying, then update XNotch.
- **Public links are bearer links.** Anyone with a link can download until it
  expires. Ids are 8 random base62 characters (about 47 bits) from a CSPRNG;
  raise `ID_LENGTH` if you want longer ones.
- **Drop passwords** add a second secret on top of the link. They are hashed with
  Argon2id; at most 4 hashes are checked at once and every wrong guess waits 750 ms,
  which slows guessing but does not stop it, so use more than a short word. Unlocking
  sets a cookie holding a random per-drop key (not the password); deleting the drop
  revokes it. Direct file links of a locked drop lead to the password form.
- **Expiry is enforced on every read**, so an expired link is dead immediately.
  A sweeper runs at startup and every 10 minutes and deletes expired drops.
- Pages are served with a strict `Content-Security-Policy`, `Referrer-Policy: no-referrer`,
  `X-Frame-Options: DENY` and `noindex`. User text is HTML-escaped. Files that a
  browser could execute (HTML, SVG, ...) are always downloads, never rendered.
- **Relay rooms are bearer secrets too.** A room id is 256 bits, so it cannot be
  guessed, but anyone who has it can connect. Payloads are end-to-end encrypted by
  XNotch, so a stranger in a room cannot read or forge messages; at worst they can
  occupy waiting slots. Delete the room (`DELETE /api/relay/rooms/{room}`) to cut
  it off.
- There is no rate limiting. If the server is exposed to abuse, add a limit in
  Traefik or your reverse proxy.

## Development

```sh
cargo test
cargo clippy --all-targets -- -D warnings
cargo fmt --check
```

Code map: `config` (environment), `ids` (drop ids), `names` (file name rules,
encoding, content types), `password` (drop passwords and unlock cookies), `range` (Range header), `model` (metadata), `storage`
(object_store backends, sweeper), `api` (JSON API), `relay` (WebSocket relay),
`public` and `pages` (drop page and downloads). Tests: `tests/api.rs` drives the
router directly; `tests/relay.rs` runs a real listener with WebSocket clients.

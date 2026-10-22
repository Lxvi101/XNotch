# XNotch Cloud

The self-hosted server behind the **Cloud** button in XNotch. The Mac uploads files
from its shelf and gets a short link that expires, like
`https://drop.example.com/8122cbAZ`. It can also relay the XNotch iPhone app to the
Mac when they are on different networks.

- One small Rust binary, no database. Files go to local disk or any S3-compatible bucket.
- Optional password per drop. Expired links stop working immediately.
- Runs in Docker on a small VPS or a 64-bit Raspberry Pi.

**Security in one paragraph.** One shared API token controls the whole server, and
anyone holding a drop link can download it until it expires. Uploaded files are
stored unencrypted on the server, so whoever runs the host or bucket can read them.
Relay traffic is end-to-end encrypted between the phone and the Mac. This suits a
person or a trusted team; it is not a multi-user document system. Read the
[security assessment](docs/SECURITY.md) before using it for a company or customer.

## Try it locally

With Docker installed:

```sh
git clone https://github.com/Lxvi101/XNotch.git
cd XNotch/Server
docker build -t xnotch-cloud .
TOKEN=$(openssl rand -hex 32)
docker run -d --name xnotch-cloud -p 127.0.0.1:8080:8080 -v xnotch-data:/data \
  -e PUBLIC_URL=http://localhost:8080 -e API_TOKEN="$TOKEN" xnotch-cloud
curl http://localhost:8080/healthz   # ok
echo "$TOKEN"
```

In **XNotch → Settings → Cloud**, enter `http://localhost:8080` and the token, then
use **Test connection**. Remove it with `docker rm -f xnotch-cloud && docker volume rm xnotch-data`.

Without Docker (Rust 1.88 or newer):
`PUBLIC_URL=http://localhost:8080 API_TOKEN=... DATA_DIR=./data cargo run --release`.

## Run it for real

To share links with other people, the server needs an HTTPS address they can reach.
Follow the **[self-hosting guide](docs/SELF_HOSTING.md)**: an illustrated Ubuntu
walkthrough with Docker, automatic HTTPS, verification, backups and upgrades, plus
Dokploy, S3/B2 and Raspberry Pi notes.

## Documentation

| Document | For |
| --- | --- |
| [Self-hosting guide](docs/SELF_HOSTING.md) | Installing, securing, backing up and upgrading a server. |
| [Reference](docs/REFERENCE.md) | All settings, rate limits and proxy trust, the relay, the HTTP API, storage layout, development. |
| [Security assessment](docs/SECURITY.md) | What the server protects, its limits, and a deployment checklist. |

# XNotch Cloud security assessment

Scope: source review of the current server and deployment configuration, October 2026.
This is not a penetration test, independent audit, or compliance certification.

## Is it suitable for enterprise use?

It can serve a trusted team under an organization's operational controls, but it
should not be described as an enterprise identity or tenant-isolation platform.
Use a separate instance, token, storage location, and domain for each customer or
trust boundary. For sensitive data, complete your own security review before rollout.

### Controls present

- Management API requests require a shared Bearer token, compared in constant time
  (`src/api.rs`). Configure a randomly generated 32-byte secret and HTTPS.
- Drop passwords use salted Argon2id hashes. Unlock cookies are HttpOnly,
  SameSite=Lax, path-scoped, and Secure when `PUBLIC_URL` uses HTTPS
  (`src/password.rs`). Creation and verification share four non-queuing blocking
  worker slots by default (`PASSWORD_CONCURRENCY`); busy requests get 429 with
  `Retry-After: 1`. Worker permits survive HTTP cancellation until work finishes;
  failed attempts still incur a delay (`src/public.rs`).
- Bounded per-IP token buckets admit public requests (120/minute, burst 60),
  password posts (10/minute, burst 5, also charged to public), API auth/management
  (120/minute, burst 60), and relay upgrades (30/minute, burst 20) before request
  work. Limits return 429 with `Retry-After`; health probes are exempt and admitted
  streams continue. At most 10000 client entries are kept, with 900-second idle
  expiry and bounded incremental cleanup. New clients fail closed at capacity;
  live entries are never evicted to reset budgets (`src/rate_limit.rs`).
- Client identity defaults to the socket peer. Forwarded headers are ignored unless
  the socket peer is in explicitly configured `TRUSTED_PROXIES` IP/CIDR ranges.
  X-Forwarded-For is walked from right to left through trusted hops; invalid or
  oversized chains fall back to the peer. The Caddy overlay uses a fixed private
  proxy IP and overwrites client-supplied forwarding headers. Other ingress needs
  an explicit trust setup, or all its clients share one budget.
- IDs use cryptographic randomness; the default eight base62 characters provide
  about 48 bits of entropy. `ID_LENGTH=22` provides about 131 bits for new drops
  (`src/ids.rs`). Changing this does not change existing links.
- Reads reject expired drops; a background sweep attempts deletion every ten
  minutes. Filenames are validated, page text escaped, and executable HTML/SVG
  files served as attachments. Pages use CSP and anti-framing headers.
- The Docker image runs as UID/GID 65532. The HTTPS deployment overlay additionally
  drops Linux capabilities and makes the application root filesystem read-only.
- Cloud links are end-to-end encrypted by default ([E2EE.md](E2EE.md)). The Mac encrypts
  contents, file names and titles with AES-256-GCM under a random per-drop key that only
  travels in the link's `#` fragment. The server holds no key, stores ciphertext and opaque object names,
  and recipients decrypt in the browser with Web Crypto. While the Mac setting is on, the
  client fails closed: it never uploads plaintext to a server without the capability, and
  it refuses plain-`http` servers other than localhost.
- The companion protocol encrypts relay payloads in the clients using ChaChaPoly
  (`Shared/XNotchLink/Sources/XNotchLink/SecureChannel.swift`). The relay forwards
  bytes; room IDs are bearer credentials. It can still observe traffic metadata.

### Material limitations and operator actions

1. **One token grants instance-wide management access.** All token holders can list,
   upload to, and delete drops and manage relay rooms. There are no per-user tokens,
   RBAC, SSO, MFA, tenant boundaries, or individual credential revocation. Treat
   every configured Mac as an instance administrator. Rotation requires updating
   every client; rotating the API token does not revoke drop links, unlock cookies,
   or existing relay room secrets. Delete affected drops/rooms separately.
2. **End-to-end encryption protects stored data, not recipients from a hostile server.**
   With encrypted links (the default), storage, backups and host administrators see only
   ciphertext. But the decrypting page comes from the same server, so a server that is
   compromised or malicious *while a link is opened* can serve a page that steals the key
   from the URL. Anyone who holds the full link can decrypt. Keys can't be revoked:
   deleting a drop removes the ciphertext but not copies already downloaded or backed up.
   A lost key means the files can't be recovered. The server still sees metadata: file
   count and sizes, times, IP addresses, expiry, and the drop password when set. Drop
   passwords gate HTTP access but are not encryption keys. Links made with encryption
   turned off, or by older clients, are stored as plaintext; for those, use encrypted host
   volumes or private buckets with restricted credentials, including backups. Browsers
   decrypt only over HTTPS (or on localhost). Files over 1 GiB can be saved only in desktop
   Chrome or Edge (File System Access API); in other browsers a file up to 1 GiB is held in
   memory while it is verified. See [E2EE.md](E2EE.md) for the format and full threat model.
3. **Public links and unlock cookies are transferable secrets.** Passwords are
   optional, not enforced by server policy. Share passwords separately; prefer long
   IDs and short expiry. Do not rely on obscurity for highly sensitive documents.
4. **Abuse controls remain local and limited.** Per-IP request limits and bounded
   password workers slow guessing and bursts, but are not distributed DDoS defense.
   NAT users share limits; IPv6 rotation/botnets can fill the bounded table and deny
   new clients until idle expiry. State resets on restart and is not shared across
   replicas. There is no total storage quota, upload concurrency limit, malware
   scanning, or DLP; a token holder can still exhaust storage. Apply ingress
   connection/concurrency limits, disk budgets and alerts, and an appropriate
   scanning process. Trust only controlled proxy peers and verify real-client
   separation, especially behind Dokploy/Traefik/CDNs. See the
   [rate-limit reference](REFERENCE.md#rate-limiting-and-client-identity) before
   tuning defaults.
5. **Operational logs are not a user audit trail.** Request paths contain drop IDs
   and filenames (opaque object names for encrypted drops; the key fragment never
   reaches the server or its logs); creation logs contain IDs. Relay room IDs are shortened in app
   request logs, but external proxies may log complete room URLs. Restrict log
   access/retention, redact secrets in upstream logging, and never log Authorization
   headers or cookies. There is no reliable attribution to an individual uploader.
6. **Expiry is not guaranteed physical erasure.** Sweep failures, offline servers,
   snapshots, backups, S3 versioning and object retention can preserve bytes beyond
   link expiry. Monitor sweep errors and align backup/lifecycle policies with your
   retention requirements. Do not promise secure erasure after ten minutes.
7. **Single-writer storage.** Run one server replica per storage namespace. Do not
   scale replicas against the same data directory/bucket prefix. Plan maintenance
   downtime and test restoration; this is not an HA cluster.
8. **Supply-chain and host maintenance remain yours.** Builds use Cargo.lock, but
   container base tags can change. Record reviewed commits and image digests, scan
   dependencies/images, rebuild for security updates, and patch Linux/Docker.

## Deployment acceptance checklist

- [ ] Separate customer instances and storage; inventory everyone with the API token.
- [ ] Valid HTTPS URL; backend 8080 unreachable from other machines; SSH restricted.
- [ ] Random token stored in a password manager; `.env` mode 0600 and excluded from Git.
- [ ] Private encrypted storage/backups; least-privilege storage credentials.
- [ ] `ID_LENGTH=22`, appropriate expiry/file limits; relay disabled if unused.
- [ ] Password and anonymous access tests performed with non-sensitive sample data.
- [ ] Encrypted links verified end to end over HTTPS; users told that the full link is the key.
- [ ] Trusted proxy identity and 429/health behavior tested; ingress connection/concurrency
      controls, resource monitoring, alerting and log retention configured.
- [ ] Restore drill and token/room/drop revocation procedure tested.
- [ ] Independent review for the customer's data classification and compliance needs.

See the [self-hosting guide](SELF_HOSTING.md#linux-server-walkthrough-ubuntu-2404-lts)
for deployment commands. This checklist does not certify the resulting deployment.

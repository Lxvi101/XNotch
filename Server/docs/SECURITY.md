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
2. **Cloud uploads are not end-to-end encrypted.** The server receives file plaintext
   and stores file contents without application-level encryption. Drop passwords
   gate HTTP access; they do not encrypt files. Host/storage administrators and a
   compromised server can read them. Use encrypted host volumes or private buckets
   with managed encryption and tightly restricted credentials, including backups.
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
   separation, especially behind Dokploy/Traefik/CDNs. See the README's rate-limit
   configuration and saturation behavior before tuning defaults.
5. **Operational logs are not a user audit trail.** Request paths contain drop IDs
   and filenames; creation logs contain IDs. Relay room IDs are shortened in app
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
- [ ] Trusted proxy identity and 429/health behavior tested; ingress connection/concurrency
      controls, resource monitoring, alerting and log retention configured.
- [ ] Restore drill and token/room/drop revocation procedure tested.
- [ ] Independent review for the customer's data classification and compliance needs.

See the [Linux walkthrough](../README.md#linux-server-walkthrough-ubuntu-2404-lts)
for deployment commands. This checklist does not certify the resulting deployment.

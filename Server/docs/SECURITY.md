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
  (`src/password.rs`). Password verification concurrency is capped at four;
  failed attempts incur a delay (`src/public.rs`).
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
4. **Abuse controls are incomplete.** There is no built-in per-client rate limit,
   total storage quota, upload concurrency limit, malware scanning, or DLP. Password
   checks have a concurrency cap but waiting requests can still consume resources;
   password hashing on authenticated drop creation has no equivalent semaphore.
   The shared token can therefore be used to exhaust CPU or storage. Apply ingress
   request/concurrency limits, disk budgets and alerts, and an appropriate scanning
   process. The bundled Caddy example provides TLS, not rate limiting.
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
- [ ] Ingress abuse controls, resource monitoring, alerting and log retention configured.
- [ ] Restore drill and token/room/drop revocation procedure tested.
- [ ] Independent review for the customer's data classification and compliance needs.

See the [Linux walkthrough](../README.md#linux-server-walkthrough-ubuntu-2404-lts)
for deployment commands. This checklist does not certify the resulting deployment.

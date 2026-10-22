# Tutorial capture provenance

Captured October 22, 2026, on an isolated OrbStack Ubuntu 24.04 arm64 VM.

- `01-docker-installed.png`: browser-rendered recording of actual OS, Docker,
  Compose and hello-world command output. This is not a native terminal screenshot.
- `02-services-running.png`: browser-rendered recording of actual Compose and
  HTTP verification output. The displayed `compose ...` abbreviates the two file
  arguments documented in the tutorial.
- `03-password-protected.png` and `04-drop-unlocked.png`: actual browser screenshots
  of the running Linux server, before and after unlocking a disposable sample drop.

The demo used local HTTP at `xnotch-docs.orb.local`; no public DNS or ACME certificate
issuance was tested. The production guide uses HTTPS. No API token or customer data
is included. The demo password and uploaded text are disposable test fixtures.

Validation performed: official Docker apt installation; Compose configuration;
Linux Docker image build; non-root/read-only application startup; Caddy configuration
validation for both local HTTP and the documented HTTPS URL; private backend port;
health/authentication checks; password-protected upload and byte-identical download;
local volume archive restored byte-for-byte to a fresh volume and restored-server
health check. All 43 existing Rust tests passed on the macOS host.

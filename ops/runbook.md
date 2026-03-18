# Ops Runbook (write)

Scope reminder: write is the command layer. It validates/signs/idempotently
processes mutations and emits publish/apply events to
`blackcat-darkmesh-ao`. It must stay secret-minimal (public keys only); PSP/SMTP
secrets live upstream (gateway/web).

## Start / Stop
- Env file: `/etc/blackcat/write.env` based on `ops/env.prod.example`.
- Start under your supervisor with
  `LUA_PATH="?.lua;?/init.lua;ao/?.lua;ao/?/init.lua" lua ao/write/process.lua`
  (or your wrapper).
- Health: `WRITE_WAL_PATH=... WRITE_OUTBOX_PATH=... LUA_PATH=... lua scripts/verify/health.lua`
  (checks WAL/outbox size/hash and deps).

## Key rotation (ed25519)
- Public keys at `/etc/ao/keys/write-ed25519.pub`; private keys in secure store.
- Steps:
  1) `ssh-keygen -t ed25519 -f /etc/ao/keys/write-ed25519-new -N ''`.
  2) Update env `WRITE_SIG_PUBLIC=/etc/ao/keys/write-ed25519-new.pub`; deploy.
  3) Run `scripts/verify/libsodium_strict.sh` and `scripts/verify/preflight.sh`.
  4) After validation, retire old pubkey and archive private safely.
- Outbox HMAC: rotate `OUTBOX_HMAC_SECRET` by adding new, deploy, then drop old
  after AO/verifiers accept the new one.

## Idempotency / replay
- Keep `WRITE_REQUIRE_SIGNATURE=1` and `WRITE_REQUIRE_NONCE=1`.
- Configure nonce window (`WRITE_NONCE_TTL_SECONDS`, `WRITE_NONCE_MAX`) and
  idempotent cache persistence (`WRITE_IDEM_PATH` if you need restart safety).

## WAL / outbox hygiene
- Paths: `WRITE_WAL_PATH`, `WRITE_OUTBOX_PATH`; cap sizes with
  `WRITE_WAL_MAX_BYTES` and queue metrics.
- Monitor via `scripts/verify/checksum_alert.sh`; run
  `ops/checksum-daemon.service` (see unit file).
- Forwarder/worker: `ops/outbox-daemon.service` can drive
  `scripts/bridge/forward_outbox_http.lua` (configure `AO_ENDPOINT`,
  `AO_API_KEY`, `AO_QUEUE_PATH`, `AO_QUEUE_LOG_PATH`).
- Rotation: if `write.wal.bytes` > threshold (see alert), archive/move WAL and
  restart forwarder. Prefer logrotate-style: copytruncate the WAL file after
  pausing forwarder, keep immutable bundle export as audit trail.
  - Example logrotate: `ops/logrotate/write-wal.conf` (adjust path to
    your `WRITE_WAL_PATH`).

## Incident response
- Duplicate/replay complaints: inspect `WRITE_IDEM_PATH` (if enabled) and WAL;
  do not wipe without approval.
- Delivery failures to AO: check queue/backoff settings
  (`AO_BRIDGE_RETRIES`, `AO_BRIDGE_BACKOFF_MS`, `AO_QUEUE_MAX_RETRIES`) and HMAC
  validation.
- Signature failures: verify `WRITE_SIG_PUBLIC` and clock skew; regenerate keys
  if compromised.

## Dependency pinning
- Lua rocks pinned in `ops/rocks.lock`; update via `luarocks` + lock refresh and
  commit the lockfile. If you add npm/pip deps, pin them and store the lock in
  `ops/`.

## Restore / backup SOP
- WAL/outbox live at `WRITE_WAL_PATH` / `WRITE_OUTBOX_PATH`; keep copies on durable
  storage (rsync/s3) plus optional immutable export `WRITE_OUTBOX_EXPORT_PATH`.
- Restore flow:
  1) Stop forwarder/daemon (`systemctl stop outbox-daemon`).
  2) Copy last good WAL/outbox snapshot back to the configured paths (preserve perms).
  3) Run `scripts/verify/checksum_daemon.sh` once to recompute hashes; ensure
     `scripts/verify/checksum_alert.sh` passes.
  4) Start forwarder and monitor metrics `write.outbox.queue_size`,
     `write.webhook.retry_queue`, `write.wal.bytes`.
- If WAL is huge/corrupt: archive it, start with empty file, but keep the
  immutable export for audit.

## HMAC/JWT rotation
- OUTBOX HMAC: set `OUTBOX_HMAC_SECRET=new`, deploy, then rotate AO verifier to
  accept the new HMAC. After confirming, remove the old secret. Keep alerts on
  `write.webhook.verify_fail` to catch drift.
- JWT/nonce: keep `WRITE_REQUIRE_SIGNATURE=1`, `WRITE_REQUIRE_NONCE=1`.
  Rotate `WRITE_JWT_HS_SECRET` by:
  1) Add new secret to vault and env.
  2) Deploy write with new secret.
  3) Run `scripts/verify/action_validation.lua` and a smoke publish to ensure tokens are issued.
- After rotation, run `scripts/verify/checksum_alert.sh` to confirm checksum
  matches current WAL/outbox files.

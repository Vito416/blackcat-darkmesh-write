# Deploy Runbook

Audience: ops/infra teams deploying the write AO process to production-like hosts.

## Pre-flight
- Ensure Lua 5.4 + required rocks are installed (`luarocks --version`); refresh pinned deps if needed (`ops/rocks.lock`).
- Run `scripts/verify/preflight.sh` with `RUN_CONTRACTS=1 RUN_CONFLICTS=1` to cover schema, contract, and conflict checks.
- Verify git/tag matches the intended release and that local changes are clean except approved hotfixes.
- Secrets checklist:
  - `OUTBOX_HMAC_SECRET` **must be 64 hex chars (32 bytes)**; non-hex will fail `scripts/verify/secrets_lint.sh` and cause HMAC drift.
  - `WRITE_SIG_TYPE` matches the provided key: `WRITE_SIG_PUBLIC` for ed25519/ecdsa, `WRITE_SIG_SECRET` for hmac.
  - Arweave gate: set `ARWEAVE_VERIFY_FILE`, `ARWEAVE_VERIFY_TX`, `ARWEAVE_VERIFY_REF` + `ENFORCE_ARWEAVE_HASH=1` if you want fail-closed hashing; leave unset to skip enforcement.

## Prepare host
- Copy `ops/env.prod.example` to `/etc/blackcat/write.env` and fill secrets/paths:
  - Set `WRITE_WAL_PATH=/var/lib/ao/write-wal.ndjson` (matches logrotate) and `WRITE_OUTBOX_PATH=/var/lib/ao/write-outbox.json`.
  - Tune retry knobs exposed for the worker: `OUTBOX_RETRY_LIMIT`, `OUTBOX_BACKOFF_MS`, `WRITE_WEBHOOK_RETRY_MAX`, `WRITE_WEBHOOK_RETRY_BASE_SECONDS`.
  - Point metric outputs: `METRICS_PROM_PATH=/var/lib/ao/metrics.prom` (exporter/sidecar reads this), set `METRICS_FLUSH_INTERVAL_SEC`.
  - Secrets: `OUTBOX_HMAC_SECRET` (32b hex, must match AO), `WRITE_SIG_PUBLIC`, `WRITE_REQUIRE_SIGNATURE=1`; optional `WRITE_JWT_HS_SECRET` if JWT enforced.
- Create and chown runtime dirs to `blackcat:blackcat` (or service user):
  `mkdir -p /var/lib/ao /var/log/ao /etc/ao/keys && chown -R blackcat:blackcat /var/lib/ao /var/log/ao`.
- Stage code at `/opt/blackcat-darkmesh-write` (rsync or untar artifact) and keep previous release under `/opt/blackcat-darkmesh-write.prev` for rollback.

## Wire services
- Install / refresh units:
  - `cp ops/outbox-daemon.service /etc/systemd/system/` (outbox forwarder scaffold).
  - `cp ops/systemd/write-checksum.service /etc/systemd/system/` (WAL/outbox integrity).
  - `systemctl daemon-reload`.
- Install log rotation aligned to WAL path:
  `cp ops/logrotate/write-wal.conf /etc/logrotate.d/write-wal`.
- If you run the AO process under systemd/supervisor, point it at `LUA_PATH="?.lua;?/init.lua;ao/?.lua;ao/?/init.lua" lua ao/write/process.lua` with `/etc/blackcat/write.env` loaded.

## Deploy + restart
- `systemctl enable --now outbox-daemon` (or start your bridge worker wrapper).
- `systemctl enable --now write-checksum`.
- Restart the write process binary/runner via your supervisor after updating code + env.
- Tail logs for the first 5 minutes: `journalctl -u outbox-daemon -u write-checksum -f`.

## Post-deploy checks
- Health probe: `WRITE_WAL_PATH=/var/lib/ao/write-wal.ndjson WRITE_OUTBOX_PATH=/var/lib/ao/write-outbox.json LUA_PATH="?.lua;?/init.lua;ao/?.lua;ao/?/init.lua" lua scripts/verify/health.lua`.
- Metrics spot-check: ensure `METRICS_PROM_PATH` contains `write_wal_bytes`, `write_webhook_retry_queue`, `write_webhook_retry_lag_seconds`, `write_wal_apply_duration_seconds`, `write_idempotency_collisions_total`.
- Smoke commands: `lua scripts/cli/run_command.lua fixtures/sample-save-draft.json` then `lua scripts/cli/run_command.lua fixtures/sample-publish.json`; confirm WAL grows and outbox queue drains.
- Optional: force a logrotate dry run `logrotate -f /etc/logrotate.d/write-wal` on a canary host to verify permissions.
- Arweave publish (arkb, optional): use workflow `Arweave Deploy (arkb)` (`.github/workflows/arkb-deploy.yml`) with inputs `artifact_path` (default `dev/write-export.ndjson`), `content_type` (default `application/json`). Requires secret `ARKB_WALLET_JSON_B64` (base64 wallet JSON). Workflow summary prints TXID + SHA256.

## AO push.forward.computer deploy flow (module + PID)
- Build/publish:
  - `node scripts/build-write-bundle.js`
  - `ao-dev build`
  - `node scripts/publish-wasm.js` (capture module TX)
- Spawn:
  - `AO_MODULE=<module_tx> HB_URL=https://push.forward.computer HB_SCHEDULER=n_XZJhUnmldNFo4dhajoPZWhBXuJk-OcQr5JQ49c4Zo node scripts/cli/spawn_wasm_tn.js`
  - capture PID from script output.
- Required finalization gate before production cutover:
  - `curl -s -o /dev/null -w '%{http_code}\n' https://arweave.net/raw/<module_tx>`
  - `curl -s -o /dev/null -w '%{http_code}\n' https://arweave.net/raw/<pid>`
  - promote only after both return `200`.
- Deep smoke after finalization:
  - `HB_URL=https://push.forward.computer HB_SCHEDULER=n_XZ... AO_PID=<pid> node scripts/cli/diagnose_message.js`
  - `HB_URL=https://push.forward.computer HB_SCHEDULER=n_XZ... AO_PID=<pid> node scripts/cli/send_write_command.js`

## Arweave release hash gate
- Purpose: CI fails closed if the shipped artifact hash differs from the reference stored on Arweave.
- Set secrets (repo or org):
  - `ARWEAVE_VERIFY_FILE` — filename of the artifact (e.g., `blackcat-darkmesh-write-v1.0.0.tar.gz`).
  - `ARWEAVE_VERIFY_TX` — Arweave TXID containing that artifact.
  - `ARWEAVE_VERIFY_REF` — git ref or tag to hash locally (e.g., `v1.0.0`).
  - `ENFORCE_ARWEAVE_HASH=1` — enables the gate; without it, the step is skipped.
- CI step (`scripts/verify/verify_arweave_hash.sh`) will:
  1) Download TX data, compute SHA256.
  2) Check out `ARWEAVE_VERIFY_REF` and hash the local artifact path; compare.
  3) Fail if hashes mismatch or file/tx missing.
- Ops triage:
  - If mismatch: verify you uploaded the right artifact, re-upload (same file) or update `ARWEAVE_VERIFY_TX`/`ARWEAVE_VERIFY_REF` to the intended release.
  - If TX not found: ensure gateway availability and TX finality; retry later.
  - For hotfixes: temporarily set `ENFORCE_ARWEAVE_HASH=0` only on a hotfix branch, never on main/release.

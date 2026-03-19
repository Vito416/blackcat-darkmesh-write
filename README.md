# blackcat-darkmesh-write
[![Project: Blackcat Mesh Nexus](https://img.shields.io/badge/Project-Blackcat%20Mesh%20Nexus-000?logo=github)](https://github.com/users/Vito416/projects/2) [![CI](https://github.com/Vito416/blackcat-darkmesh-write/actions/workflows/ci.yml/badge.svg)](https://github.com/Vito416/blackcat-darkmesh-write/actions/workflows/ci.yml)

![Write Banner](.github/blackcat-darkmesh-write-banner.jpg)

AO-native command layer for Blackcat Darkmesh. This repository hosts the write-side AO processes that enforce idempotent, authorized, and auditable changes to the canonical state maintained in `blackcat-darkmesh-ao`. No separate server-side authority exists; any bridge or admin client is only a transport adapter.

## Scope
- In scope: AO command processes, handlers, idempotency registry, audit/event emission, publish workflow (draft → review → publish → rollback), validators and schemas, minimal adapters, deploy/verify scripts, fixtures, CI workflows.
- Out of scope: public read/state model (lives in `blackcat-darkmesh-ao`), gateway rendering, frontend assets, mailbox payload storage, SMTP/OTP/PSP integrations, template/catalog UI, or long-term secret storage (only public keys here).

## Architecture Snapshot
- Role: command-first AO process set that owns write semantics, conflict detection, and append-only audit; delegates state materialization to `blackcat-darkmesh-ao`.
- Pipeline: command envelope → validation (schema + policy) → idempotency / anti-replay → handler → audit + event → downstream AO state update.
- Identity & auth: signed commands or capability tokens; gateway is never an implicit authority.
- Idempotence: `requestId` registry and optimistic `expectedVersion` guards to prevent duplicate writes.
- Audit: append-only log with correlation to requestId and actor; deterministic status codes.

## Repository Layout (blueprint)
```
docs/              # command contracts, flows, failure modes, ADRs, runbooks
ao/                # AO command process and shared libs
  write/           # command handlers, routing
  shared/          # auth, idempotency, validation, audit
schemas/           # JSON schemas for command envelopes and actions
scripts/           # deploy | verify
fixtures/          # sample command envelopes and expected outcomes
tests/             # contract, conflict, and security tests
scripts/bridge/    # stub forwarder from write outbox to -ao
scripts/cli/       # local helpers (run command)
.github/workflows/ # CI entrypoint
```

## Minimal Command Envelope
- Required tags: `Action`, `Request-Id`, `Actor`, `Tenant`, `Expected-Version`, `Nonce`, `Signature-Ref`, `Timestamp`.
- Core handlers (initial set): `SaveDraftPage`, `PublishPageVersion`, `UpsertRoute`, `UpsertProduct`, `UpsertProfile`, `AssignRole`, `GrantEntitlement`, `LinkDomain`, `RotateKey`, `CreateReceipt`.
- Conflict strategy: reject on missing/expired nonce, replayed `Request-Id`, or mismatched `Expected-Version`; return prior result when replayed.

## Development
- Prereqs: `lua5.4` (or `luac`) and `python3`.
- Static checks: `scripts/verify/preflight.sh` (JSON schema validation + Lua syntax).
- Contract smoke tests: `LUA_PATH="?.lua;?/init.lua;ao/?.lua;ao/?/init.lua" lua5.4 scripts/verify/contracts.lua` (or set `RUN_CONTRACTS=1` to run during preflight).
- Conflict/security smoke tests: `LUA_PATH="?.lua;?/init.lua;ao/?.lua;ao/?/init.lua" lua5.4 scripts/verify/conflicts.lua` (or `RUN_CONFLICTS=1`).
- Batch fixtures: `LUA_PATH="?.lua;?/init.lua;ao/?.lua;ao/?/init.lua" lua5.4 scripts/cli/batch_run.lua` (or `RUN_BATCH=1` in preflight) – compares fixtures to `*.expected.json`.
- Branches: `main` (releasable), `develop` (integration), `feature/*`, `adr/*`, `release/*`.
- Message contracts and schemas are public API; prefer additive changes over breaking ones.

### Quickstart (local dev)
1) Install deps: `sudo apt-get install lua5.4 lua5.4-dev luarocks libsodium-dev`  
   then install rocks from the lockfile:
   ```bash
   while read -r name ver; do
     case "$name" in \#*|"") continue ;;
     esac
     luarocks --lua-version=5.4 install --local "$name" "$ver"
   done < ops/rocks.lock
   ```
2) Copy env template: `cp ops/env.prod.example ops/.env.local` and fill secrets:  
   - `OUTBOX_HMAC_SECRET` (required)  
   - signature verifier (`WRITE_SIG_PUBLIC` or `WRITE_SIG_SECRET` when `WRITE_SIG_TYPE=hmac`)  
   - optional `WRITE_JWT_HS_SECRET` if you turn on `WRITE_REQUIRE_JWT=1`.
3) Run checks: `RUN_DEPS_CHECK=1 LUA_PATH="?.lua;?/init.lua;ao/?.lua;ao/?/init.lua" LUA_CPATH="$HOME/.luarocks/lib/lua/5.4/?.so" scripts/verify/preflight.sh`.
4) Fixtures: `RUN_BATCH=1 LUA_PATH="?.lua;?/init.lua;ao/?.lua;ao/?/init.lua" lua scripts/cli/batch_run.lua` (uses the env from step 2; hashes/nonce/signature checks can be relaxed via `WRITE_REQUIRE_*` env).
5) Outbox/queue paths in the template default to `/var/lib/ao/...`; for dev you can override to `dev/*` paths next to the repo.
6) Optional specs:  
   - JWT: `RUN_JWT_SPEC=1 lua5.4 scripts/verify/jwt_actor_spec.lua` + `scripts/verify/jwt_expiry_spec.lua`  
   - Rate/nonce: `RUN_RATE_SPEC=1 WRITE_RATE_STORE_PATH=dev/write-rate-store.json lua5.4 scripts/verify/rate_store_spec.lua`; `RUN_RATE_SPEC=1 lua5.4 scripts/verify/rate_tenant_scope_spec.lua`  
   - Outbox HMAC: `RUN_OUTBOX_SPEC=1 lua5.4 scripts/verify/outbox_hmac_spec.lua`

## Env toggles (write process)
- `WRITE_REQUIRE_SIGNATURE=1` — reject commands without `signatureRef`.
- `WRITE_REQUIRE_NONCE=1` — reject commands without nonce and block replay.
- `WRITE_NONCE_TTL_SECONDS` (default 300) and `WRITE_NONCE_MAX` (default 2048) — nonce cache sizing.
- `WRITE_ALLOW_ANON=1` — allow missing actor/tenant (off by default).
- `WRITE_SIG_TYPE=ed25519|ecdsa|hmac` (prod default: `ed25519`); `WRITE_SIG_PUBLIC` (PEM) or `WRITE_SIG_SECRET` (hmac key) to verify `signature`.
- Optional JWT gate: set `WRITE_JWT_HS_SECRET` (HS256) and optionally `WRITE_REQUIRE_JWT=1` to fail-closed; claims `sub/tenant/role/nonce` populate `actor/tenant/role/nonce` when missing.
- `WRITE_WAL_PATH=/var/lib/ao/write-wal.ndjson` — append-only WAL with request/response hashes.
- `WRITE_IDEM_PATH=/var/lib/ao/write-idem.json` — persist idempotent responses across restarts (optional).
- `WRITE_OUTBOX_PATH=/var/lib/ao/write-outbox.json` — persist outbox events (used by forwarders/export).
- Checksum watchdog: `ops/systemd/write-checksum.service` + `scripts/verify/checksum_daemon.sh` (set `WRITE_WAL_PATH`, `WRITE_OUTBOX_PATH`, `CHECKSUM_INTERVAL_SEC`).
- Resolver flags: `WRITE_FLAGS_PATH=/etc/ao/resolver-flags.ndjson` to block/readonly resolvers (shared with registry/AO); enforced before policy.
- Shipping/Tax export for AO: persist rates with `WRITE_RATE_STORE_PATH` and run `scripts/export/rates.lua [rate_store] [shipping.ndjson] [tax.ndjson]`; point AO to the outputs via `AO_SHIPPING_RATES_PATH` / `AO_TAX_RATES_PATH`.
- Dispute evidence payload: `AddDisputeEvidence` accepts `evidence.url|hash|hashAlgo|type|note|fileName` to carry provider links/hashes; stored in `payment_disputes` and can be sent via provider webhooks.
- `WRITE_RL_WINDOW_SECONDS` / `WRITE_RL_MAX_REQUESTS` — rate-limit per tenant+actor (default 60s / 200 reqs).
- `WRITE_RL_BUCKET_TTL_SECONDS` / `WRITE_RL_MAX_BUCKETS` — trim idle buckets (default 4× window, 4096 buckets).
- `WRITE_RATE_STORE_PATH` — persist rate-limit buckets across restarts (optional; JSON file written atomically).
- `WRITE_NONCE_STORE_PATH` — persist nonce cache (tenant+actor namespaced) to survive restarts.
- Bridge/env for queue/HTTP: `AO_ENDPOINT=https://...` (optional); `AO_API_KEY`; `DRY_RUN=1` or `AO_BRIDGE_MODE=mock|off|http`; `AO_BRIDGE_RETRIES`/`AO_BRIDGE_BACKOFF_MS`; `AO_QUEUE_PATH` (persisted queue), `AO_QUEUE_LOG_PATH=/var/lib/ao/queue-log.ndjson`, `AO_QUEUE_MAX_RETRIES=5`, `AO_EXPECT_RESPONSE_HASH` to enforce downstream body hash.
- Outbox HMAC enforcement: `WRITE_STRICT_OUTBOX_HMAC=1` rejects outbox events without `hmac` when `OUTBOX_HMAC_SECRET` is set (default off; forwarder still checks mismatches when `hmac` is present). HMAC input defaults to full canonical JSON of the event; set `WRITE_OUTBOX_HMAC_MODE=legacy` to use the older limited field hash.
- Trust manifest signing (resolvers): set `TRUST_MANIFEST_HMAC` and run `lua scripts/cli/trust_manifest_sign.lua manifest.json > manifest.signed.json`; optionally set `TRUST_MANIFEST_SIGNER`.
- Key management: keep public keys under `/etc/ao/keys`, record their `sha256sum` in ops docs, rotate on a schedule; never store private keys in repos, artifacts, or CI logs.
- OTP/passwordless flows and payment/PSP callbacks have been removed from this repo; keep secrets and such logic in upstream gateway/web layers.

## CLI helpers
- `lua scripts/cli/run_command.lua ./fixtures/sample-save-draft.json` — route a JSON command locally and print the response (uses in-memory state). A publish sample is at `fixtures/sample-publish.json`.
- `RUN_BATCH=1 LUA_PATH="?.lua;?/init.lua;ao/?.lua;ao/?/init.lua" lua scripts/cli/batch_run.lua` — run all fixtures and enforce matches to `*.expected.json` (CI uses this).
- Queue forwarder (persisted outbox → HTTP):  
  `AO_QUEUE_PATH=dev/outbox-queue.ndjson AO_QUEUE_LOG_PATH=dev/queue-log.ndjson AO_QUEUE_MAX_RETRIES=5 LUA_PATH="?.lua;?/init.lua;ao/?.lua;ao/?/init.lua" lua scripts/bridge/queue_forward.lua`
- Health snapshot (write-side files & deps):  
  `WRITE_WAL_PATH=... WRITE_OUTBOX_PATH=... AO_QUEUE_PATH=... LUA_PATH="?.lua;?/init.lua;ao/?.lua;ao/?/init.lua" lua scripts/verify/health.lua`

## Prod hardening checklist
- Set `WRITE_STRICT_OUTBOX_HMAC=1` and ensure every emitted event includes `hmac`.
- Keep signature/JWT verification on (WRITE_REQUIRE_SIGNATURE/WRITE_REQUIRE_JWT) and rotate keys regularly.
- Persist idempotency/rate buckets/outbox where applicable (`WRITE_IDEM_PATH`, `WRITE_RATE_STORE_PATH`, `WRITE_OUTBOX_PATH`) and back them up.
- Monitor `/metrics` (bearer from METRICS_BEARER_TOKEN) for `rate_limited`, `replay_nonce`, and outbox HMAC counters; alert on sustained errors.
- If Arweave verification is mandatory on all branches, set `ENFORCE_ARWEAVE_HASH=1` and provide `ARWEAVE_VERIFY_FILE/ARWEAVE_VERIFY_TX`; CI will fail-closed otherwise.

## Monitoring
- Expose Prom-style `/metrics` via `ao.shared.metrics` (see `METRICS_PROM_PATH`, `METRICS_LOG`, `METRICS_BEARER_TOKEN`).
- Key counters:
  - `write_auth_signature_failed_total`, `write_auth_signature_missing_total`
  - `write_auth_jwt_invalid_total`, `write_auth_jwt_expired_total`, `write_auth_jwt_not_before_total`, `write_auth_jwt_skew_total`, `write_auth_jwt_*_mismatch_total`
  - `write_auth_nonce_replay_total`
  - `write_auth_rate_limited_total`
  - `write_outbox_hmac_missing_total`, `write_outbox_hmac_mismatch_total`
- Sample alerts (PromQL):
  - `increase(write_auth_rate_limited_total[5m]) > 50`
  - `increase(write_auth_jwt_invalid_total[5m]) > 5 or increase(write_auth_jwt_expired_total[5m]) > 20`
  - `increase(write_auth_nonce_replay_total[5m]) > 0`
  - `increase(write_outbox_hmac_mismatch_total[5m]) > 0 or increase(write_outbox_hmac_missing_total[5m]) > 5`
- Add alerts on rising trends; log/Prom output controlled by `METRICS_*` envs in `ao/shared/metrics.lua`.

## Bridge (stub)
- `scripts/bridge/forward_outbox.lua` reads the in-memory outbox (`write._storage_outbox()`) and logs events you would forward to `blackcat-darkmesh-ao`. Replace `forward_event` with signed POST to AO endpoint (registry/site process) in production.
- `scripts/bridge/export_outbox.lua [outfile]` dumps outbox to NDJSON (default `dev/outbox.ndjson`) for offline inspection or manual upload.
- `scripts/bridge/forward_outbox_http.lua` posts outbox events to `AO_ENDPOINT` (set `DRY_RUN=1` to log only; optional `AO_API_KEY`, `AO_SITE_ID` tag).

## Security Guard Rails
- No secrets or raw keys in AO state, manifests, or adapters.
- Gateways act only as clients; write process re-validates auth and policy.
- All comments and docs remain in English.

## License
Blackcat Darkmesh Write is licensed under `BFNL-1.0` (see `LICENSE`). Contribution and relicensing rules are governed by the companion documents in `blackcat-darkmesh-ao/docs/`. This repository is an official component of the Blackcat Covered System; repository separation inside `BLACKCAT_MESH_NEXUS` is for maintenance/safety/auditability and nevyvolává samostatnou fee událost pro stejný běžný deployment.

Canonical licensing bundle:
- BFNL 1.0: https://github.com/Vito416/blackcat-darkmesh-ao/blob/main/docs/BFNL-1.0.md
- Founder Fee Policy: https://github.com/Vito416/blackcat-darkmesh-ao/blob/main/docs/FEE_POLICY.md
- Covered-System Notice: https://github.com/Vito416/blackcat-darkmesh-ao/blob/main/docs/LICENSING_SYSTEM_NOTICE.md

## CI notes
- CI will gain a schema/manifest consistency check (WeaveDB manifest vs. JSON schemas); keep generated manifests in sync when modifying schemas.
- Future PSP/order fixtures will be added to ingest/batch smokes once the PSP abstraction and order state machine land.

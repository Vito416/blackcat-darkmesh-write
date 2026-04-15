# Ops Runbook (write command layer)

## Start / Stop
- Load env from `ops/env.prod.example` (signature/idempotency/WAL/outbox paths).
- Start the write process under your supervisor (e.g.,
  `lua5.4 ao/write/process.lua` with `LUA_PATH="?.lua;?/init.lua;ao/?.lua;ao/?/init.lua"`).
- AO/public state lives in `blackcat-darkmesh-ao`; this service only emits
  publish/apply events to AO.

## Health Checks
- Command health:  
  `WRITE_WAL_PATH=... WRITE_OUTBOX_PATH=... LUA_PATH="?.lua;?/init.lua;ao/?.lua;ao/?/init.lua" lua scripts/verify/health.lua`
  (checks WAL/outbox size/hash, deps, rate-limit state).
- Contract/conflict smoke tests: `RUN_CONTRACTS=1 RUN_CONFLICTS=1 scripts/verify/preflight.sh`.

## Idempotency / anti-replay
- Keep `WRITE_REQUIRE_SIGNATURE=1` and `WRITE_REQUIRE_NONCE=1` in production.
- Configure nonce window and cache: `WRITE_NONCE_TTL_SECONDS`, `WRITE_NONCE_MAX`.
- Request replay policy: `WRITE_IDEM_PATH` to persist idempotent outcomes across
  restarts (optional).

## Outbox / bridge integrity
- WAL: `WRITE_WAL_PATH` (append-only audit of handled commands).
- Outbox: `WRITE_OUTBOX_PATH` (events to deliver to AO). Guard size with
  `WRITE_WAL_MAX_BYTES` and monitor via health script.
- Bridge to AO: use `scripts/bridge/forward_outbox_http.lua` or queue forwarder
  with `AO_ENDPOINT`, `AO_API_KEY`, `AO_QUEUE_PATH`, `AO_QUEUE_LOG_PATH`.
- Enable HMAC on emitted events with `OUTBOX_HMAC_SECRET`; AO should verify
  before applying.

## Receipts
- Provider-specific callbacks stay in gateway/web layers.
- The write process currently persists normalized payment/order state changes
  (`ProviderWebhook`, `GoPayWebhook`, `ConfirmPayment`, `IssueRefund`).

## Key rotation SOP (ed25519)
- Rotate every 90 days or on incident.
- Generate: `openssl genpkey -algorithm ed25519 -out /secure/write-ed25519.key`
  and `openssl pkey -in ... -pubout -out /etc/ao/keys/write-ed25519.pub`.
- Record `sha256sum /etc/ao/keys/write-ed25519.pub` with date in ops vault.
- For single-key mode, set `WRITE_SIG_PUBLIC=<new key>` and restart.
- For multi-key rotation (recommended), keep a keyring in `WRITE_SIG_PUBLICS`
  keyed by `signatureRef` (for example: `gateway-a=hex:...,gateway-b=hex:...,default=hex:...`),
  roll clients to the new `signatureRef`, then remove old entries after cutover.
- Validate with signed smokes, then retire the old key. Never commit private keys
  or print them in CI logs.

## Incident Response
- Replay/duplicate: inspect `WRITE_IDEM_PATH` and WAL; clear only with explicit
  approval, as it resets idempotent responses.
- Failed deliveries to AO: retry via queue forwarder (`AO_QUEUE_MAX_RETRIES`,
  `AO_BRIDGE_RETRIES`, `AO_BRIDGE_BACKOFF_MS`); rotate HMAC secret if mismatch.
- Rate-limit exhaustion: tune `WRITE_RL_WINDOW_SECONDS`,
  `WRITE_RL_MAX_REQUESTS`, or block offending actor/tenant.

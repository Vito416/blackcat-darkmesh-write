# Ops Overview (write command layer)

What this repo is
- Canonical AO **write** layer: validates commands, enforces idempotency,
  applies policy, and emits publish/apply events to `blackcat-darkmesh-ao`.
- Not a public read runtime; no templates/rendering; no mailbox/SMTP/OTP/PSP
  storage. Secrets stay outside; only public keys appear here.

What you deploy
- Write process (`ao/write/process.lua`) plus shared libs and schemas.
- Systemd helpers: `ops/checksum-daemon.service` (WAL/outbox integrity) and
  `ops/outbox-daemon.service` (forwarder/worker scaffolding). Configure env via
  `/etc/blackcat/write.env`.
- Optional immutable export: `WRITE_OUTBOX_EXPORT_PATH` appends PII-scrubbed
  outbox/WAL/idempotency snapshots for bundling to WeaveDB; local restart
  snapshots via `WRITE_STATE_DIR`.

Key files
- `ops/runbook.md` — procedures (start/stop, key rotation, WAL/outbox care).
- `ops/env.prod.example` — baseline env (no real secrets).
- `ops/alerts.md` — Prometheus alert suggestions.
- `ops/rocks.lock` — pinned Lua rocks for deployment images.

Guard rails
- Enforce signatures + nonce/timestamp replay window (`WRITE_REQUIRE_SIGNATURE`,
  `WRITE_REQUIRE_NONCE`).
- Webhook hardening: replay window, signature verify (Stripe/PayPal), retry with
  backoff, DLQ, metrics (`write.webhook.*`, `write.psp.*`).
- Persist idempotent outcomes and WAL/outbox on durable storage; monitor sizes
  (`WRITE_WAL_MAX_BYTES`, queue metrics).
- Emit HMAC on outbox events (`OUTBOX_HMAC_SECRET`); AO should verify before
  applying.
- WeaveDB/Arweave is immutable: do **not** persist PII or erasable data here.
  Only emit pseudonymous references; sensitive payloads must stay in the
  per-site worker/inbox with delete-on-download/TTL semantics.

Observability
- Prom scrape via `METRICS_PROM_PATH`; NDJSON export via `METRICS_NDJSON_PATH`;
  log stream to `METRICS_LOG`.
- Klíčové metriky: `write.webhook.verify_fail`, `write.webhook.replay`,
  `write.webhook.retry_queue` / `webhook_retry_queue`,
  `write.webhook.retry_overdue` / `webhook_retry_overdue`,
  `write.webhook.retry_lag_seconds` / `webhook_retry_lag_seconds`,
  `write.wal.apply_duration_seconds` / `wal_apply_duration_seconds`,
  `write.idempotency.collisions_total` / `idempotency_collisions_total`,
  `write.psp.<provider>.breaker_open` / `breaker_open`,
  `write.psp.<provider>.breaker_blocked`,
  `write.outbox.queue_size` / `outbox_queue_depth`.
- HMAC/outbox: `write.outbox.queue_size`, `write_outbox_hmac_missing_total`,
  `write_outbox_hmac_mismatch_total`; monitor WAL size `write_wal_bytes`.
- Protect scrape: if exposing `/metrics` via sidecar, put behind basic auth or mTLS
  (`scrape_configs` example: `basic_auth` username/password) to avoid leaking
  operational signals.
- Grafana: sample dashboard `ops/dashboards/psp-breaker.yml` covers breaker open/
  blocked, webhook retries/verify_fail (Stripe/PayPal/GoPay), retry queue depth,
  DLQ size, and WAL bytes. Import via file provisioner or UI as needed.

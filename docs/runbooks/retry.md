# Retry & Incident Response

Use this when webhook deliveries or AO bridge forwarding is stuck/backlogged.

## Detect
- Alerts: `WriteWebhookRetryLagHigh`, `WriteWebhookRetryOverdue`, `WriteOutboxQueueLag`, `WriteDLQNonEmpty`.
- Metrics to check: `write_webhook_retry_queue`, `write_webhook_retry_lag_seconds`, `write_webhook_dlq_size`, `write_outbox_queue_size`, `write_wal_bytes`, `write_idempotency_collisions_total`.
- Files: WAL/outbox at `/var/lib/ao`, queue log at `AO_QUEUE_LOG_PATH`, state snapshots at `WRITE_STATE_DIR`.

## Clear outbox/bridge backlog
1) Confirm network/endpoint health for `AO_ENDPOINT` (curl against it).
2) Run the worker once to drain with current settings (safe to repeat):
```
WRITE_OUTBOX_PATH=/var/lib/ao/write-outbox.json \
OUTBOX_RETRY_LIMIT=${OUTBOX_RETRY_LIMIT:-5} \
OUTBOX_BACKOFF_MS=${OUTBOX_BACKOFF_MS:-500} \
LUA_PATH="?.lua;?/init.lua;ao/?.lua;ao/?/init.lua" \
lua scripts/worker/outbox_daemon.lua
```
3) If lag persists, lower `OUTBOX_BACKOFF_MS` or raise `OUTBOX_RETRY_LIMIT` in `/etc/blackcat/write.env`, then `systemctl restart outbox-daemon`.
4) Inspect `AO_QUEUE_LOG_PATH` for repeat offenders; quarantine noisy tenants instead of raising limits globally.

## Clear webhook retry queue (internal)
1) Identify provider causing retries via metrics (`write_webhook_<provider>_retry_total` and breaker gauges).
2) Trigger retries with a signed `RunWebhookRetries` command (admin/support role) via the gateway/admin channel. Minimal envelope shape:
```
{
  "action": "RunWebhookRetries",
  "tenant": "<ops-tenant>",
  "actor": "ops",
  "requestId": "retry-" + <timestamp>,
  "timestamp": <unix>,
  "nonce": "<unique>",
  "signature": "...",          // per your signing flow
  "signatureRef": "<key-id>"
}
```
3) Re-run until `write_webhook_retry_queue` reaches 0. Watch `write_webhook_retry_lag_seconds` and `write_webhook_retry_overdue` drop.
4) For DLQ items (`write_webhook_dlq_size > 0`), extract entries from the persisted state (if `WRITE_STATE_DIR` is set) and replay manually with provider-specific tooling after root-causing the failure.

## When to stop retries
- If `write_idempotency_collisions_total` spikes or provider responds 4xx consistently, pause retries and involve the product team to avoid double-processing downstream.
- For oversized WAL (`write_wal_bytes` above alert threshold), rotate WAL first (logrotate conf) to avoid disk pressure before continuing retries.

## Post-incident
- Document the failing tenants/events, the retry/backoff settings used, and whether limits were changed.
- Reset temporary overrides in `/etc/blackcat/write.env` to defaults after stability is confirmed for 30 minutes.

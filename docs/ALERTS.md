# Observability & Alerts (WRITE)

Goal: catch regressions in idempotence, outbox flow, PSP/webhooks, and schema drift early. Metrics names follow the `worker_` / `write_` prefix used in scripts/metrics.

## Prometheus rules (examples)

```
# Outbox / WAL health
- alert: WriteOutboxStuck
  expr: increase(write_outbox_queue_depth[5m]) > 0 and write_outbox_queue_depth > 100
  for: 10m
  labels: { severity: warning }
  annotations:
    summary: "Write outbox growing"
    description: "Queue depth {{ $value }} > 100 for 10m; replay or downstream blocked."

- alert: WriteWalApplySlow
  expr: histogram_quantile(0.95, rate(write_wal_apply_duration_seconds_bucket[5m])) > 2
  for: 5m
  labels: { severity: warning }
  annotations:
    summary: "WAL apply p95 > 2s"
    description: "Slow WAL apply; check DB / AO latency."

# Idempotence
- alert: WriteIdempotencyCollisions
  expr: increase(write_idempotency_collisions_total[10m]) > 5
  labels: { severity: warning }
  annotations:
    summary: "Idempotency collisions rising"
    description: "More than 5 collisions in 10m; investigate replay window or nonce store."

# Webhooks / PSP
- alert: WriteWebhookRetryLag
  expr: max_over_time(write_webhook_retry_lag_seconds[5m]) > 30
  for: 5m
  labels: { severity: critical }
  annotations:
    summary: "Webhook retry lag > 30s"
    description: "Downstream PSP/gateway likely failing; breaker may be open."

- alert: WriteBreakerOpen
  expr: increase(write_breaker_open_total[5m]) > 0
  labels: { severity: warning }
  annotations:
    summary: "Circuit breaker opened"
    description: "PSP/webhook failures triggered breaker in last 5m."

# Schema drift / contract checks
- alert: WriteSchemaDrift
  expr: increase(write_schema_validation_failed_total[10m]) > 0
  labels: { severity: warning }
  annotations:
    summary: "Schema validation failing"
    description: "Commands failing schema validation; client/server contract drift."

# Rate limits / abuse
- alert: WriteRateLimitSpike
  expr: increase(write_rate_limit_blocked_total[5m]) > 50
  labels: { severity: warning }
  annotations:
    summary: "Rate limits blocking traffic"
    description: "Possible abuse or misconfigured clients."
```

## Scrape hints
- Exporter: `scripts/verify/health.lua` and `ao/shared/metrics.lua` emit Prometheus text when `METRICS_LOG` is configured.
- Scrape with bearer/basic auth if enabled; avoid scraping from public networks.
- For Cloudflare Worker ingest, reuse the worker metrics job pattern from `blackcat-darkmesh-ao` and add this service under a separate job_name.

## Runbooks tie-in
- Pair these alerts with `docs/runbooks/outbox.md` and `docs/runbooks/webhooks.md` (if present) so oncall knows remediation steps.

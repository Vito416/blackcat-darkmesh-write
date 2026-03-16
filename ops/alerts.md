# Sample Prometheus-style alerts for write services

- alert: WriteChecksumDaemonDown
  expr: up{job="write-checksum"} == 0
  for: 2m
  labels:
    severity: warning
  annotations:
    summary: "Write checksum daemon is not running"
    description: "No scrape for job=write-checksum. Check systemd unit ops/checksum-daemon.service"

- alert: WriteOutboxQueueLag
  expr: write_outbox_queue_size > 100
  for: 5m
  labels:
    severity: critical
  annotations:
    summary: "Outbox queue backlog is high"
    description: "Pending events exceed 100. Inspect AO bridge connectivity or retry settings."

- alert: WriteWalSizeHigh
  expr: write_wal_bytes > 5242880
  for: 5m
  labels:
    severity: warning
  annotations:
    summary: "Write WAL size above 5 MiB"
    description: "Rotate or archive WAL. Check for stuck retries or noisy clients."

- alert: WriteWebhookRetryBacklog
  expr: write_webhook_retry_queue > 20
  for: 5m
  labels:
    severity: warning
  annotations:
    summary: "Webhook retry queue growing"
    description: "PSP/webhook deliveries are backing up. Check provider health and retry settings."

- alert: WritePSPBreakerOpen
  expr: write_psp_breaker_open > 0
  for: 1m
  labels:
    severity: warning
  annotations:
    summary: "PSP circuit breaker open"
    description: "PSP failures reached threshold for one or more providers. Requests are being short-circuited. Inspect provider-specific gauges write_psp_<provider>_breaker_open."

- alert: WriteWebhookProviderFailure
  expr: increase(write_webhook_paypal_retry_total[5m]) > 5 or increase(write_webhook_stripe_retry_total[5m]) > 5
  for: 2m
  labels:
    severity: warning
  annotations:
    summary: "Webhook retries accumulating"
    description: "Provider webhooks are failing repeatedly. Check retry queue and PSP status."

## Prometheus scrape example
```
scrape_configs:
  - job_name: write
    static_configs:
      - targets: ["write.yourdomain:9101"]  # METRICS_PROM_PATH via sidecar/exporter
    metrics_path: /metrics
```

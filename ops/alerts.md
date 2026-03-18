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

- alert: WritePSPProviderBreaker
  expr: (write_webhook_stripe_retry_overdue > 0) or (write_webhook_paypal_retry_overdue > 0)
  for: 2m
  labels:
    severity: warning
  annotations:
    summary: "Provider-specific breaker/retry issues"
    description: "Stripe/PayPal retries overdue; check write_psp_<provider>_breaker_open and provider health."

- alert: WritePSPBreakerStripe
  expr: write_psp_stripe_breaker_open > 0
  for: 1m
  labels:
    severity: warning
    provider: stripe
  annotations:
    summary: "Stripe breaker open"
    description: "Stripe PSP circuit is open (threshold reached). Investigate Stripe API health and error rate."

- alert: WritePSPBreakerPayPal
  expr: write_psp_paypal_breaker_open > 0
  for: 1m
  labels:
    severity: warning
    provider: paypal
  annotations:
    summary: "PayPal breaker open"
    description: "PayPal PSP circuit is open (threshold reached). Investigate PayPal API health and retries."

- alert: WritePSPBreakerGoPay
  expr: write_psp_gopay_breaker_open > 0
  for: 1m
  labels:
    severity: warning
    provider: gopay
  annotations:
    summary: "GoPay breaker open"
    description: "GoPay PSP circuit is open (threshold reached). Check GoPay connectivity and error logs."

- alert: WriteWebhookProviderFailure
  expr: increase(write_webhook_paypal_retry_total[5m]) > 5 or increase(write_webhook_stripe_retry_total[5m]) > 5
  for: 2m
  labels:
    severity: warning
  annotations:
    summary: "Webhook retries accumulating"
    description: "Provider webhooks are failing repeatedly. Check retry queue and PSP status."

- alert: WriteWebhookStripeRetryHot
  expr: increase(write_webhook_stripe_retry_total[5m]) > 10
  for: 2m
  labels:
    severity: warning
    provider: stripe
  annotations:
    summary: "Stripe webhook retries spiking"
    description: "Stripe retry volume high; investigate Stripe API failures."

- alert: WriteWebhookPayPalRetryHot
  expr: increase(write_webhook_paypal_retry_total[5m]) > 10
  for: 2m
  labels:
    severity: warning
    provider: paypal
  annotations:
    summary: "PayPal webhook retries spiking"
    description: "PayPal retry volume high; check PayPal webhooks and signatures."

- alert: WriteWebhookGoPayRetryHot
  expr: increase(write_webhook_gopay_retry_total[5m]) > 10
  for: 2m
  labels:
    severity: warning
    provider: gopay
  annotations:
    summary: "GoPay webhook retries spiking"
    description: "GoPay retry volume high; check GoPay gateway and signatures."

- alert: WriteDLQNonEmpty
  expr: write_webhook_dlq_size > 0
  for: 5m
  labels:
    severity: warning
  annotations:
    summary: "Write webhook DLQ is non-empty"
    description: "Items stuck in write webhook DLQ; inspect retry/dead-letter queue."

- alert: WriteWALGrowing
  expr: write_wal_bytes > 52428800  # 50MB
  for: 5m
  labels:
    severity: warning
  annotations:
    summary: "Write WAL exceeds 50MB"
    description: "Check WAL rotation/archiving; risk of disk growth."

- alert: WriteWebhookVerifyFail
  expr: increase(write_webhook_paypal_verify_fail_total[5m]) > 3 or increase(write_webhook_stripe_verify_fail_total[5m]) > 3
  for: 2m
  labels:
    severity: warning
  annotations:
    summary: "Webhook signature verification failing"
    description: "Repeated signature verify failures; check secrets/certs and replay attempts."

- alert: WriteWebhookReplay
  expr: increase(write_webhook_replay_total[5m]) > 3
  for: 2m
  labels:
    severity: info
  annotations:
    summary: "Webhook replay detected"
    description: "Webhook replay window hit; investigate duplicate deliveries."

- alert: WriteWebhookRetryOverdue
  expr: write_webhook_retry_overdue > 0
  for: 2m
  labels:
    severity: warning
  annotations:
    summary: "Webhook retries overdue"
    description: "Queued retries are past due. Check PSP connectivity and retry parameters."

## Prometheus scrape example
```
scrape_configs:
  - job_name: write
    static_configs:
      - targets: ["write.yourdomain:9101"]  # METRICS_PROM_PATH via sidecar/exporter
    metrics_path: /metrics
```

# Write AO Roadmap – 99% web/eshop coverage

## Ordering & Payments
- Order lifecycle: draft → confirmed → paid → fulfilled → returned → refunded (events + state machine).
- Inventory: multi-warehouse, reservations with expiry, backorder/preorder flags.
- Promotions: coupons, price rules, tax/shipping zones; idempotent apply/remove.

## PSP/Webhooks
- Unified PSP abstraction (Stripe/PayPal/GoPay) with:
  - signature/cert verify,
  - retry/backoff + jitter (3–5 attempts),
  - circuit breaker per PSP endpoint,
  - webhook_seen/idempotency store,
  - status events (`PaymentStatusChanged`, `OrderStatusUpdated`) to AO.
- Cert cache refresh job; health checks per PSP.

## Observability
- Metrics: webhook_retry_lag_seconds, breaker_open, outbox_queue_depth, wal_apply_duration, idempotency_collisions.
- Alerts: breaker_open ratio, webhook backlog age, ingest apply failures.

## Resilience
- WAL/outbox replayer tool for recovery.
- Export verifier for WRITE_OUTBOX_EXPORT_PATH (hash/size).

## Testing/CI
- Extend ingest_smoke with PSP/webhook fixture; CI check for schema manifest consistency.
- Property tests for idempotency keys.

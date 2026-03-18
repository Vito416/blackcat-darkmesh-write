# Analytics / Risk stubs

- `ao.shared.analytics.event(type, payload)` returns a timestamped event table; integrate into outbox if desired.
- Minimal plan (ready when prioritised):
  - Emit analytics events for `order_created`, `payment_status_changed`, and `shipment_updated` by piping `ao.shared.analytics.event(...)` into the outbox as a distinct stream/topic (tag events with `analytics=true`).
  - Include non-PII risk hints if the gateway supplies them (e.g., `ip_hash`, `device_id`, `user_agent_fingerprint`) and store only hashed/pseudonymous values.
  - Export analytics/risk events to the existing immutable export path (`WRITE_OUTBOX_EXPORT_PATH`) for downstream modeling; keep retention aligned with WAL rotation.
- Deferred (not implemented in code): configurable risk rules/scoring engine; wait until data owners approve fields and retention.

# Rollback Runbook

Goal: return the write process to the last known good release while preserving WAL/outbox/idempotency data.

## Quiesce + capture
- Drain traffic: take the write process out of rotation (load balancer weight 0) or set gateway to fail closed for writes.
- Snapshot persistence before any destructive change (timestamps in filenames):
  `cp /var/lib/ao/write-wal.ndjson /var/lib/ao/backups/write-wal.$(date -Iseconds).ndjson`
  `cp /var/lib/ao/write-outbox.json /var/lib/ao/backups/write-outbox.$(date -Iseconds).json`
  `cp /var/lib/ao/write-idem.json /var/lib/ao/backups/write-idem.$(date -Iseconds).json`
  `cp /var/lib/ao/outbox-queue.ndjson /var/lib/ao/backups/outbox-queue.$(date -Iseconds).ndjson`

## Revert code + config
- Swap code symlink or untar the last good artifact into `/opt/blackcat-darkmesh-write` (keep the bad build as `.failed` for forensics).
- Restore `/etc/blackcat/write.env` to the prior version; confirm WAL path matches logrotate (`/var/lib/ao/write-wal.ndjson`).
- `systemctl daemon-reload && systemctl restart outbox-daemon write-checksum` (plus your write process service).

## Validate before reopening
- Run `scripts/verify/health.lua` with production paths; expect WAL/outbox hashes to match snapshots and queue sizes to be reasonable.
- Check metrics for regressions: `write_webhook_retry_lag_seconds` near 0, `write_wal_apply_duration_seconds` steady, `write_idempotency_collisions_total` not spiking.
- Replay smoke fixtures (`scripts/cli/run_command.lua fixtures/sample-save-draft.json`) and verify deterministic responses.

## Re-enable traffic
- Put the service back into rotation; monitor alerts `WriteWebhookRetryLagHigh`, `WriteWalApplySlow`, and WAL size thresholds for 15–30 minutes.
- If issues persist, roll forward to a new hotfix rather than flipping repeatedly.

## Arweave hash gate (CI) rollback
- If CI fails on Arweave hash mismatch during an emergency hotfix, you may temporarily set `ENFORCE_ARWEAVE_HASH=0` **only in the hotfix branch**, never on `main`/`release`.
- Keep `ARWEAVE_VERIFY_FILE/ARWEAVE_VERIFY_TX/ARWEAVE_VERIFY_REF` unchanged; after uploading the corrected artifact to Arweave, re-enable `ENFORCE_ARWEAVE_HASH=1` and update TXID/ref as needed.
- Document any temporary disable/enable in the change ticket and post-mortem.

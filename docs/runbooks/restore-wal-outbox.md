# WAL / Outbox Restore

Use this when WAL or outbox files are corrupted, accidentally truncated, or a host rebuild requires restoring the write side from backups.

## Inputs
- Backup set: `write-wal.<ts>.ndjson`, `write-outbox.<ts>.json` (and optionally `write-idem.<ts>.json`, `outbox-queue.<ts>.ndjson`) kept under `/var/lib/ao/backups/` or your remote bucket.
- Recorded SHA256 for each artifact (from vault, backup log, or `journalctl -u write-checksum`).
- Target paths from env: `WRITE_WAL_PATH=/var/lib/ao/write-wal.ndjson`, `WRITE_OUTBOX_PATH=/var/lib/ao/write-outbox.json`, `AO_QUEUE_PATH=/var/lib/ao/outbox-queue.ndjson`, `WRITE_IDEM_PATH=/var/lib/ao/write-idem.json`.

## Quiesce first
- Remove the write process from rotation (LB weight 0 or gateway fail-closed).
- Stop mutation writers: `systemctl stop outbox-daemon write-checksum` and stop your write process supervisor. Goal is zero concurrent writes while restoring.
- Mount the backup source read-only if it is remote media.

## Restore steps
1) Pick a consistent timestamped backup (WAL + outbox from the same snapshot).
2) Verify integrity before touching prod files:
```
sha256sum /var/lib/ao/backups/write-wal.<ts>.ndjson
sha256sum /var/lib/ao/backups/write-outbox.<ts>.json
[ -f /var/lib/ao/backups/outbox-queue.<ts>.ndjson ] && sha256sum /var/lib/ao/backups/outbox-queue.<ts>.ndjson
```
   - If hashes diverge from the recorded values, stop and fetch another snapshot.
3) Preserve current state for forensics:
```
ts=$(date -Iseconds)
mv /var/lib/ao/write-wal.ndjson /var/lib/ao/write-wal.$ts.bad 2>/dev/null || true
mv /var/lib/ao/write-outbox.json /var/lib/ao/write-outbox.$ts.bad 2>/dev/null || true
mv /var/lib/ao/outbox-queue.ndjson /var/lib/ao/outbox-queue.$ts.bad 2>/dev/null || true
mv /var/lib/ao/write-idem.json /var/lib/ao/write-idem.$ts.bad 2>/dev/null || true
```
4) Restore backups atomically with correct ownership:
```
install -o ao -g ao -m 0640 /var/lib/ao/backups/write-wal.<ts>.ndjson /var/lib/ao/write-wal.ndjson
install -o ao -g ao -m 0640 /var/lib/ao/backups/write-outbox.<ts>.json /var/lib/ao/write-outbox.json
[ -f /var/lib/ao/backups/outbox-queue.<ts>.ndjson ] && install -o ao -g ao -m 0640 /var/lib/ao/backups/outbox-queue.<ts>.ndjson /var/lib/ao/outbox-queue.ndjson
[ -f /var/lib/ao/backups/write-idem.<ts>.json ] && install -o ao -g ao -m 0640 /var/lib/ao/backups/write-idem.<ts>.json /var/lib/ao/write-idem.json
```
5) Ensure directories remain owned by the service user: `chown -R ao:ao /var/lib/ao /var/log/ao` (or your service account).

## Validate integrity (checksums + health)
- Run the checksum alert manually to confirm size/hash and thresholds:
```
WRITE_WAL_PATH=/var/lib/ao/write-wal.ndjson \
WRITE_OUTBOX_PATH=/var/lib/ao/write-outbox.json \
RUN_CHECKSUM_ALERT=1 bash scripts/verify/checksum_alert.sh
```
- Run the health probe to ensure state aligns and deps load:
```
WRITE_WAL_PATH=/var/lib/ao/write-wal.ndjson \
WRITE_OUTBOX_PATH=/var/lib/ao/write-outbox.json \
AO_QUEUE_PATH=/var/lib/ao/outbox-queue.ndjson \
LUA_PATH="?.lua;?/init.lua;ao/?.lua;ao/?/init.lua" \
lua scripts/verify/health.lua
```
- If size thresholds trip, either raise `WRITE_WAL_MAX_BYTES`/`WRITE_OUTBOX_MAX_BYTES` temporarily or trim via logrotate before proceeding.

## Restart and monitor
- Start integrity automation first: `systemctl start write-checksum` (or `systemctl enable --now write-checksum` if it was disabled).
- Start the outbox forwarder and write process via your supervisor.
- Watch for 5–10 minutes: `journalctl -u write-checksum -u outbox-daemon -u <write-service> -f` and ensure metrics `write_wal_bytes`, `write_outbox_queue_size`, `write_webhook_retry_queue` stabilize.
- Record the new WAL/outbox SHA256 values in the ops vault alongside the backup timestamp for future restores.

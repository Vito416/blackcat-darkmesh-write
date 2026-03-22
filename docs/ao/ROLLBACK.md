# AO PID Rollback (shared -write)

## Env layout
- `AO_WRITE_PID_CURRENT` – PID in production
- `AO_WRITE_PID_PREV`    – last known-good PID

## Deploy new PID
1) Build bundle: `npm install && npm run build:ao`
2) Deploy: `AO_WALLET=path/to/jwk ao deploy --module dist/ao-write.js`
3) Set `AO_WRITE_PID_PREV=$AO_WRITE_PID_CURRENT`, then `AO_WRITE_PID_CURRENT=<new PID>` in gateway env.
4) Redeploy gateway/workers with updated env.
5) Smoke test (SaveDraftPage/Publish/Webhook).

## Rollback
1) Set `AO_WRITE_PID_CURRENT=$AO_WRITE_PID_PREV`.
2) Redeploy gateway/workers.
3) (Optional) Keep failed PID noted for post-mortem; redeploy fixed PID later.

## Canary tip
- Before step 4 in “Deploy new PID”, route only a small set of tenants to `PID_CURRENT` (feature flag/tenant map) and verify metrics. Then flip all tenants.

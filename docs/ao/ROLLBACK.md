# AO PID Rollback (shared -write)

## Env layout
- `AO_WRITE_MODULE_CURRENT` - module TX in production
- `AO_WRITE_MODULE_PREV` - last known-good module TX
- `AO_WRITE_PID_CURRENT` - PID in production
- `AO_WRITE_PID_PREV` - last known-good PID

## Deploy new module + PID
1) Build + publish WASM:
   - `node scripts/build-write-bundle.js`
   - `ao-dev build`
   - `node scripts/publish-wasm.js` (capture `<new module tx>`)
2) Spawn a new process:
   - `AO_MODULE=<new module tx> HB_URL=https://push.forward.computer HB_SCHEDULER=n_XZJhUnmldNFo4dhajoPZWhBXuJk-OcQr5JQ49c4Zo node scripts/cli/spawn_wasm_tn.js`
   - capture `<new PID>`
3) Finalization gate (mandatory):
   - wait for both `https://arweave.net/raw/<new module tx>` and `https://arweave.net/raw/<new PID>` to return `200`.
   - do not promote a PID during the 404/pending window.
4) Promote env values:
   - `AO_WRITE_MODULE_PREV=$AO_WRITE_MODULE_CURRENT`
   - `AO_WRITE_PID_PREV=$AO_WRITE_PID_CURRENT`
   - `AO_WRITE_MODULE_CURRENT=<new module tx>`
   - `AO_WRITE_PID_CURRENT=<new PID>`
5) Redeploy gateway/workers with updated env.
6) Smoke test (`diagnose_message.js`, `send_write_command.js`, then domain actions).

## Rollback
1) Set:
   - `AO_WRITE_MODULE_CURRENT=$AO_WRITE_MODULE_PREV`
   - `AO_WRITE_PID_CURRENT=$AO_WRITE_PID_PREV`
2) Redeploy gateway/workers.
3) Keep failed module/PID noted for post-mortem; redeploy fixed pair later.

## Canary tip
- Before full cutover, route only a small set of tenants to the new PID (feature flag/tenant map), verify metrics and write-path behavior, then flip all tenants.

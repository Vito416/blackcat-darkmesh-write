# AO deployment log – blackcat-write

## Snapshot (2026-03-28 - mainnet retry plan)
- Latest mainnet module (dist/ao-write.js build) uploaded as `fwoPBAYio8pUkqgemgVuAsexTucPSGM6tMADdW1rHK0` (supersedes `csOQ_c7ZYLpKwD8MPI6ezgd712ibs7KKhXsasTga-iY` for mainnet pushes).
- Target HB: `https://push.forward.computer/` (mirror `https://push-1.forward.computer/`); Scheduler TX: `n_XZJhUnmldNFo4dhajoPZWhBXuJk-OcQr5JQ49c4Zo`.
- Spawn tags: Variant=`ao.MN.1`, Scheduler=`n_XZ...`, Authority=`scheduler`, Name=`blackcat-write`, Data-Protocol=`ao`, Content-Type=`application/javascript`; signer from `wallet.json` (addr `ZqkuoHZ3GTSCVh96BUgO0wlszuOfzFcerd_zN5W4xTU`).
- Process PID: **record once spawn succeeds** on push.* or a self-hosted HyperBEAM/Scheduler.
- Throughput: public push.* enforces AO gas-based message quotas; keep >=1 AO in the signer and prefer running your own HB+Scheduler to avoid throttling/indexing lag.

## Snapshot (2026-03-24)
- Module uploaded to Arweave: `csOQ_c7ZYLpKwD8MPI6ezgd712ibs7KKhXsasTga-iY`
  - Tags: Type=Module, Data-Protocol=ao, Module-Format=javascript, Input/Output-Encoding=utf-8, Name=blackcat-write-module.
- SDK: `@permaweb/aoconnect` **0.0.94** (built locally from tag `connect@v0.0.94`), `@permaweb/ao-core-libs` 0.0.8.
- Testnet spawns fail at MU validation (HTTP 500) because every Scheduler-Location URL we tried redirects (302) or is unreachable.
- Mainnet spawns fail with connect timeouts to the default HyperBEAM host (`tee-6.forward.computer` and tee-1..10, scheduler.forward.computer).
- AO team (Discord, Jonny Ringo, 24-Mar-2026) confirmed ongoing indexing issues; HyperBEAM is default process type, compute/cache is deterministic, but tx indexing is currently flaky.

## Environment / tooling
- Host: WSL2 (Ubuntu) on BLACK-DELL.
- Wallet: `wallet.json` in repo (RSA JWK, funded), address `ZqkuoHZ3GTSCVh96BUgO0wlszuOfzFcerd_zN5W4xTU`.
- Build: `npm run build:ao` (esbuild) → `dist/ao-write.js`.
- SDK build: cloned tag `connect@v0.0.94`, ran `npm install && npm run build && npm pack`, installed `permaweb-aoconnect-0.0.94.tgz`; `ao-core-libs` 0.0.8.
- Node 20.20.1, npm 10.9.x.

## What we tried (chronology)
### Testnet (ao-testnet)
- Scheduler-Location TX attempts (Variant `ao.TN.1`):
  - `M98VTc06mleYRW-fwT6eX9WQKSITN8GnScFJBGxDqaU` → Url `https://arweave.net` → MU 500 "fetch failed".
  - `8cJ0BgVZT0xm_Bb_SSswtW7UBpHGC5NcWYQNy8H4fVs` → Url `http://hyperbeam.permaweb.black:10000/~hyperbuddy@1.0/index` → MU 500 "Error: 302:".
  - `efeB3tYA0brHNtEfpVZ63ucdnpCf-il7t_VJahUeLvA` → Url `http://hyperbeam.permaweb.black:10000` → MU 500 "Error: 302:".
  - `hZd_aeY8ttqhagku0ogIWhzhTcrO09MtCYO_6EDzcwU` → Url `https://scheduler.ao-testnet.xyz` → DNS/fetch failed.
  - Newly generated (e.g., `l-kyNNxeNEtHAc85suJ89tSR3Pty3zHkAI3ljyQaMNI`) also point to `https://scheduler.ao-testnet.xyz` → unreachable.
- All POSTs to `https://mu.ao-testnet.xyz/` with correct tags (Variant, Type=Process, Module, Scheduler, Scheduler-Location, Data-Protocol=ao, Content-Type) returned 500 because the Scheduler-Location URL could not be validated.

### Mainnet (forward.computer)
- Upgraded aoconnect to 0.0.94, built dist, tried `MODE: 'mainnet'` (default URL `https://tee-6.forward.computer`).
- Result: `UND_ERR_CONNECT_TIMEOUT` to tee-6.forward.computer:443. Tests on tee-1..10.forward.computer and scheduler.forward.computer: DNS resolves, but TCP 443 times out.
- No alternative public HyperBEAM host has been found; curl/ping fail from here.

### Extra diagnostics
- DNS for `tee-6.forward.computer` → `45.63.87.141`; ping 100% loss; curl with 5s timeout hangs (same for tee-1..10, scheduler.forward.computer).
- Curl HEAD sweep across tee-1..10.forward.computer → all connection timeouts.
- Direct DataItem POSTs with `arbundles@0.11.2` to MU: always 500 when scheduler URL redirects or is unreachable.
- Module and scheduler TX tags verified via GraphQL (tags are correct); failures are strictly due to scheduler URL reachability.

## Insights from Discord (Jonny Ringo, 24-Mar-2026)
- HyperBEAM is the default process type in `aos`.
- State in compute/cache is deterministic and considered final; indexing to Arweave/GQL happens after, but indexing is currently degraded.
- The team is working on txs not being indexed; downstream issues (incl. validation) may be related.

## Current blockers
1) No reachable HyperBEAM/Scheduler endpoint: every known URL either redirects (302) or times out.
2) Indexing issues on AO side: even with a reachable host, validation/indexing may be unstable until the team finishes their fix.

## 2026-03-28 – Forward HB public endpoints announced
- Public HB URLs: `https://push.forward.computer/` (mirror `https://push-1.forward.computer/`), scheduler `n_XZJhUnmldNFo4dhajoPZWhBXuJk-OcQr5JQ49c4Zo`; aoconnect 0.0.93 recommended (Jon Ringo, 28-Mar-2026 02:03 UTC).
- Spawn attempts with aoconnect 0.0.93 (wallet.json, module `csOQ_c7ZYLpKwD8MPI6ezgd712ibs7KKhXsasTga-iY`, Variant=ao.MN.1, Scheduler tag) → **HTTP 500** on `/push` (both push.forward.computer and push-1). HyperBEAM error page shows `unsupported_tx_format` at `ar_bundles:deserialize_item/1`, so the bundle is rejected before scheduling.
- `npx aos new --mainnet dist/ao-write.js ...` also fails (“could not parse file”), likely because `aos new` expects a different local source format.

### Repro script (fails with 500 /push)
```js
import fs from 'fs';
import { connect, createDataItemSigner } from '@permaweb/aoconnect';

const wallet = JSON.parse(fs.readFileSync('wallet.json','utf8'));
const moduleTx = 'csOQ_c7ZYLpKwD8MPI6ezgd712ibs7KKhXsasTga-iY';
const HB = 'https://push.forward.computer';
const SCHED = 'n_XZJhUnmldNFo4dhajoPZWhBXuJk-OcQr5JQ49c4Zo';

const ao = connect({ MODE: 'mainnet', URL: HB, SCHEDULER: SCHED });

await ao.spawn({
  module: moduleTx,
  scheduler: SCHED,
  signer: createDataItemSigner(wallet),
  tags: [
    { name: 'Variant', value: 'ao.MN.1' },
    { name: 'Scheduler', value: SCHED },
    { name: 'Name', value: 'blackcat-write' },
    { name: 'Data-Protocol', value: 'ao' },
    { name: 'Content-Type', value: 'application/javascript' },
  ],
});
```
Response: 500 `/push`, HTML body with `unsupported_tx_format` (ar_bundles:deserialize_item/1).

### Likely next steps
- Ask Forward/AO if `/push` expects a different ANS/bundle format or if this is a known bug with aoconnect 0.0.93.
- Workaround: run a local HyperBEAM node and push there until the public `/push` accepts current bundles.
- When spawning, add one or more `Authority` tags (e.g., scheduler/node operator). In `aos`: `--tag-name Authority --tag-value <addr1> --tag-name Authority --tag-value <addr2>`. In JS: `tags: [{ name: "Authority", value: "<addr1>" }, ...]`. At runtime, you can append: `table.insert(ao.authorities, "<addrX>")`.

### 0.0.94 (GitHub tarball) retry
- Installed `@permaweb/aoconnect@0.0.94` from tag tarball; retried spawn with the same module/wallet and Forward HB URL/Scheduler.
- Result: still `Error spawning process` (HTTP 500 on `/push`); behavior identical to 0.0.93, so the rejection is on the HB side, not the SDK patch level.

### Rate limits (from AO Assistant, 2026-03-28 02:29)
- If you see `Error: 500: {"error":"Error: Rate limit exceeded"}`, it means the signer address needs AO balance.
- Messaging limits based on AO balance: 0.1 AO → 1 msg/hour; 1 AO → 10 msg/hour; 2 AO → 20 msg/hour; 10 AO → 100 msg/hour.
- Typical dev/app processes: 200 msgs/hour + 10 msgs per AO held in the signer wallet.
- To obtain AO: stake AR or other assets (see https://ao.arweave.net/#/mint/deposits/) or buy on a CEX (no guidance provided).

## What we need to proceed
- Confirm whether `push.forward.computer` accepts the new module bundle (`fwoPBAYio8pUkqgemgVuAsexTucPSGM6tMADdW1rHK0`) with Scheduler/Authority tag; if 500 persists, spawn on a self-hosted HyperBEAM/Scheduler instead.
- Capture the returned PID once spawn succeeds (public or self-hosted) and record it in the snapshot above.
- After a PID exists, run Eval + one domain action to verify handlers; log outputs and any rate-limit messages.
- Keep the signer funded (>=1 AO recommended) to stay above AO gas quotas during messaging.

## Mainnet spawn recipe (push.forward.computer)
```js
import fs from 'fs';
import { connect, createDataItemSigner } from '@permaweb/aoconnect';

const signer = createDataItemSigner(JSON.parse(fs.readFileSync('wallet.json','utf8')));
const moduleTx = 'fwoPBAYio8pUkqgemgVuAsexTucPSGM6tMADdW1rHK0';
const scheduler = 'n_XZJhUnmldNFo4dhajoPZWhBXuJk-OcQr5JQ49c4Zo';

const ao = connect({ MODE: 'mainnet', URL: 'https://push.forward.computer', SCHEDULER: scheduler });

const pid = await ao.spawn({
  module: moduleTx,
  scheduler,
  signer,
  tags: [
    { name: 'Variant', value: 'ao.MN.1' },
    { name: 'Authority', value: scheduler },
    { name: 'Scheduler', value: scheduler },
    { name: 'Name', value: 'blackcat-write' },
    { name: 'Data-Protocol', value: 'ao' },
    { name: 'Content-Type', value: 'application/javascript' },
  ],
});

console.log('Process PID (record in snapshot):', pid);
```
- Swap `URL` to your own HyperBEAM/Scheduler node to bypass public rate limits and to control indexing. Keep `{ Authority: scheduler }` when targeting Forward’s scheduler.

## Messaging with aoconnect (Eval + domain action)
```js
const { message, result } = ao;

// Eval smoke
const evalMsg = await message({
  process: pid,
  signer,
  tags: [{ name: 'Action', value: 'Eval' }],
  data: 'return "pong"',
});
const evalOut = await result({ process: pid, message: evalMsg });

// Domain action example
const saveDraft = await message({
  process: pid,
  signer,
  tags: [
    { name: 'Action', value: 'SaveDraftPage' },
    { name: 'Request-Id', value: '<uuid>' },
    { name: 'Actor', value: '<actor>' },
    { name: 'Tenant', value: '<tenant>' },
    { name: 'Timestamp', value: String(Date.now()) },
  ],
  data: JSON.stringify({ /* payload */ }),
});
const saveDraftOut = await result({ process: pid, message: saveDraft });
```
- Messaging incurs AO gas quotas on public push.*; if responses stall or rate limit errors appear, fund the signer or point `ao.URL` to your own node.

## Action items
1) Spawn `fwoPBAYio8pUkqgemgVuAsexTucPSGM6tMADdW1rHK0` on push.forward.computer (or self-hosted HB) with Scheduler/Authority `n_XZJhUnmldNFo4dhajoPZWhBXuJk-OcQr5JQ49c4Zo`; log the returned PID above.
2) Run Eval + one `SaveDraftPage` message using the messaging recipe; capture outputs and any rate-limit errors.
3) If `/push` continues returning 500/`unsupported_tx_format`, stand up a local HB+Scheduler and retry spawn/messaging there.
4) Keep `wallet.json` funded (>=1 AO) to stay above the lowest gas tier.

## Housekeeping
- Sources kept: `/home/jaine/ao-connect-094` (local build, ~30 MB) in case we need to rebuild.
- Installed: `@permaweb/aoconnect` 0.0.94 (from tag build), `ao-core-libs` 0.0.8.
- Unsuccessful Scheduler-Location TXs remain on Arweave; harmless but not usable for validation.

## Next step
- Run the mainnet spawn recipe (push.* or self-hosted HB) and capture the returned PID in the snapshot at the top.
- Send Eval + `SaveDraftPage` messages, record outputs and any rate-limit errors; if push.* keeps rejecting bundles, fall back to self-hosted HB/Scheduler and document its URL/tag here.

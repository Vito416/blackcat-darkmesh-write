# AO deployment log – blackcat-write

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

## What we need to proceed
- A working HyperBEAM/Scheduler URL that returns HTTP 200 (no redirect) and is reachable from MU/HyperBEAM:
  - Testnet: Variant `ao.TN.1`, Scheduler-Location TX with such `Url`.
  - Mainnet: Variant `ao.MN.1`, or direct HyperBEAM URL to use as `URL` in `connect`.

## Ready-to-run spawn once a good endpoint is known
```js
import { connect } from '@permaweb/aoconnect';
import fs from 'fs';

const wallet = JSON.parse(fs.readFileSync('/mnt/c/Users/jaine/Desktop/BLACKCAT_MESH_NEXUS/blackcat-darkmesh-write/wallet.json','utf8'));
const moduleId = 'csOQ_c7ZYLpKwD8MPI6ezgd712ibs7KKhXsasTga-iY';

const HB_URL = '<working-hyperbeam-url-here>';       // e.g. https://<host>
const SCHED_LOC = '<scheduler-location-txid-if-needed>'; // optional

const tags = [
  { name:'Variant', value:'ao.TN.1' },        // ao.MN.1 for mainnet
  { name:'Type', value:'Process' },
  { name:'Module', value: moduleId },
  { name:'Scheduler', value:'ZqkuoHZ3GTSCVh96BUgO0wlszuOfzFcerd_zN5W4xTU' },
  { name:'Scheduler-Location', value: SCHED_LOC },
  { name:'App-Name', value:'ao' },
  { name:'App-Version', value:'0.0.1' },
  { name:'Name', value:'blackcat-write' },
  { name:'Data-Protocol', value:'ao' },
  { name:'Content-Type', value:'application/javascript' }
];

const { spawn } = connect({ MODE:'testnet', URL: HB_URL }); // MODE:'mainnet' for mainnet
const pid = await spawn({ module: moduleId, wallet, tags });
console.log('Process ID', pid);
```

## Action items
1) Obtain a reachable HyperBEAM URL (HTTP 200, no redirect) from AO/Forward (testnet or mainnet).
2) If provided as Scheduler-Location TXID (Variant `ao.TN.1` or `ao.MN.1`), set `SCHED_LOC`; otherwise set `URL` in `connect`.
3) Re-run the spawn script; read state from compute/cache while GQL indexing is being fixed.
4) Keep SDK at 0.0.94 until a newer release appears.
5) Optional cleanup: `/home/jaine/ao-connect-094` (~30 MB) can be deleted, kept for rebuild convenience.

## Housekeeping
- Sources kept: `/home/jaine/ao-connect-094` (local build, ~30 MB) in case we need to rebuild.
- Installed: `@permaweb/aoconnect` 0.0.94 (from tag build), `ao-core-libs` 0.0.8.
- Unsuccessful Scheduler-Location TXs remain on Arweave; harmless but not usable for validation.

## Next step
- Get a confirmed reachable HyperBEAM host or Scheduler-Location TXID from AO/Forward.
- Re-run the spawn script above with that URL/TXID; monitor compute/cache for results while indexing is being fixed.

# AO deployment log – blackcat-write

## Snapshot (2026-04-04) — v1.2.0 hardening before next mainnet spawn
- Process defaults: `ENABLE_EVAL=0`, `WRITE_TEST_MODE=0`, `WRITE_AUTH_TOKEN` required for Ping/GetHealth/SaveDraft/Eval. `WRITE_MAX_PAYLOAD_BYTES` enforced even without cjson (rough size fallback). Outbox HMAC now signs the entire envelope and fails closed if the secret is missing.
- Worker `/sign`: requires dedicated `WORKER_SIGN_TOKEN` (fallback to WORKER_AUTH_TOKEN), per-IP rate-limit, payload cap (`SIGN_MAX_BYTES`), nonce+timestamp replay guard (`SIGN_TS_WINDOW`, stored in KV), and schema allowlist. Startup guardrails reject prod if secrets are disabled or memory KV is used.
- Tokens separated: keep `WORKER_AUTH_TOKEN` for notify/forget; plan to use distinct `WORKER_SIGN_TOKEN`. Secrets must be present when `REQUIRE_SECRETS=1` (prod default).
- Supply chain: `@permaweb/ao` pinned to commit `8e23f3486bf28720d98de9d0b4ff650dbdb2077e` (no mutable tag). Added root `.gitignore`; removed stray vendor tarball (`tmp/vendor/permaweb-ao-core-libs-0.0.8.tgz`). CLI helpers now refuse silent defaults unless `--allow-defaults` and block reading files outside repo for Eval.

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

## Current mainnet module + PID (2026-04-04)
- Module TX: `F47cEULJhjxolLnvRYO2zGK4cMGToydkxVmA7R7Qe_c`
  - Variant `ao.TN.1`, signing-format `ans104`, accept-bundle `true`, accept-codec `httpsig@1.0`, Data-Protocol `ao`, Content-Type `application/wasm`, Module-Format `wasm64-unknown-emscripten-draft_2024_02_15`, Input/Output-Encoding `JSON-1`, Memory-Limit `1-gb`, Compute-Limit `9000000000000`, Name `blackcat-write`, AOS-Version `2.0.6`.
- Process PID: `26hrLuQBsVFcsqHMLhP1LjifRh8WYMerYyd71A2ofjo`
  - Tags include device `process@1.0`, scheduler-device `scheduler@1.0`, push-device `push@1.0`, execution-device `genesis-wasm@1.0`, Authority/Scheduler `n_XZJhUnmldNFo4dhajoPZWhBXuJk-OcQr5JQ49c4Zo`, Module `F47cEUL…7R7Qe_c`, Name `blackcat-write`, signing-format `ans104`, accept-bundle `true`, accept-codec `httpsig@1.0`, Variant `ao.TN.1`, Data-Protocol `ao`, Type `Process`.

## 2026-04-04 — v1.2.0 readiness (pre-release)
- New handlers in process (local build):
  - Ping: returns JSON `status=OK`, pong, requestId, ts.
  - GetHealth: returns version, uptime, drafts count, outbox depth, ts.
  - SaveDraftPage: stores payload in `state.drafts`, returns `{status:OK,id}`.
  - Eval: gated by `ENABLE_EVAL=1`; otherwise returns `{status:DISABLED}`.
- CLI presets (send-msg.js):
  - savedraft (exists), notify (Event/Tenant/Actor/Timestamp, default payload), writecmd (Write-Command tags + demo payload; accepts signature/refs).
- Live smoke on push-1 (PID `26hrLuQ...`):
  - Ping → 200, body `1984` (current deployed module still old handlers).
  - Eval → 200 (returns `1984` because old module; new build has gating).
  - SaveDraft preset → 200 (`1984` because old module); new build will return OK/id.
- Worker `/sign` with test secrets returns signature OK (no sha512Sync error).
- Messaging shape confirmed: POST `/PID` with `Content-Type: application/json` and `codec-device: httpsig@1.0`; no `/message`, no ANS-104 bundling needed.
- Next steps to cut v1.2.0:
  1) Build WASM from updated process (Ping/GetHealth/SaveDraft/Eval gate) → publish new module TX with standard tags.
  2) Spawn new PID on push-1 (authority/scheduler = `n_XZ...`), record PID here.
  3) Smoke tests on new PID: Ping, GetHealth, SaveDraft preset, Eval (with `ENABLE_EVAL=1` set at spawn/env), notify & writecmd presets.
  4) Keep worker secrets as in `tmp/test-secrets.json`; ensure worker `/health` (optional) returns 200 for ops checks.

## Working Ping shape (verified locally, release HB)
- Endpoint: `http://localhost:8734/<PID>` (POST directly to PID, not `/message`).
- Headers: `Content-Type: application/json`, `codec-device: httpsig@1.0`.
- Body:
```json
{
  "tags": [
    {"name":"Action","value":"Ping"},
    {"name":"Content-Type","value":"application/json"},
    {"name":"Data-Protocol","value":"ao"},
    {"name":"Type","value":"Message"},
    {"name":"Variant","value":"ao.TN.1"}
  ],
  "data": ""
}
```
- Response: `200 OK`, body `1984`; HB response headers show `accept-codec=httpsig@1.0`, `signing-format=ans104`.
- Key finding: push expects structured/HTTPSIG JSON at `/PID`; the aoconnect mainnet path that wrapped ANS104 and ended up as `[object Object]` caused 400/500. For mainnet use the same shape (URL `https://push-1.forward.computer/<PID>`) with HTTPSIG.

### Praktické příklady (mainnet push-1)
- curl Ping:
```
curl -X POST https://push-1.forward.computer/26hrLuQBsVFcsqHMLhP1LjifRh8WYMerYyd71A2ofjo \
  -H "Content-Type: application/json" \
  -H "codec-device: httpsig@1.0" \
  -d '{
        "tags": [
          {"name":"Action","value":"Ping"},
          {"name":"Content-Type","value":"application/json"},
          {"name":"Data-Protocol","value":"ao"},
          {"name":"Type","value":"Message"},
          {"name":"Variant","value":"ao.TN.1"}
        ],
        "data":""
      }'
```
- Node helper (repo): `node send-ping-push1.js`
- Generic sender: `node send-msg.js --pid <PID> --action Ping --data "" --url https://push-1.forward.computer --variant ao.TN.1 --type Message --content-type application/json`
- Eval helper: `node send-eval.js --pid <PID> --code "return 'pong'"` (or `--file code.lua`), sends Action=Eval to `/PID` with HTTPSIG JSON.
- SaveDraft preset (example): `node send-msg.js --preset savedraft --pid <PID> --url https://push-1.forward.computer`
  - Defaults: Action=SaveDraftPage, Request-Id=req-demo-uuid, Actor=demo-actor, Tenant=demo-tenant, Timestamp=now, Content-Type=application/json, Variant=ao.TN.1. Override via `--request-id`, `--actor`, `--tenant`, `--timestamp`, `--data`.
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

### WASM module path (no Eval/chunking)
- Build module to `application/wasm` with target `wasm64-unknown-emscripten-draft_2024_02_15`, JSON I/O.
- Upload module TX with tags:
  - Content-Type: application/wasm
  - Module-Format: wasm64-unknown-emscripten-draft_2024_02_15
  - AOS-Version: 2.0.6 (or matching build)
  - Name: <module-name>
  - Type: Module
  - Variant: ao.TN.1
  - Data-Protocol: ao
  - Input-Encoding: JSON-1
  - Output-Encoding: JSON-1
- (optional) Memory-Limit: 1-gb; Compute-Limit: 9000000000000
- Spawn process with `module: <module_txid>`, Scheduler, Authority tags. No Eval needed; CU/HB loads module by TXID.
- Hyperengine smoke test before upload: clone/build `hyperengine`, then run `hyperengine smoke main` (or module name) on the built wasm; expect “Smoke OK”.
- Alternative toolchains: `wao` (ArweaveOasis, Rust→WASM) can build AO modules with correct tags; not yet tested here.

### Lua path tags (when using spawn+eval/chunking)
- Content-Type: text/lua
- Data-Protocol: ao
- Variant: ao.MN.1
- Authority tags at spawn

## 2026-04-03 — WASM pipeline (no Eval/chunking)
- Built write process with hyperengine → `dist/write/process.wasm` (JSON I/O, target `wasm64-unknown-emscripten-draft_2024_02_15`).
- Published to Arweave via `ao publish` (wallet.json) → **module txid `CkCoqC2-lGgLOsQJZgeaA1-MYqW3kBkRcrRdNSa4wwM`**.
- Tags used (all required for HB/CU to load):
  - Content-Type=application/wasm

## 2026-04-04 — Known good (no ping yet)
- Module txid `x1DLlk1xbIJ1vQQoukISJP4kshYqvpdVH_FhBQVzEi0` was **stable** (no runtime errors) but **did not include the Ping handler** at that time.

## 2026-04-04 — Worker signing fixed + current blocker
- Worker `/sign` endpoint now succeeds (multiple OK POSTs logged on prod).
- Root cause of 500 was **noble/ed25519 missing SHA‑512 hook** (`hashes.sha512Sync not set`).
  - Fix: wire `@noble/hashes/sha512` and set `ed25519.etc.sha512Sync = sha512` in worker.
  - Deploy: `blackcat-darkmesh-ao/worker` → `npm install` + `npx wrangler deploy -e production`.
- Test secrets are stored locally at: `blackcat-darkmesh-write/tmp/test-secrets.json` (do **not** commit).
  - Used to provide `WORKER_AUTH_TOKEN` (and other HMAC secrets) for local curl testing.
- `/sign` test (local): curl with Authorization header now returns `{ signature, signatureRef }`.
- **Current blocker:** AO `ao.message` fails with `Error sending message` on both:
  - `https://push-1.forward.computer`
  - `https://push.forward.computer`
  - This happens even with valid worker signature and known-good PID.
  - Next step if persists: spawn a fresh PID on push‑1 and test immediately.

## 2026-04-04 — Finalization/indexing wait is required
- New process TXs on push‑1 can show **Pending** for minutes; messages sent before finalization can return **bad/invalid responses**.
- Example: PID `OrNQTP_ZErK4fHai7qGHB7bJQsc8Db5Y7GcNQrtmg0I` was Pending on Arweave shortly after spawn.
- **Rule:** wait for the process TX to finalize/index (Pending → Success) before sending first messages, otherwise HB may reject with `ao-types` / cache errors.
- **Timing:** Recent mainnet spawns take **30+ minutes** to fully finalize/index. Plan tests accordingly; sending earlier produces false positives.
- **Check finalization here:** use Viewblock (e.g. `https://viewblock.io/arweave/tx/DHRy_YjzUY8f_1bBRi1-hCRdrbuKFLFmdc5e7ZA-3y4`) to verify Status=Success before messaging.
- **Observed sequence:** first 5–10 minutes after publish the endpoint can return 404; then ~30 minutes of finalization follow. Failures in this window are almost always due to incomplete finalization or our code, not push/push-1.
- **WSL quick check:**  
  ```bash
  TX=<txid>
  curl -s https://arweave.net/tx/$TX/status | jq
  ```  
  - Contains `block_height` ⇒ confirmed/finalized.  
  - 202/404 or no `block_height` ⇒ not ready; wait longer before messaging.

## 2026-04-04 — ~relay@1.0 HTTP from inside AO (post‑finalize idea)
- You can trigger HTTP requests inside AO using `~relay@1.0` (async) with a handler like:
  - `Send({ target = ao.id, ['relay-path'] = URL, resolve = '~relay@1.0/call/~patch@1.0' })`
  - Handle `GET-Result` / `GET-Failed` via `ao.isTrusted` checks.
- **Known limitation:** response body is currently placed into tags and **~4 KB cap** applies (buggy).
- **Usefulness:** good for small GETs without external worker; **does not** fix pre‑finalize message failures.
  - Module-Format=wasm64-unknown-emscripten-draft_2024_02_15

## 2026-04-04 — Local HyperBEAM (edge-ephemeral) ans104 diagnostics
- Env: `docker compose up` from `hyperbeam-docker` → HB listening on `http://localhost:8734`. Router has only `/_`; add `/?x=1` to POSTs to bypass the UI redirect. `/push` is **not** exposed.
- Headers that decode correctly: `Content-Type: application/ans104`, `codec-device: ans104@1.0`, `accept-bundle: true` (optionally `accept-codec: httpsig@1.0`). Signature decoding now succeeds; no more `decode_signature` errors.
- Persistent 500: `Attempted to resolve an empty message sequence.` HB logs show `hb_ao:resolve_many([])` because `hb_util:message_to_ordered_list` only collects numerically‑indexed keys (1,2,…) from the TABM produced by `ar_bundles:deserialize`. Our ans104 TABM currently contains **no numeric keys**, so the sequence is empty.
- Structured@1.0 (application/json + `codec-device: structured@1.0`) also fails: `{badmap,<<"[{\\"target\\":...}]">>}` because the body stays a binary string, not a numbered map.
- Tried variants (all still empty sequence): tags for Target/Action, `ao-data-key`, JSON list in data, tag `"1"` with JSON payload, data map with key `"1"`.
- Hypothesis: only an **ans104 bundle** (count-prefixed) will yield numbered keys (1..n) after `ar_bundles:unbundle`, satisfying `message_to_ordered_list`. Not tested yet.
- Next experiments (keep Docker HB running):
  1. Build a single‑item ans104 bundle with `arbundles` (`Bundle.bundleAndSignData` or `new Bundle([dataItem])`), send binary to `http://localhost:8734/?x=1` with the headers above. Expect non‑empty message sequence.
  2. If bundle still empties, send the same message using HTTPSIG (application/json + `codec-device: httpsig@1.0`, signed with the same JWK). HTTPSIG should produce numbered keys automatically; use it as a messaging fallback while keeping ans104 for module uploads.
  3. Debug TABM locally: `const di = new DataItem(raw); console.log(di.tags, di.getData().toString('hex'))` to confirm what keys exist pre‑HB.

## ans104 vs HTTPSIG (why we still care)
- **ans104 (Arweave DataItem)**: on‑chain compatible payload, hash‑addressed, can be bundled, survives offline, canonical signing; required for module uploads and useful when we need auditable, replayable messages.
- **HTTPSIG**: lighter HTTP request signature, great for live messaging, auto‑numbers keys for HB, but not an Arweave artifact and not durable by itself.
- Strategy: keep ans104 for modules; use ans104 bundle (if we can populate numbered keys) or fall back to HTTPSIG for live messages to avoid the empty‑sequence issue.
  - Variant=ao.TN.1
  - Data-Protocol=ao
  - Input-Encoding=JSON-1, Output-Encoding=JSON-1
  - Memory-Limit=1-gb, Compute-Limit=9000000000000
  - AOS-Version=2.0.6
  - Type=Module, Name=blackcat-write
- Spawn recipe (mainnet push / push-1):
```bash
node - <<'JS'
import fs from 'fs';
import { connect, createDataItemSigner } from '@permaweb/aoconnect';

const wallet = JSON.parse(fs.readFileSync('wallet.json','utf8'));
const signer = createDataItemSigner(wallet);
const scheduler = 'n_XZJhUnmldNFo4dhajoPZWhBXuJk-OcQr5JQ49c4Zo';
const moduleTx = 'CkCoqC2-lGgLOsQJZgeaA1-MYqW3kBkRcrRdNSa4wwM';

const ao = connect({ MODE:'mainnet', URL:'https://push-1.forward.computer', SCHEDULER:scheduler });

const pid = await ao.spawn({
  module: moduleTx,
  scheduler,
  signer,
  tags: [
    { name:'Variant', value:'ao.MN.1' },
    { name:'Authority', value:scheduler },
    { name:'Scheduler', value:scheduler },
    { name:'Name', value:'blackcat-write' },
    { name:'Data-Protocol', value:'ao' },
    { name:'Content-Type', value:'application/wasm' },
  ],
});

console.log('PID', pid);
JS
```
- **Working minimal spawn (verified 2026-04-04):** use `createSigner` + `authority` param and *minimal tags*. Extra tags + `createDataItemSigner` failed on push-1.
```js
import { connect, createSigner } from '@permaweb/aoconnect';
import fs from 'fs';

const HYPERBEAM_URL = 'https://push-1.forward.computer';
const HYPERBEAM_SCHEDULER = 'n_XZJhUnmldNFo4dhajoPZWhBXuJk-OcQr5JQ49c4Zo';
const WASM_MODULE = 'W80c8K0ReyPgTZ_A1hBABCEIzLhnBh020rOIMAtzJY4';

const jwk = JSON.parse(fs.readFileSync('wallet.json', 'utf-8'));
const ao = connect({
  MODE: 'mainnet',
  URL: HYPERBEAM_URL,
  SCHEDULER: HYPERBEAM_SCHEDULER,
  signer: createSigner(jwk),
});

const processId = await ao.spawn({
  module: WASM_MODULE,
  scheduler: HYPERBEAM_SCHEDULER,
  authority: HYPERBEAM_SCHEDULER,
  tags: [{ name: 'Example-Tag', value: 'Example Value' }],
  data: '1984',
});
```
- **Spawn success (push-1, 2026-04-04):** PID `QFCAzUYXtgZI29S4NFD9T-p-cj21rmvCa5DINux-2XE`.
- Smoke tests on PID `QFCAzUYXtgZI29S4NFD9T-p-cj21rmvCa5DINux-2XE`: `Ping`, `GetOpsHealth`, `GetLocaleRoute`, `CartGet`, `SubmitForm` all returned OK (GasUsed 0).
- **WASM w/ Write-Command handler (2026-04-04):** module tx `s8H4M-S6qz7YKRq-p-VZ_UK3dsjg62M2o5OBv72I2ss` (Variant `ao.MN.1`), spawned PID `RzyBZpp0JKyPT1JVASqb5_L4cbx_b7xjeBuSyz1Whw8`.
- **WASM re-spawn after tx finalization (2026-04-04):** PID `ElLSNp3b_d3FCStytXnpPZyxGDvHBAg8RVffokuiT3U` on push-1.
- Worker signing endpoint added: `POST /sign` (requires `WORKER_AUTH_TOKEN` and `WORKER_ED25519_PRIV_HEX`).
- Local test flow: `WORKER_SIGN_URL=https://blackcat-inbox-production.vitek-pasek.workers.dev/sign` + `WORKER_AUTH_TOKEN` then run `node scripts/cli/send_write_command.js` to send a signed `Write-Command` to AO.
- Worker-style signed command sender added: `scripts/cli/send_write_command.js` (uses Ed25519 private key from `tmp/worker-ed25519-priv.pem` and validates in AO via `WRITE_SIG_PUBLIC`).
- Expectation: no Eval needed; CU loads the module by txid. Use public HB quota (suggest ≥1 AO balance) or your own HB for stability.

### Live process tests (3 Apr)
- Test PID on push-1: `yXiLzv9BZjAXFwLpOJCeQLWwcZRhwhPP4gPrnzeQBog` (module `fssz3nLeORY_dBTYEHdpcgysSxCbVfaM9_TqpbCszww`, previous build).
- Actions validated (messages + results OK, GasUsed 0): `Ping`, `GetOpsHealth`, `GetLocaleRoute`, `CartGet`, `SubmitForm`.
- Secondary test PID: `eHNB8fzlfcn3BbKYHekTn-gQ_NgKOV-Gdv_LhSQPlP8` (used for repeated smoke tests).
- Rate limits: public push-* allows roughly 10 msgs / 5 minutes with empty AO balance; keep AO funded for higher quotas (see limits table above).

### Test secrets (gitignored)
- Stored at `tmp/test-secrets.json` (generated locally, not committed). Use only for QA; regenerate for prod.
- For Cloudflare worker integration tests, see `blackcat-darkmesh-ao/worker` notes below.

### HTTP via `~relay@1.0` (async)

You can call HTTP endpoints directly from the process using the HyperBEAM relay device. Key rules:
- Target must be `~relay@1.0` (not `ao.id`).
- Add a `Request-ID` tag so you can match responses.
- Set `Action='HttpRequest'` and `Method` (e.g., GET/POST).
- Gate responses with `ao.isTrusted(msg)` and the `Request-ID`.

Example (Lua):

```lua
Handlers.add('GET', 'GET', function (msg)
  local url = msg.Tags['URL']
  assert(type(url) == 'string' and #url > 0, 'URL tag is required')
  local reqId = tostring(ao.id) .. '-' .. tostring(msg.Id or ao.now)
  Send({
    Target = '~relay@1.0',
    Tags = {
      Action = 'HttpRequest',
      Method = 'GET',
      ['Request-ID'] = reqId,
      Url = url,
    },
    Data = ''
  })
end)

Handlers.add('GET-Result', function (msg)
  return ao.isTrusted(msg)
    and msg.Tags['Request-ID'] ~= nil
    and msg.Tags['Status'] == '200'
end, function (msg)
  print('GET success id=' .. msg.Tags['Request-ID'] .. ' status=' .. msg.Tags['Status'])
  print('Body:', msg.Body or '')
end)

Handlers.add('GET-Failed', function (msg)
  return ao.isTrusted(msg)
    and msg.Tags['Request-ID'] ~= nil
    and msg.Tags['Status'] ~= '200'
end, function (msg)
  print('GET failed id=' .. msg.Tags['Request-ID'] .. ' status=' .. (msg.Tags['Status'] or 'unknown'))
  print('Body:', msg.Body or '')
end)
```

## Housekeeping
- Sources kept: `/home/jaine/ao-connect-094` (local build, ~30 MB) in case we need to rebuild.
- Installed: `@permaweb/aoconnect` 0.0.94 (from tag build), `ao-core-libs` 0.0.8.
- Unsuccessful Scheduler-Location TXs remain on Arweave; harmless but not usable for validation.

## Next step
- Run the mainnet spawn recipe (push.* or self-hosted HB) and capture the returned PID in the snapshot at the top.
- Send Eval + `SaveDraftPage` messages, record outputs and any rate-limit errors; if push.* keeps rejecting bundles, fall back to self-hosted HB/Scheduler and document its URL/tag here.

## Diagnostics (2026-04-04)
- Module (WASM) **F47cEULJhjxolLnvRYO2zGK4cMGToydkxVmA7R7Qe_c** is **Success**, Variant **ao.TN.1**, tags OK (Content-Type application/wasm, Module-Format wasm64-unknown-emscripten-draft_2024_02_15, Data-Protocol ao, Input/Output JSON-1, Memory-Limit 1-gb, Compute-Limit 9000000000000, AOS-Version 2.0.6, signing-format ans104, accept-bundle/accept-codec set, Name=blackcat-write).
- PID from this module on push-1: **26hrLuQBsVFcsqHMLhP1LjifRh8WYMerYyd71A2ofjo** (Authority/Scheduler `n_XZJhUnmldNFo4dhajoPZWhBXuJk-OcQr5JQ49c4Zo`, Variant TN). Finalized.
- All message attempts (aoconnect + raw ANS-104) to `/<PID>~process@1.0/push` return **400 “Message is not valid.”**. Endpoint `/message` returns 404 on push-1.
- Response headers sometimes include `ao-types: status="integer"` when payload lacks `status`; adding `status:0` (in JSON + tag) still 400, so ao-types schema expects more fields than we supply.
- Patched `@permaweb/aoconnect` to default Variant=ao.TN.1; no `legacy` mode left; spawn works.
- Raw tests tried: minimal ping, status field, Owner/Nonce/Timestamp/Content-Length/SDK tags — all 400.
- Hypothesis: ao-types schema for Message requires a specific structure (field types) we have not matched. Need to read schema from `@permaweb/ao-core-libs` / `ao` source to craft compliant payload.

### Next actions (blocking)
- Extract ao-types Message schema from `@permaweb/ao-core-libs` / `@permaweb/ao` (look for type definitions in source, not minified dist).
- Once schema is known, craft payload exactly per requirements and resend via aoconnect `message()` to PID 26hrLuQ… on push-1.
- If schema cannot be derived quickly, try with Owner+Process+Status integer and simplest body matching schema (as discovered) before moving back to self-hosted HB.

## WASM deploy snapshot (2026-04-03)
- Built via `ao-dev` (dev-cli 0.1.7, Docker, deno 1.41) after `hyperengine build` → `dist/write/process.wasm` (wasm64).
- Published TX (mainnet): **KoZU6dV1-C076ZddCw9N-W0vyrmJLt_Esv1XDX4wtOM**  
  Tags: Content-Type=application/wasm; Module-Format=wasm64-unknown-emscripten-draft_2024_02_15; Variant=ao.TN.1; Data-Protocol=ao; Input/Output-Encoding=JSON-1; Memory-Limit=1-gb; Compute-Limit=9000000000000; Name=blackcat-write; Type=Module; AOS-Version=2.0.6.
- Spawn success on push-1.forward.computer → **PID yoej26bhzk9moP4nT48wQ5Wm9n4S3xaJwF_MUKlGmAs**  
  - signer: `createSigner(jwk)`  
  - fields: module=KoZU6…, scheduler=`n_XZJhUnmldNFo4dhajoPZWhBXuJk-OcQr5JQ49c4Zo`, authority=scheduler  
  - tags: Variant=ao.TN.1, Name=blackcat-write (Content-Type already on module)  
  - URLs: URL/MU/CU all `https://push-1.forward.computer`
- Gotchas fixed:
  - Use `createSigner`, not `createDataItemSigner`, for spawn.
  - Pass `authority` as a field, not just a tag.
  - Minimal spawn tags are enough; module metadata lives on the TX.
  - Public HB returns 500 if AO gas is missing or params are wrong.
  - Docker required for `ao-dev build`.
- Module reachable: https://arweave.net/KoZU6dV1-C076ZddCw9N-W0vyrmJLt_Esv1XDX4wtOM

### Spawn + message script (working reference)
```js
import { connect, createSigner } from '@permaweb/aoconnect';
import fs from 'fs';

const jwk = JSON.parse(fs.readFileSync('wallet.json','utf8'));
const scheduler = 'n_XZJhUnmldNFo4dhajoPZWhBXuJk-OcQr5JQ49c4Zo';
const moduleId = 'KoZU6dV1-C076ZddCw9N-W0vyrmJLt_Esv1XDX4wtOM';
const URL = 'https://push-1.forward.computer';

const ao = connect({
  MODE: 'mainnet',
  URL,
  MU_URL: URL,
  CU_URL: URL,
  SCHEDULER: scheduler,
  signer: createSigner(jwk),
});

const pid = await ao.spawn({
  module: moduleId,
  scheduler,
  authority: scheduler,
  tags: [
    { name: 'Variant', value: 'ao.TN.1' },
    { name: 'Name', value: 'blackcat-write' },
  ],
  data: 'init',
});
console.log('PID', pid);

const msgId = await ao.message({
  process: pid,
  tags: [{ name: 'Action', value: 'Eval' }],
  data: 'return \"pong\"',
});
const res = await ao.result({ process: pid, message: msgId });
console.log(res);
```

### Rate limits (public push.*)
- 0.1 AO = 1 msg/hour; 1 AO = 10 msg/hour; 2 AO = 20 msg/hour; 10 AO = 100 msg/hour.
- Typical dev/app processes: 200 msgs/hour + 10 msgs per AO held.
- If you hit `Rate limit exceeded`, add AO or use your own HB/Scheduler.

### Why WASM (vs. Eval/chunking)
- Module loads directly by TXID; žádné chunk uploady, žádný Eval limit.
- Payload/size limity u zpráv odpadají, kód je celý v modulu.

### Useful repos / references
- ao dev-cli (builder, install scripts): https://github.com/permaweb/ao/tree/main/dev-cli
- hyperengine (bundling + smoke): https://github.com/memetic-block/hyperengine
- wao (Rust→WASM AO modules, optional): https://github.com/ArweaveOasis/wao

### Next actions for WASM path
- Send Eval/handler message to PID yoej26b… and record outputs.
- Keep signer funded with AO to avoid push.* rate limits.
- Record any future module/PID replacements here.

## 2026-04-04 — Local HB diagnostics (hyperbeam-edge-ephemeral)
- Local HyperBEAM (docker compose `hyperbeam-edge-ephemeral`) runs at `http://localhost:8734`, operator/scheduler `ZqkuoHZ3GTSCVh96BUgO0wlszuOfzFcerd_zN5W4xTU`. `~meta@1.0/info` and `~scheduler@1.0/info` return JSON.
- TN module `F47cEULJhjxolLnvRYO2zGK4cMGToydkxVmA7R7Qe_c` is reachable; HB pulls ~938 KB from Arweave on start.
- aoconnect spawn attempts to local HB (URL/MU_URL/CU_URL=http://localhost:8734, Variant ao.TN.1, Content-Type application/wasm) hang client-side and never hit HB logs → likely blocked in aoconnect fetch layer (HTTPS-only expectation or other pre-flight). Same with https://localhost and TLS disabled.
- Next step: bypass aoconnect and POST a signed ANS-104 data item directly to HB (`/process`/`/message`) while tailing `docker compose logs -f hyperbeam-edge-ephemeral` to capture the exact validation error that yields 400 on push-1. Once a working request shape is confirmed locally, mirror it in `scripts/send_write_command` and retest on push-1.
- Reminder: every module/process tx must fully finalize before judging errors. Expect ~5–10 min of 404, then ~30+ min pending→success. Use Viewblock (e.g., https://viewblock.io/arweave/tx/DHRy_YjzUY8f_1bBRi1-hCRdrbuKFLFmdc5e7ZA-3y4) to confirm Status=Success before messaging.

## 2026-04-04 — Local HB ans104 POST diagnostics
- HyperBEAM (hyperbeam-edge-ephemeral) router: jediná cesta `/_` → AO pipeline, `/push` neexistuje. Root `/` bez body dává 302 na UI, jakýkoli POST (mimo preflight) jde do `hb_http:req_to_tabm_singleton`.
- Přímý DataItem (Type=Process, žádné AO tagy) jako `application/octet-stream` na `/` → **200 OK** (vrací HyperBEAM UI), tj. request není zpracován jako AO msg, ale nezpůsobí chybu.
- DataItem s plnými AO tagy (Type=Process, Data-Protocol=ao, Variant=ao.TN.1, Module=F47cEUL…, Scheduler/Authority=ZqkuoH…) + `Content-Type: application/ans104`, `codec-device: ans104@1.0`, `accept-bundle: true` → **500**; HB log: `binary:part/[<<>>,0,2] -> ar_bundles:decode_signature -> deserialize_item -> req_to_tabm_singleton`, tj. parser vidí prázdnou signature.
- Stejný DataItem s AO tagy, ale hlavička pouze `application/octet-stream` (bez codec-device) → **200 OK** (UI), žádná chyba → HB neaktivuje ans104 decoder.
- Z toho plyne: ans104 cesta je správná (POST `/`), ale náš ans104 payload není ve formátu, který HB očekává; `ar_bundles:deserialize_item/1` považuje podpis za prázdný.
- Další krok: inspekce `/app/src/ar_bundles.erl` v kontejneru pro přesný layout a zkusit jiný serializer (např. @irys/arbundles nebo toBuffer) / ověřit, že body obsahuje kompletní ANS104 bundle tak, jak jej chce HB.

### 2026-04-04 — Ans104 parsing state (local HB)
- POST na `/` s ans104 hlavičkami + query `/?x=1` nyní prochází až do ans104 decode, ale končí **500 "Attempted to resolve an empty message sequence."**
- Dřívější chyba `decode_signature` je pryč → signature se načte, ale výsledný TABM je prázdný.
- Inspekce `dev_codec_ans104_from` a `dev_codec_structured`: Base message se skládá z dat/tagů/fields podle `committed` keys; structured pak filtruje a dekóduje typy. Pokud committed/base je prázdný, vyletí "empty message sequence".
- Podezření: DataItem nemá dost klíčů v datech/tagách, takže committed keys jsou prázdné → žádná message.
- Další krok: poslat DataItem s data mapou obsahující `target` a `action` (lowercase, hb_ao normalize) a AO tagy (Type=Process, Data-Protocol=ao, Variant=ao.TN.1, Module, Scheduler, Authority, Name), na `/?x=1` s ans104 hlavičkami. Cíl: aby committed obsahovalo target/action a structured nevygenerovalo prázdnou sekvenci.

### 2026-04-04 — Empty message sequence root-cause
- HB router: jediná trasa `/_`; `/push` neexistuje. Aby se obešel 302 na UI, používáme query `/?x=1`.
- Ans104 request (POST `/` s hlavičkami `content-type: application/ans104`, `codec-device: ans104@1.0`, `accept-bundle: true`) se nyní deserializuje bez chyby podpisu, ale AO končí 500: **"Attempted to resolve an empty message sequence."**
- `hb_ao:resolve_many` dostává prázdný seznam, protože `hb_util:message_to_ordered_list` vytváří list pouze z **očíslovaných klíčů** (1,2,…) v TABM. Naše TABM po ans104 decode žádné numerické klíče nemá ⇒ prázdný list ⇒ empty sequence.
- Pokusy: target/action v TAGS, ao-data-key, data jako JSON map, jako list, jako map s klíčem "1" → stále empty sequence. Structured@1.0 (application/json + codec-device structured@1.0) končí `badmap` (body bráno jako binární řetězec).
- Z `dev_codec_ans104_from` a `hb_message` plyne: committed/base message jsou prázdné, resp. nejsou očíslované ⇒ `message_to_ordered_list` vrací [].
- Pro AO je potřeba TABM s numerickými klíči ("1", "2", …) nebo list. Ans104 data pole je binární, takže se numerické klíče nevytvoří automaticky; ans104 bundle zjevně nepřekládá JSON string do mapy.
- Další směr: buď použít codec httpsig@1.0 (podepsaný request) nebo ans104 bundle ve formátu, který obsahuje očíslované zprávy (nenalezeno), případně postavit TABM ručně (mimo ans104) tak, aby měl číselné klíče.

## 2026-04-05 — Mainnet WASM publish + spawn (push-1)
- WASM module publish TX: `O1gXFuy3-8UA2wvLgIpqOQNCYzziDnuC6q0gaSEcwS4` (tags: ao.TN.1, wasm64-unknown-emscripten-draft_2024_02_15, signing-format=ans104, accept-bundle=true, accept-codec=httpsig@1.0, Name=blackcat-write).
- Spawned PID (push-1): `xV9QOCYQ4SuS5_DbWas-nlrIFf8ObWs1n3arjC5AQ6g`.
- Initial ping test returned `1984` (likely pre-finalization behavior / default handler). Do **not** judge correctness until finalization completes.
- IMPORTANT: allow 30–40 minutes for both module TX and process TX to fully finalize/index before concluding any test results.

### Planned production-like validation (after finalization)
- Full functional test matrix: Ping, GetHealth, SaveDraftPage, Write-Command (signed), webhooks (ProviderWebhook/ProviderShippingWebhook), outbox HMAC, replay window, rate limits.
- Security tests: verify signature enforcement, nonce+timestamp window, reject unsigned commands, verify HMAC required in prod mode.
- Pentest pass: malformed payloads, oversized payloads, replayed nonces, missing tags, invalid signatures.

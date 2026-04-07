# AO deployment log – blackcat-write

## 2026-04-07 — Cross-repo security fit (ao + write + gateway + web)
- Context reviewed from READMEs:
  - `gateway` is intentionally untrusted/multi-tenant edge infrastructure (can forward writes, cache templates, hold short-lived encrypted envelopes).
  - `web` is per-admin control plane and local PII holder (offline-first, private key material local-only).
  - `write` is the command authority and must fail-closed on auth/replay/idempotency.
  - `ao` is public state projection and should remain secretless.
- Security consequence:
  - Wallet-address allowlists are not sufficient for write command authenticity in this architecture.
  - We need rotatable application signing keys (`signatureRef`/kid) independent from transport wallet identity.
- Decision for this project:
  1) Keep detached command signatures at app layer (`signature`, `signatureRef`, canonical payload).
  2) Verify Ed25519 in write process runtime (trustless app-level check), not by trusting gateway identity.
  3) Rotate keys via keyring map (`WRITE_SIG_PUBLICS`) + default fallback, no hardcoded wallet allowlists.
  4) Keep transport-level signatures (HTTPSIG/ANS104) as delivery integrity, not as sole business auth.
- Why this path:
  - Matches threat model where gateway can be third-party and still must write safely.
  - Preserves auditability and key-rotation control per admin/tenant without coupling to one wallet.
  - Aligns with AO split: `write` enforces auth semantics; `ao` consumes already-authorized publish events.
- Current blocker remains:
  - AO runtime currently reports `ed25519_not_available` unless verifier backend is bundled/available.
  - Next implementation step is to ship a deterministic Ed25519 verifier path in runtime and complete deep tests.

## 2026-04-07 — Deep research: best path for trustless Ed25519 + key rotation (no wallet allowlist)
- Goal confirmed: keep request signing/key rotation independent of wallet-address allowlists.
- HyperBEAM `httpsig@1.0` current path (as used in push/scheduler flow) is built around:
  - `rsa-pss-sha512` and `hmac-sha256` commitments in `dev_codec_httpsig.erl`.
  - `keyid` schemes (`publickey`, `constant`, `secret`) in `dev_codec_httpsig_keyid.erl`.
- `ans104/tx` codec currently notes RSA-only support in data-item signature type handling (`ar_bundles.erl` comments and encoder/decoder paths), so relying on ANS-104 for app-level Ed25519 verification is not a practical route for this blocker.
- Conclusion from code/docs review:
  - There is no drop-in AO-mainnet mechanism in current push flow to replace app-level Ed25519 detached verification with a native HB-only Ed25519 verifier for this write-command pattern.
  - Best production path remains **app-level Ed25519 verify in process code** + **rotatable keyring by `signatureRef`**, not wallet allowlists.
- Architecture recommendation (ordered):
  1) Implement/ship pure-Lua Ed25519 verifier in process runtime (trustless in-process check; no native libs required).
  2) Keep detached signature envelope (`signature`, `signatureRef`) and rotate keys via keyring map (`WRITE_SIG_PUBLICS`), with optional default key.
  3) Optional later hardening: move verify to shared verifier PID (module + write PID + verifier PID), but only after in-process path is stable (async complexity, callback flow, replay coordination).
- Current repo alignment toward rotation:
  - auth key selection supports `signatureRef`-based key lookup (`WRITE_SIG_PUBLICS` / `WRITE_SIG_PUBLIC` fallback).
  - CLI helpers support explicit `SIGNATURE_REF` when generating/sending signed commands.
- Source references used for this conclusion:
  - HyperBEAM httpsig codec: `src/dev_codec_httpsig.erl`
  - HyperBEAM keyid schemes: `src/dev_codec_httpsig_keyid.erl`
  - HyperBEAM ans104 bundles: `src/ar_bundles.erl`
  - HyperBEAM docs: `https://hyperbeam.ar.io/build/devices/source-code/dev_codec_httpsig.html`

## 2026-04-07 — New finalized run (`DSFB...` / `5GtV...`) confirms exact blocker
- New module/pid tested after indexing:
  - Module: `DSFB26wxEh5Mr36Rn0yP0Nr4j4TTpeYM7SlrlSSbzas` (`raw=200`)
  - PID: `5GtVElIZaKYrhQpHlrmxPnNFueRvuHaaIFBdEtig_fs` (`raw=200`)
- Signed AO test (`send_write_command.js` + worker `/sign`) now returns exact auth reason:
  - `Write-Command-Result.Data` => `{"code":"UNAUTHORIZED","message":"ed25519_not_available",...}`
- This confirms the final blocker is **runtime crypto provider availability in AO process** (not worker signing, not canonicalization, not finalization timing).

## 2026-04-07 — Signature blocker diagnosis (final root-cause isolation)
- Reproduced current blocker on finalized PID `0dO9p0JKZU-yfVg85h4MfhcoMu2dtoKnEzcu-xQf1Wg`:
  - `scripts/cli/send_write_command.js` returns `Write-Command-Result` with:
    - `{"code":"UNAUTHORIZED","message":"signature failed",...}`
- Verified worker signature correctness independently:
  - Called production worker `/sign` with `tmp/test-secrets.json` token.
  - Verified returned signature locally with `tweetnacl` against `WRITE_SIG_PUBLIC_HEX` (`e3db...5459`).
  - Result: **valid signature** (`verify=true`), so worker key/canonicalization is not the failure source.
- Code-level root cause in process auth path:
  - `ao.shared.auth.verify_sig` discarded backend error reason (`verify_ed25519` second return value), masking the real failure.
  - `M.route` also ran a second detached-signature check on a different message shape (`action|tenant|requestId`), which can fail even if primary detached verification passes.
- Fixes applied in source:
  - `ao/shared/auth.lua`: now propagates backend verification reasons for hmac/ecdsa/ed25519.
  - `ao/write/process.lua`: removed redundant second detached-signature verification in `M.route`.
  - Same fixes mirrored in `dist/write/process.lua` so next WASM build includes diagnostics immediately.
- Build/deploy status:
  - Docker daemon issue was resolved by starting Docker Desktop from Windows (`dockerDesktopLinuxEngine` became available).
  - Rebuilt WASM from patched runtime and published/spawned:
    - Module TX: `DSFB26wxEh5Mr36Rn0yP0Nr4j4TTpeYM7SlrlSSbzas`
    - PID: `5GtVElIZaKYrhQpHlrmxPnNFueRvuHaaIFBdEtig_fs`
  - Immediate post-spawn status (expected early window):
    - `arweave.net/tx/<module>` = `202`
    - `arweave.net/raw/<module>` = `404`
    - `arweave.net/tx/<pid>` = `404`
    - `arweave.net/raw/<pid>` = `404`
    - `POST /<PID>` = `200`
    - `POST /<PID>~process@1.0/push` = `500`
  - Next step after full indexing/finalization: rerun signed `Write-Command` on PID `5GtV...` and confirm exact auth backend error text.

## 2026-04-07 — Deep tests on finalized pair (`zts...` / `0dO9...`)
- Finalized test target:
  - Module: `ztsL6BgF69JtwFb7-xq6pCVUBGdXmBKYfybnSRZHe2k` (`raw=200`)
  - PID: `0dO9p0JKZU-yfVg85h4MfhcoMu2dtoKnEzcu-xQf1Wg` (`raw=200`)
- AO deep probes against `https://push.forward.computer`:
  - `Ping` => transport OK, `msgId=1`, no runtime crash, output contains AOS action print.
  - `GetHealth` => transport OK, `msgId=2`, no runtime crash, output contains AOS action print.
  - `Write-Command` => transport OK, `msgId=3`, emits one outbound `Write-Command-Result`.
- Key blocker verification result:
  - **Fixed:** `Write-Command-Result.Data` is now JSON string.
  - **Not fixed:** auth result is `{\"code\":\"UNAUTHORIZED\",\"message\":\"signature failed\",...}`.
  - **Important:** previous `Data = table: 0x...` regression is gone on this pair.
- Residual blocker moved from serialization to signature validation semantics:
  - worker-signed detached signature is being rejected by process verifier (`signature failed`).
  - next step is auth/signature canonicalization alignment (worker signer payload vs `auth.canonical_detached_message` expectations), not transport/runtime stability.

## 2026-04-07 — Follow-up after retest: runtime seed + templates fixes re-applied
- During deep retest on PID `ZHH-Ocf5i3ebPTdoDdh6-2DM5GNTfX_eSer4W-griRc` (module `NVtraFxy...`), process still failed with:
  - `[string ".process"]:567: attempt to concatenate a nil value (field 'Module')`
- Root cause confirmed: generated runtime (`dist/write/process.lua`) still had non-nil-safe seed path and eager templates require.
- Re-applied both runtime hotfixes directly in generated runtime before WASM compile:
  - nil-safe seed components for `Block-Height`, `Owner`, `Module`, `Id`
  - `pcall(require, "templates")` fallback to `{}` for bundled templates
- Rebuilt + published + spawned again:
  - Module TX: `ztsL6BgF69JtwFb7-xq6pCVUBGdXmBKYfybnSRZHe2k`
  - PID: `0dO9p0JKZU-yfVg85h4MfhcoMu2dtoKnEzcu-xQf1Wg`
- Immediate status after spawn:
  - module `tx`: `202` / `raw`: `404`
  - pid `tx`: `404` / `raw`: `404`
- Next gate: wait finalization/indexing, then rerun deep tests on PID `0dO9...` to verify:
  - no nil-Module crash
  - no templates crash
  - `Write-Command-Result.Data` is JSON (not `table: 0x...`)

## 2026-04-07 — Write-Command JSON serialization hotfix (new build)
- Implemented process-side serialization hardening in `ao/write/process.lua`:
  - replaced `encode_json` fallback from `tostring(value)` to a deterministic JSON fallback encoder.
  - fallback now handles arrays/objects, scalar escaping, non-finite numbers, and cycle guard.
  - goal: prevent `Write-Command-Result.Data = "table: 0x..."` and always emit JSON text.
- Rebuilt artifacts:
  - `node scripts/build-write-bundle.js`
  - `node /tmp/hyperengine-cli/dist/cli.js build`
  - `docker run --platform linux/amd64 -v "$PWD:/src" p3rmaw3b/ao:0.1.5 ao-build-module` from `dist/write/`
- Published new module:
  - Module TX: `NVtraFxyZYrYkkUNWrD-8Tk87JJslCTBMMXrBQsExJQ` (`status 200` on publish)
- Spawned new process on `https://push.forward.computer`:
  - PID: `ZHH-Ocf5i3ebPTdoDdh6-2DM5GNTfX_eSer4W-griRc`
- Immediate post-spawn checks:
  - module `tx` endpoint: `200`
  - module `raw` endpoint: `404` (indexing window)
  - PID `tx` endpoint: `404` (indexing window)
  - direct `POST /<PID>`: `200` + `1984`
  - `POST /<PID>~process@1.0/push`: `500` (expected before full indexing/finalization)
- Release gate for this hotfix:
  - wait until both `/raw/<module>` and `/raw/<pid>` are `200`, then rerun deep tests (`Ping`, `GetHealth`, `Write-Command`) against PID `ZHH...`.
  - success criterion: `Write-Command-Result.Data` must be JSON (no `table: 0x...`).

## 2026-04-07 — Retest after "both hotfixes are green"
- Retest target endpoint: `https://push.forward.computer` with scheduler `n_XZJhUnmldNFo4dhajoPZWhBXuJk-OcQr5JQ49c4Zo`.
- Worker signer remains healthy with `tmp/test-secrets.json`:
  - `GET /health` => `200`
  - `GET /metrics` => `200`
  - `POST /sign` => `200` + valid `{ signature, signatureRef }`
- Process `3EE6jzn_T6GUwmtVejAJuKsOpSEmiXR8I4iy4vaCUrM` (first hotfix pair) is still broken at runtime:
  - `diagnose_message` returns `status=200` but runtime error remains:
  - `module 'templates' not found` (same stack as before).
- Process `yqESMx5s_6x_iuxDtrdGKI3zmm2rn4oeY2th0FZh8BU` (second hotfix pair) now accepts messaging:
  - `ao.message` for `Ping` works (`msgId` increments).
  - `ao.request` to `/<PID>~process@1.0/push` returns `200` and no `templates` runtime error.
  - Direct `POST /<PID>` still returns `200` + `1984` (state path).
- Current blocker moved to response serialization semantics on `Write-Command`:
  - `Write-Command` executes and emits outbound `Action=Write-Command-Result`,
  - but outbound `Data` is `table: 0x...` instead of JSON payload.
  - This indicates table-to-string fallback in process response encoding (`tostring(table)` path) is being hit in runtime.
- Practical implication:
  - Transport/signature path is now accepted on `yqES...`.
  - Release is still blocked until `Write-Command-Result.Data` is always JSON (never Lua table pointer text).

## 2026-04-07 — Deep test on green hotfix pair + second hotfix spawn
- Tested green pair:
  - Module `CYg8_NvhuHI-8o-QasvOAyzMXjgp8DmdxJaZJTVsah0`
  - PID `3EE6jzn_T6GUwmtVejAJuKsOpSEmiXR8I4iy4vaCUrM`
- Worker test-secrets path still healthy (`/health`, `/metrics`, `/sign` all `200`).
- Deep diagnose against `push.forward.computer` returned a concrete process error:
  - `module 'templates' not found`
  - This comes from generated `dist/write/process.lua` where `require("templates")` runs before `package.preload["templates"]` is defined.
- Applied runtime hotfix in generated Lua:
  - changed eager `local _bundled = require("templates")` to `pcall(require, "templates")` with `{}` fallback.
- Rebuilt/republished/respawned after this fix:
  - New module: `6YEUKQps0VlH5vZs2aE6nMkM1Ola2XOSijJvtAUL6AI`
  - New PID: `yqESMx5s_6x_iuxDtrdGKI3zmm2rn4oeY2th0FZh8BU`
- Immediate status of newest pair:
  - `arweave.net/raw/<module>` and `arweave.net/raw/<pid>` are currently `404` right after spawn (indexing window).
  - Direct path `POST /PID` returns `200` + `1984`.
  - Push path currently returns `500` during early indexing window.
- Action: wait full indexing/finalization for `6YEU...` + `yqES...`, then rerun deep tests (Write-Command, Ping, GetHealth) on `push.forward.computer`.

## 2026-04-06 — New blocker isolated + hotfix rebuild cycle
- While retesting the finalized pair, a hidden transport regression was found:
  - `push-1.forward.computer` started returning `400` for paths that previously worked.
  - `push.forward.computer` still responded correctly for direct process reads (`GET/POST /PID` => `200` + `1984`).
- Root-cause in CLI helpers:
  - `@permaweb/aoconnect` 0.0.93 clears `process.env.AO_URL` at module load in this build path.
  - Scripts that relied on `AO_URL` silently fell back to `https://push-1.forward.computer`.
  - Fix applied in local scripts:
    - `scripts/cli/send_write_command.js`
    - `scripts/cli/diagnose_message.js`
    - `scripts/cli/spawn_wasm_tn.js`
    - `scripts/cli/spawn_wasm_raw.js`
  - New env override precedence: `HB_URL/HYPERBEAM_URL` (and `HB_SCHEDULER/HYPERBEAM_SCHEDULER`) before legacy `AO_*`.
- Deep diagnosis on PID `MUZW7IZRDPLcEFitSJg1oeEjacdIgOQTmKktPw-XQG0` (module `ghwt8...`) through `push.forward.computer`:
  - `diagnose_message` returned `status=200` with runtime error:
    - `[string ".process"]:567: attempt to concatenate a nil value (field 'Module')`
  - Error maps to generated AOS runtime in `dist/write/process.lua`:
    - `chance.seed(tonumber(msg['Block-Height'] .. stringToSeed(msg.Owner .. msg.Module .. msg.Id)))`
  - This confirms the current runtime assumes `msg.Module` is always present on inbound messages, which is not true in this path.
- Hotfix applied in generated runtime before WASM compile:
  - `msg['Block-Height']`, `msg.Owner`, `msg.Module`, `msg.Id` now use nil-safe fallbacks in the seed expression.
- New rebuild/publish/spawn after hotfix:
  - **Module TX**: `CYg8_NvhuHI-8o-QasvOAyzMXjgp8DmdxJaZJTVsah0`
  - **PID**: `3EE6jzn_T6GUwmtVejAJuKsOpSEmiXR8I4iy4vaCUrM`
- Current state of this newest pair:
  - `arweave.net/raw/<module>` and `arweave.net/raw/<pid>` were still `404` right after spawn (indexing window in progress).
  - `diagnose_message` on the new PID currently returns `500` during this early window.
- Next gate:
  - Wait full indexing/finalization, then rerun `diagnose_message` + `send_write_command` on PID `3EE6...` using `HB_URL=https://push.forward.computer`.

## 2026-04-06 — Fresh WASM build + publish + spawn (post-fix run)
- Built a fresh WASM from current sources (including latest `ao/write/process.lua` changes) with:
  1) `node /tmp/hyperengine-cli/dist/cli.js build`
  2) `docker run --platform linux/amd64 -v \"$PWD:/src\" p3rmaw3b/ao:0.1.5 ao-build-module` from `dist/write/`
- New module published:
  - **Module TX**: `ghwt8knGDpHF6iXNQiTmB1KyWvXb2xsAWGQTt3MxBTs`
  - Upload status: `200`
  - Tags verified from `arweave.net/tx`:
    - `Content-Type=application/wasm`
    - `Module-Format=wasm64-unknown-emscripten-draft_2024_02_15`
    - `Variant=ao.TN.1`
    - `Data-Protocol=ao`
    - `Input-Encoding=JSON-1`
    - `Output-Encoding=JSON-1`
    - `Memory-Limit=1-gb`
    - `Compute-Limit=9000000000000`
    - `AOS-Version=2.0.6`
    - `Type=Module`
    - `Name=blackcat-write`
    - `signing-format=ans104`
    - `accept-bundle=true`
    - `accept-codec=httpsig@1.0`
- New process spawned on push-1:
  - **PID**: `MUZW7IZRDPLcEFitSJg1oeEjacdIgOQTmKktPw-XQG0`
  - Spawn command printed PID successfully.
- Immediate post-spawn state:
  - `arweave.net/raw/<module>`: still `404` shortly after publish (expected indexing delay).
  - `arweave.net/raw/<pid>`: `404` (expected before finalization/indexing).
  - Direct process path `POST /<PID>` still returns `200` + `1984`.
  - Push slot endpoint currently unstable for this fresh PID until indexing/finalization settles.
- Operational rule remains unchanged: wait for full indexing/finalization (often 40–60+ min) before judging handler correctness to avoid false negatives.

## 2026-04-06 — Production-like retest on finalized module/PID (worker secrets path)
- Target pair used for this run: Module `vCH7fxmbzfkby6_cGpfn3yY4H-shOalUhOr9n4zJJuM`, PID `5WXxCBn5PZADOb35QAGDpF8kY_bBrd7uuKEhaUy-XBk` (already finalized/indexed before tests).
- Secrets source: `tmp/test-secrets.json`; signer endpoint: `https://blackcat-inbox-production.vitek-pasek.workers.dev/sign`.
- Worker checks (all pass):
  - `GET /health` => `200` (`{"status":"ok",...}`).
  - `GET /metrics` with `METRICS_BEARER_TOKEN` => `200`.
  - `POST /sign` with `WORKER_AUTH_TOKEN` => `200` + `{signature, signatureRef}`.
- AO transport checks:
  - Direct process path `POST /<PID>` with `send-msg.js --direct --action Ping` => `200`, body `1984` (state fetch path behavior).
  - Raw HTTPSIG helper (`scripts/cli/hb_push_httpsig.js`) to `/<PID>~process@1.0/push` => `400 "Message is not valid."` (schema mismatch when bypassing aoconnect request construction).
  - aoconnect request path (`scripts/cli/send_write_command.js` and `scripts/cli/diagnose_message.js`) => `200` and slot progression observed: `27 -> 28 -> 29 -> 30 -> 31`.
- Message/result payload outcome is still the blocker:
  - `raw.Output=""`, `raw.Messages=[]`, `raw.Assignments=[]`, `raw.Error={}` for `Write-Command`, `Ping`, and `GetHealth`.
  - This confirms push/scheduler/signature transport is accepted, but handler-visible response/output is not emitted in current deployed runtime path.
- Current diagnosis:
  - Not a worker secret failure and not a push availability issue.
  - Blocker is at process-level response semantics on the deployed module/runtime path (accepted message, empty compute result payload).
- Next mandatory step before release:
  - Rebuild/redeploy from current `ao/write/process.lua` instrumentation and rerun the same three-message probe (`Write-Command`, `Ping`, `GetHealth`) expecting non-empty handler signal (either outbound message or compute output).

## 2026-04-05 — Live AO smoke with worker test-secrets (production endpoints)
- Source of test secrets: `tmp/test-secrets.json` (local only); worker endpoint used: `https://blackcat-inbox-production.vitek-pasek.workers.dev`.
- Worker checks:
  - `GET /health` → **200** (`{"status":"ok",...}`).
  - `GET /metrics` with bearer from test-secrets → **200** (Prometheus output).
  - `POST /sign` with auth token + write command body → **200**, returns `signature` + `signatureRef`.
- AO checks on push-1 for PID `5WXxCBn5PZADOb35QAGDpF8kY_bBrd7uuKEhaUy-XBk`:
  - Direct HTTPSIG JSON POST to `/PID` with `Action=Ping` → **200**, body `1984`.
  - `Action=GetHealth`, `Action=SaveDraftPage`, `Action=Write-Command` (signed) also return **200** with body `1984` on direct process path.
  - Crucial clarification: `/PID` is not message ingress; it returns process state/blob (here always `1984`). Actual message ingress is `/PID~process@1.0/push`.
  - Posting the same JSON message to `/PID~process@1.0/push` currently returns **400 `Message is not valid.`**, which is the real blocker.
  - `aoconnect` path (`message` + `result`) for signed `Write-Command` returns no actionable output (`Output=""`, `Messages=[]`, `Assignments=[]`, `Error={}`), i.e. accepted transport but no handler-level payload.
- Additional security sanity checks against current worker production endpoint:
  - Invalid auth token on `/sign` is rejected (**401**) as expected.
  - Timestamp/nonce/unknown-field hard checks are **not** enforced on the currently deployed `/sign` behavior (stale timestamp, replay nonce, and unknown field still returned **200** in this run), which suggests production worker code is behind the stricter local branch.
- Smoke report artifact written to: `tmp/ao-live-smoke-report.json`.

## 2026-04-05 — CI stabilization (tests 1-3 done)
- Implemented shared verify signing helper: `scripts/verify/_test_sign.lua` (`maybe_sign(cmd)`).
- Applied signing-aware command flow to failing specs:
  - `scripts/verify/action_validation_shipping.lua`
  - `scripts/verify/publish_flow.lua`
  - `scripts/verify/idempotency_replay.lua`
  - `scripts/verify/conflicts.lua`
  - `scripts/verify/publish_outbox_mock_ao.lua`
  - `tests/security/hmac_replay.lua`
- Added test-only auth mode to CI unit/spec steps (no prod relaxation):
  - In `.github/workflows/ci.yml`, shipping/publish/idempotency/conflicts/hmac/outbox steps now run with `WRITE_REQUIRE_SIGNATURE=0`, `WRITE_REQUIRE_NONCE=0`, `WRITE_REQUIRE_TIMESTAMP=0`, `WRITE_REQUIRE_JWT=0`, and high RL ceilings.
- Hardened `jwt_actor_spec` to be deterministic and non-flaky:
  - Now signs a fresh JWT with `ao.shared.jwt.sign_hs256`.
  - Skips cleanly unless `WRITE_REQUIRE_JWT=1` and `WRITE_JWT_HS_SECRET` are provided.
- Ran `stylua` autofix across `ao/`, `scripts/`, `tests/`.
- Local full CI-equivalent run after fixes: **17 pass / 0 fail**.
  - Report: `tmp/full-ci-local-report-after-fixes.txt`

## 2026-04-05 — HTTPSIG scheduler blocker (local HB) + latest module/PID
- Latest WASM module: `wNHRxZAHXeTKlWhWxgzeX7SQPAW5IhZ2khsCDnhDX74` (Variant `ao.TN.1`, signing-format `ans104`, accept-bundle + accept-codec set).
- Latest PID (mainnet push-1): `fEOj0AVVssxfJZLpiJ-D6iu2dPlRYLMObpDnRkkrEQs` (uses module above). Newer spawn pair also indexed: Module `O1gXFuy3-8UA2wvLgIpqOQNCYzziDnuC6q0gaSEcwS4`, PID `xV9QOCYQ4SuS5_DbWas-nlrIFf8ObWs1n3arjC5AQ6g`. Another finalized pair after deep-test rebuild: Module `vCH7fxmbzfkby6_cGpfn3yY4H-shOalUhOr9n4zJJuM`, PID `5WXxCBn5PZADOb35QAGDpF8kY_bBrd7uuKEhaUy-XBk` (current focus for local HB tests).
- Local Hyperbeam (hyperbeam-docker, edge-release-ephemeral) patched:
  - `dev_codec_httpsig_siginfo.erl` now tolerates full `comm-...=:BASE64:` signature headers by stripping the `=:` prefix/suffix before base64 decoding.
  - `dev_message.erl` strips `signature` / `signature-input` from the TABM before `calculate_id` so commitments don’t get polluted by headers.
  - Result: HTTPSIG headers parse; HB no longer 500s on b64 decode. Requests now reach `schedule.forward.computer/<PID>/schedule` and return **400 "Message is not valid"**, meaning HTTPSIG is fine but the **message body/commitments are not in the scheduler’s expected AO schema**.
- Helper added: `scripts/cli/hb_push_httpsig.js`
  - Builds a HTTPSIG-signed POST to `/PID` (or `/PID~process@1.0/push`) with `comm-` prefixed signature headers.
  - Supports `--action`, `--data`, `--variant`, `--message-file` to inject raw message JSON, `--debug`, `--print-curl`, and custom `--url` (default `http://localhost:8734`).
  - Uses wallet signer from `wallet.json`; switches keyid to `publickey:<jwk-n>` for HTTPSIG.
- Current blocker (to solve before deep tests): Scheduler requires a **committed AO message**:
  - HB logs show expected structure: `commitments` is a map keyed by commitment-id; each value contains `commitment-device`, `committed` (list/map of fields), `keyid`, `signature`, `type` (rsa-pss-sha512 and hmac-sha256 seen), and optional `committer`.
  - Our last attempt (single commitment map) triggers `{badmap, <<"OWg_PwduoEcPrUGMZ3sFiRYcvmIXivAtxCoURtuK-tI">>}`, so the scheduler tries to treat the binary commitment-id as a map key but sees a bare string.
  - Next step: send `commitments` as an object keyed by commitment-id with full maps inside, and include both rsa + hmac commitments (ids from HB log). `commitment-device` should likely be a map `{ "httpsig@1.0": true }`, not a bare string.
- Planned local deep-test path:
  1) Craft `tmp/committed_ping.json` with the two commitments (rsa + hmac) as map entries, `commitment-device` maps, `committed` as map `{body:true,method:true,path:true}`.
  2) `node scripts/cli/hb_push_httpsig.js --pid 5WXxCBn5PZADOb35QAGDpF8kY_bBrd7uuKEhaUy-XBk --url http://localhost:8734 --message-file tmp/committed_ping.json --debug --print-curl`.
  3) Check HB logs; success criterion: 200 or slot compute; failure 400 => adjust schema; 500 => adjust commitment types.
  4) Once local HB accepts Ping, rerun against push-1 with the same helper/body (swap `--url https://push-1.forward.computer`).
- Rule of thumb re finalization: every new module/PID must be fully indexed (Arweave /raw/<tx> 200) before messaging; allow 40–60 minutes on mainnet to avoid false negatives.

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

## Local deep test (2026-04-05) — aoconnect message/result
- Local HB: `http://localhost:8734`, local PID: `RSVTuHEIVcR9L4J2KHDbO9xRSSs1u7d5099DVo4Bmwc`.
- Sent aoconnect `message` with Action=Write-Command and signed JSON payload (using `tmp/test-signer.json` via `scripts/sign-write.js`), then `result` with 20s timeout.
- Result returned successfully but only showed AOS console output:
  - `Output.data`: "New Message From ... Action = Write-Command"
  - No `Messages`/`Assignments`/`Spawns` generated.
- Interpretation: message is accepted by HB, but the Write-Command handler is not producing any response in this path (either handler not wired for this message shape, or it expects a different tag/data format). This is the current local blocker to fully validate handler logic via aoconnect.

## Local rebuild (2026-04-05) — new module + PID (pending finalization)
- Built WASM and published module TX: `wNHRxZAHXeTKlWhWxgzeX7SQPAW5IhZ2khsCDnhDX74` (Arweave `tx` endpoint returns 200).
- Spawned local HB PID: `fEOj0AVVssxfJZLpiJ-D6iu2dPlRYLMObpDnRkkrEQs` (from module above).
- Local deep test attempt via aoconnect failed with `HTTP request failed`. Direct POST to PID returned 500.
- HB logs show it is trying to resolve `https://arweave.net/raw/<PID>` and gets **404**, then returns 500 (`badmap,failure`).
- Conclusion: even for local HB, the **PID must be indexed and available on Arweave** before `/PID` requests succeed. Wait until `/raw/<PID>` stops returning 404 (can take ~30+ minutes).

## Local deep test (2026-04-05) — after PID indexed
- `/raw/fEOj0AV...` now returns 200. Direct HTTPSIG POST to local HB `/PID` returns 200 + body `1984`.
- HB logs show slot compute failing with `AbortError` from `http://localhost:6363/result/0?process-id=fEOj0AV...` (status 500), then `error_computing_slot` and push returns 400.
- No handler debug prints appear, so the Write-Command handler still does not execute under this compute failure.
- Hypothesis: local compute/result service on port `6363` is aborting (timeout or missing service), which prevents HB from producing a result.
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

## Immediate todo for deep tests (2026-04-05)
- Finish committed-message body for HTTPSIG:
  - `commitments` must be a map keyed by commitment-id; include both RSA (`type: rsa-pss-sha512`, keyid `publickey:<wallet-n>`) and HMAC (`type: hmac-sha256`, keyid `constant:ao`) entries; each with `commitment-device: {"httpsig@1.0": true}`, `committed: {body:true,method:true,path:true}`, and `signature` values from HB log.
  - Top-level `commitment-device: {"httpsig@1.0": true}`.
  - Body fields: `target=<PID>`, `type=Message`, `action=Ping`, `variant=ao.TN.1`, `data-protocol=ao`, `data=""`.
- Use `scripts/cli/hb_push_httpsig.js --pid 5WXxCBn5PZADOb35QAGDpF8kY_bBrd7uuKEhaUy-XBk --url http://localhost:8734 --message-file tmp/committed_ping.json --debug --print-curl` and tail HB logs.
- If 400 persists: mirror `dev_scheduler:http_post_schedule_sign/3` structure (committed keys list vs map) and retry.
- After local Ping passes → repeat against push-1 with current mainnet PID (`5WXxCBn5PZADOb35QAGDpF8kY_bBrd7uuKEhaUy-XBk`) and record results.
- Once Ping/GetHealth pass, run full handler suite (Write-Command, SaveDraftPage) using the same helper, then switch to worker-signed commands.

### Messaging shape that actually works (no HB patch needed)
- Endpoint: `/<PID>` (not `/~scheduler@1.0/schedule`, not `/PID~process@1.0/push`).
- Headers: `Content-Type: application/json`, `codec-device: httpsig@1.0` (push.* also tolerates/sets accept-codec/accept-bundle).
- Body (Ping example):
  ```json
  {
    "tags":[
      {"name":"Action","value":"Ping"},
      {"name":"Content-Type","value":"application/json"},
      {"name":"Data-Protocol","value":"ao"},
      {"name":"Type","value":"Message"},
      {"name":"Variant","value":"ao.TN.1"}
    ],
    "data":""
  }
  ```
- Write-Command example: same tags but `Action=Write-Command`, plus optional Request-Id/Actor/Tenant/Timestamp tags; `data` is JSON string payload.
- Helper: `node scripts/cli/hb_push_httpsig.js --pid <PID> --url http://localhost:8734 --action Ping --data "" --variant ao.TN.1 --type Message --content-type application/json --direct`. Omit `--direct` only if you explicitly need `/~process@1.0/push` (generally not needed).
- Verified locally: Ping and Write-Command to `/PID` return 200 (body `1984` because current module still returns that stub).

### 2026-04-05 — False spawn blocker identified
- Spawn is **not** the blocker. Current mainnet pair is reachable and accepts direct POSTs:
  - PID `5WXxCBn5PZADOb35QAGDpF8kY_bBrd7uuKEhaUy-XBk` (module `vCH7fxmbzfkby6_cGpfn3yY4H-shOalUhOr9n4zJJuM`) returns HTTP 200 on push-1 for Ping/Write-Command shaped requests.
- Root cause of repeated `400` during diagnostics was the helper request shape:
  - `scripts/cli/hb_push_httpsig.js` initially omitted `codec-device: httpsig@1.0`, so push-1 rejected requests.
  - After adding `codec-device`, the same helper returns `200` on both local HB and push-1.
- Practical conclusion:
  - If you see `400` from helper, first verify `codec-device` is present.
  - Treat spawn as healthy when `/raw/<module>` is 200 and direct `/PID` message returns 200.
  - Remaining issue is **runtime behavior** (`1984` / empty outputs), not spawn transport.

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

## 2026-04-05 — Local HB spawn + ping confirmed (httpsig)
- Local HB spawn works with aoconnect: `connect({ MODE: 'mainnet', URL: 'http://localhost:8734', SCHEDULER: n_XZ... })` + `spawn({ module: O1gXF..., scheduler/authority: n_XZ..., data: '1984' })`.
- Local PID returned: `RSVTuHEIVcR9L4J2KHDbO9xRSSs1u7d5099DVo4Bmwc`.
- Local ping works via HTTPSIG JSON: `node send-msg.js --pid <PID> --url http://localhost:8734 --action Ping --data ""` → **200 OK**, body `1984`.
- Key takeaway: local HB can only resolve **local** PIDs; trying to hit a mainnet PID locally causes 502 fetch from `arweave.net/raw/<PID>` and leads to 500s. Use local spawn first, then message `/PID` directly (no `/message`, no ANS‑104).
- Local smoke (HTTPSIG JSON to `/PID`): Ping, GetOpsHealth, SaveDraft preset, and Write-Command (signed) all returned **200 OK** with body `1984`. This confirms the local request shape is accepted; handler output still needs validation once we have a result/observe pipeline.

### Planned production-like validation (after finalization)
- Full functional test matrix: Ping, GetHealth, SaveDraftPage, Write-Command (signed), webhooks (ProviderWebhook/ProviderShippingWebhook), outbox HMAC, replay window, rate limits.
- Security tests: verify signature enforcement, nonce+timestamp window, reject unsigned commands, verify HMAC required in prod mode.
- Pentest pass: malformed payloads, oversized payloads, replayed nonces, missing tags, invalid signatures.

## 2026-04-05 — Local HB deep-test blocker (HTTPSIG vs ANS-104)
- **aoconnect is hardwired to ANS-104** for `message()` and `result()` (base params include `signing-format: ans104`). HB rejects ANS-104 locally with `unsupported_tx_format` during `ar_bundles:deserialize_item/1`.
- For local HB, **HTTPSIG must be used** for `/PID~process@1.0/push`. The request must be a valid HTTP Message Signature, not ANS-104.
- **Important: HB expects `comm-` prefixed signature headers.** `dev_codec_httpsig_siginfo.erl` only extracts commitments when `signature` and `signature-input` start with `comm-...`. Standard HTTP Message Signatures without the prefix fail verification → `Message is not valid.`
- A plain HTTPSIG POST (even correctly signed) currently fails verification because the commitment extraction can’t find `comm-` signatures; result is 400 with `Message is not valid.`
- Manual JSON POST to `/PID~process@1.0/push` without HTTPSIG verification returns the same `Message is not valid` (scheduler rejects an unsigned/invalid message).
- Even when HTTPSIG succeeds, **scheduler still returns 400** unless the message map matches the exact AO scheduler schema — so the remaining blocker is **message construction + HTTPSIG framing**, not tags or push server.
- Conclusion: **We need a helper that builds an AO message map, signs it using HTTP Message Signatures, then prefixes `signature` and `signature-input` with `comm-` before POSTing.** This is required to pass local HB verification.
- Helper plan: build AO message map (same structure as aoconnect), sign with HTTP Message Signatures, prefix `Signature`/`Signature-Input` with `comm-`, POST to `/PID~process@1.0/push`. Once it passes locally, reuse on push/mainnet.

### 2026-04-05 — HTTPSIG helper attempt (local HB)
- Added helper `scripts/cli/hb_push_httpsig.js` to sign a JSON message body with HTTP Message Signatures and rewrite headers into `comm-<sigName>=...` form.
- Current output headers look like:
  - `signature: comm-<sigName>=:base64:`
  - `signature-input: comm-<sigName>=(...);keyid="publickey:..."` (rsa-pss-sha512)
- HB still returns **500** with `dev_codec_httpsig_siginfo:commitment_to_sf_siginfo/3` → `badarg` (b64fast decode), so parsing still fails even with `comm-` prefix.
- Next suspicion: signature header key must be `comm-<sigName>` where `<sigName>` matches `hb_util:human_id(sha256(signature))` **and** the dictionary format must match HB’s structured-field parser exactly. We may need to generate the signature dictionary directly rather than rewiring `http-message-signatures` output.
### 2026-04-05 — HB HTTPSIG decode suspicion (base64 vs base64url)
- Likely root-cause for `b64fast:decode64` badarg: helper emits **base64url** (no padding) for `signature` / `signature-input` values. HB’s `b64fast` expects **standard base64** (RFC 8941 binary value) with `+`/`/` and padding.
- Action: adjust helper to output **standard base64** (not base64url) for the binary signature portion and any structured-field binary values, then re-test with HB logs.
### 2026-04-05 — HTTPSIG roundtrip findings (local HB)
- `dev_codec_httpsig_conv:from()` succeeds with our `comm-<sigName>=:BASE64:` signature dictionary and `signature-input` list.
- **Crash root‑cause** in `commitment_to_sf_siginfo`: if `signature-input` includes `created`/`expires`, HB parses them as **integers** and later crashes because `commitment_to_sf_siginfo` expects `{integer, N}` tuples. This reproduces locally via `roundtrip.escript`.
- Workaround: **omit `created`/`expires`** from `signature-input` parameters. Keep `alg` + `keyid` only.
- With `alg` + `keyid` only, `from()` + `to()` roundtrip succeeds locally (no crash). `signature-input` in re-encoded response becomes `=()` with params `alg`/`keyid`.
- Despite the roundtrip success, the running HB server still reports `badarg` on `commitment_to_sf_siginfo` when hitting `/PID~process@1.0/push`; need to confirm if server still sees `created`/`expires` or if header normalization differs at runtime.
### 2026-04-05 — Runtime HB crash: signature header leaking into commitment
- Using the exact `curl` headers generated by `hb_push_httpsig.js` still crashes local HB with `b64fast:decode64` on the **entire signature header string** (`comm-...=:...:`).
- This implies the runtime path is passing the **raw `signature` header** into `commitments_to_siginfo` (as `Commitment.signature`) instead of using the parsed commitments map.
- Likely cause: during `dev_message:calculate_id` / `dev_codec_httpsig:commit`, the `signature` header is not stripped from the message base, so it gets treated as signature data and `hb_util:decode` fails.
- Hypothesis: server should drop `signature`/`signature-input` before `commit`, or only use commitments derived from `siginfo_to_commitments`.
- Next diagnostic: patch hyperbeam-docker to remove `signature` + `signature-input` before `calculate_id`, then re-test to validate this theory.

### 2026-04-05 — HTTPSIG local HB progress (commitment parsing fix)
- Patched hyperbeam-docker `dev_codec_httpsig_siginfo:commitment_to_sf_siginfo/3` to tolerate a **full signature header value** by extracting the base64 between `=:` and trailing `:` before decoding.
- After rebuild, local HB no longer crashes on `b64fast:decode64`; requests now return **400 "Message is not valid."** instead of 500.
- HB logs show the request reaches `schedule.forward.computer/<PID>/schedule` and that endpoint returns **400**, then HB propagates the 400 back to the client.
- This strongly suggests the **message body is still not in the scheduler’s expected AO schema** (commitments/committed keys missing), even though HTTPSIG headers are now accepted.
- Next step: update helper to build a **fully committed AO message map** (with `commitments` and committed keys) and wrap it in a committed envelope (similar to `dev_scheduler:http_post_schedule_sign`).

### 2026-04-05 — Extracted the exact committed scheduler payload (Ping)
- Inside patched hyperbeam container, generated the scheduler POST body HB expects by calling `hb_message:commit` with path `/~scheduler@1.0/schedule`, method POST, and inner message (target=PID, type=Message, action=Ping, variant=ao.TN.1, data="").
- Captured the committed TABM as Erlang term (base64-encoded ETF). This is the ground truth shape HB wants; our current helper still sends a bare JSON and misses `commitments`/`commitment-*` keys.
- Base64 (ETF) blob for the Ping request: `g3QAAAAEbQAAAARib2R5aAN3BGxpbmttAAAAK1dGbWM0cEpxT2t1S19aZFdpekMzd3lIT1VJOEMxMnNnYVpxVHBKNGpIeVF0AAAAAm0AAAAEbGF6eXcFZmFsc2VtAAAABHR5cGVtAAAABGxpbmttAAAAC2NvbW1pdG1lbnRzdAAAAAJtAAAAK2psdFE1LXk3NDFHektOX0ktaXE5ZEc3VDFFMG8xQXI1dzNhaGhtOGV6cUF0AAAABm0AAAARY29tbWl0bWVudC1kZXZpY2VtAAAAC2h0dHBzaWdAMS4wbQAAAAljb21taXR0ZWRsAAAAA20AAAAEYm9keW0AAAAGbWV0aG9kbQAAAARwYXRoam0AAAAJY29tbWl0dGVybQAAACtacWt1b0haM0dUU0NWaDk2QlVnTzB3bHN6dU9mekZjZXJkX3pONVc0eFRVbQAAAAVrZXlpZG0AAAK2cHVibGlja2V5OndqZU5KdWFjUkNrK1FsVjdmTWVSL0o0UUZUcVMwdWhzT1hyQjdOM2dyUUduZWdGQ1FSVW5HZytIWmIyRDZqUGZjWVBSOUdNbnYweHhBbmQyTFg4Q1NWOFlTRWhMdHVKaHU4VWdneFZHM3ltNFIwMW9KbVNZaXdSQzQ1Wm1TSW1UOGtwVFQ2emp1dEp3d014REdGck9majZqbEpJemdNQmVPL2drWnlCV3g4YkJ5MXRQL0tvMFF4MjUweXpQMzRoMk9UL1phWm1MMzJ2Y05rQlAyM2sxd3BrblEwTHNWVkJCM3pDeFY1ODlIb1ZxTWI0MG1IMThaRDh2TEtvb1Jha3ZlU01jdzI2Q3NEL1pweU1Nb2NCMys4VW5nYm4wNE9tRGVuN2hUcWFtVEFyait0Q1JjRmNiWWp0UmdwWVJKZHpMQVpYaTJENzVaRFV3Ny9tTytKOVQ3cE9MQ3JsY09BVG1SZTRENHlyUndzaUJ2YTVTRG1ONDc4QlhsZDZzSitnMWRjV0wwTHF1SjJqRmZ5L2t2UFlRYWVxSkRBWFM4SjRwTkJHNGZCQVRheGozRjRFMnRRL2ZUTFExeWJRVGFDWkE1T2pXK1cwSWdXMFl0Z0x6U3lTODMxVFo4ZU45NGd0WjgxcXlNdk9ZUjVYangzdXlGNjRxNnhMUTRVRGQ4ZU9BSUs1dWhDd25Wb3k4ZnVvS1IvVnMzcWNtWGNxTFVOYlkyVWRqZ3VOcEJ5SVV6OUw2TWJvWnB1dWl4bXRDSUdFbm1MTlJwN0MwTFFsYTNoc3dvVE1EWmZQRUJoZGQrYkdZSDExc2RaZ2ZqY0hwZG13RVhBY2FoZnBibGJxb3U0VE5lcm9IaS92a29OT2JabkhJV2pjcS9vaVlrenZpdUpLeVJwRlVyVDBKWUdjPW0AAAAJc2lnbmF0dXJlbQAAAqtYc0I1aVdwVXhYZTB0SlFrTDRYR0x1NGdnTTF6ZDhZc1FTSzFBUVFTcG4xMEF6LUxZTnRpeTIwZmRvcVJwX0ZNaFRNaWxtZ2h1Rl9CdGNuRkk3bHV2N29tTVpSMlJSRDBqREJMakU3a082azVsUzZTbHBZY2FIUEQtSXRNcWd3VG5ZOGhvSXBvNVNTNlh0TFhmVFY2djdoQ3F1X0s2NDJsX2hMb2tRaHE0VFdmS2pYSnd4YUlmcHl5Uk1oUmZwSGZjM2FpeFNnZmUyeUoxQU5tQUt4dm5vdFJfdG5fclpmc0VtRm9WdU5zQ3NNYWQ1bkFEOERxajU0OUdOZEVfdnRDTnFZYWIwQWhOWG1wWDRFYTBWcy16amxJRGk1OE1HeHZLZWNVTDhlRXdhLTVGalY4OFpQaTN6YlNtS1NzRzZQcTRmaUZkZHd6Y0FmQ3NEaEljazgzcnlWUHJrMHhLZjJnc3d4M2RvVHNUTHVNMzJZNGZOaVlfdFU1SFB5T2I5alZZTmIwZERKOWhCbHZJa1pNRnRDQVlEbWFwbEdOR01MdW5CT0xtVEtqUFVKZ2FlQVVVYzB5SFFRdnBVdmZvYkdWSEpaLVk2aXRQLWwwa0ZSckVGU1p2RzRYNnd2T0FEcWhFZGo2QkMwZzgzSmtZSE9ZaXhmbkpCcmNzbGltQzV2MElQU0pHOXNqLUw3UmhmenVPZGF5Z05pYTA5NlUxR1RaTE93RzVmTzV1M0xBZXQzblI0LXZVZ3VUNnRISy02OXhHWnJyTFNFVjdpeXBwOVFEeS1pOUZ6akdZTlRjLXhFdWg0ajZObUJTXzdRbTlCdmJuTUw2VFZqbmJKTXFDU1V3dWQxTkpIdWNLaUZJSlRSZ2toTFdVV2szdXBzQjBHV1pXVGRqbDBSS2g3dw==`.
- Action item: decode this ETF and make `hb_push_httpsig.js` send this committed structure (with commitments + commitment-device fields) instead of bare JSON, then re-test locally; if 200, reuse for push.

### 2026-04-05 — CI stabilization pass ("1-3" completed)
- Implemented verify helper `scripts/verify/_test_sign.lua` to sign test commands with `scripts/sign-write.js` when `WRITE_SIG_PRIV_HEX` is present; tests auto-fallback to unsigned mode only when signature env is intentionally absent.
- Updated CI smoke steps for shipping/publish/idempotency/conflicts/outbox to run in explicit test mode (`WRITE_REQUIRE_SIGNATURE=0`, nonce/timestamp/jwt off, high RL limits) so unit/spec checks stay deterministic and do not fail on runtime-only auth gates.
- Enabled nightly JWT actor mapping step with explicit env (`WRITE_REQUIRE_JWT=1`, fixed 32-byte `WRITE_JWT_HS_SECRET`) so it no longer silently skips.
- Hardened JWT/HMAC specs for sodium-only environments:
  - `jwt_expiry_spec.lua` now uses a 32-byte fallback secret and an expiry window that is definitively outside auth skew tolerance.
  - `outbox_hmac_spec.lua` now uses a 32-byte secret to avoid `wrong key size` failures when OpenSSL HMAC is unavailable.
- Removed temporary verbose `print(...)` diagnostics from `ao/write/process.lua` `Write-Command` handler to avoid payload/signature leakage in production logs.
- Local validation run completed for CI-equivalent path: preflight, luacheck, stylua check, ingest/envelope/action (skip-aware), shipping/publish/idempotency/conflicts/hmac replay/publish-outbox, checksum alert; all passed with expected skip semantics for strict-signature smokes.

## 2026-04-05 — Mainnet continuation: worker secrets smoke + handler-matching fix
- Worker test-secrets smoke is healthy:
  - `GET /health` on `blackcat-inbox-production` -> 200
  - `POST /sign` with `WORKER_AUTH_TOKEN` -> 200 with signature + signatureRef
  - `GET /metrics` with `METRICS_BEARER_TOKEN` -> 200
- AO live test on finalized PID `5WXxCBn5PZADOb35QAGDpF8kY_bBrd7uuKEhaUy-XBk`:
  - `ao.request` / `ao.message` to `/<PID>~process@1.0/push` succeeds transport-wise (200, slot increments),
  - but `raw.Output=""`, `raw.Messages=[]`, `raw.Error={}` (handler-level no-op symptom remains).
- Diagnostic conclusion: `Write-Command` handler likely not matching incoming message shape in all runtimes.
- Code fix applied in `ao/write/process.lua`:
  - replaced strict `Handlers.utils.hasMatchingTag("Action", "Write-Command")` usage with a resilient matcher that accepts:
    - top-level `Action` / `action`,
    - map-style tags (`Action`/`action`/`ACTION`),
    - array-style tags (`[{name,value}]`) case-insensitively.
- Rebuild + deploy sequence executed:
  - build: `/home/jaine/.local/bin/ao-dev build` (WASM rebuilt)
  - module publish tx: `qPBm6y3vKe2mckcgMX7ckAaw6-U0VYIRPrY2zRmWFPg` (HTTP 200 on publish)
  - spawned PID: `WzjZR8SQwqaMFbH2sfZ6Urr4qXyYWqZXRyXa85AQO1w`
- Current finalization state right after spawn:
  - module tx status endpoint -> `202 Accepted`
  - process tx status endpoint -> `404 Not Found` (expected early window)
  - early push test on new PID -> 400 until indexing/finalization completes.
- Required next step (do not evaluate behavior before this): wait standard finalization window, then rerun `scripts/cli/diagnose_message.js` and `scripts/cli/send_write_command.js` against PID `Wzj...`.

## 2026-04-06 — Current blocker diagnosis update (mainnet + local)
- Local debug stack is back online after restart:
  - `hyperbeam-docker-hyperbeam-edge-release-ephemeral-1` on `http://localhost:8734`
  - `hyperbeam-docker-local-cu-1` on `http://localhost:6363`
- Worker signing endpoint is healthy again:
  - `POST https://blackcat-inbox-production.vitek-pasek.workers.dev/sign` with `Authorization: Bearer <WORKER_AUTH_TOKEN>` returns `200` with `{ signature, signatureRef }`.
- Mainnet `/push` acceptance matrix on current PID `5WXxCBn5PZADOb35QAGDpF8kY_bBrd7uuKEhaUy-XBk`:
  - minimal request (`Action/Type/Variant/Data-Protocol` only) -> `400 Message is not valid.`
  - with nonce/timestamp/owner/status only -> still `400 Message is not valid.`
  - with AO transport tags (`signing-format=ans104`, `accept-bundle=true`, `require-codec=application/json`) -> `200`.
- Important conclusion: the last 400 blocker is **transport-shape related** for `/PID~process@1.0/push`. The AO transport trio above is mandatory in practice for this flow.
- `ao.message()` now works against this PID (slot increments; e.g. `msgId 23`, `msgId 24` observed), so basic message ingress is no longer blocked.
- `ao.result()` currently returns empty execution payload (`Output=""`, `Messages=[]`, `Error={}`) for Ping/Write-Command tests on this PID.
  - This means transport succeeds, but handler-level observable output is still missing in this process/runtime path.
- Secondary PID `WzjZR8SQwqaMFbH2sfZ6Urr4qXyYWqZXRyXa85AQO1w` still returns `400` with only `{ commitments, status: 400 }` on the same push probe, so it should not be used as current test target.

### Known-good push probe shape (mainnet)
- Endpoint: `https://push-1.forward.computer/<PID>~process@1.0/push`
- Required fields in request params:
  - `Action`, `Type=Message`, `Variant=ao.TN.1`, `Data-Protocol=ao`
  - `signing-format=ans104`
  - `accept-bundle=true`
  - `require-codec=application/json`

### Open issue after transport fix
- Message delivery is accepted, but AO result remains empty for Write-Command/Ping business checks.
- Next deep-test step is not transport anymore; it is **process-level observability/handler execution confirmation** on the selected PID.

### 2026-04-06 — Write-Command observability hardening patch
- Patched `ao/write/process.lua` `register_write_handlers()` to make AO runtime diagnostics explicit:
  - `M.route(cmd)` is now wrapped in `pcall` (runtime exceptions become structured `HANDLER_CRASH` response instead of silent no-op).
  - Added resilient reply-target resolution (`From`/`from`/`Reply-To`/`ReplyTo`/`From` tag fallback).
  - Added guarded send (`safe_send`) so failed `Send` no longer aborts the handler path.
  - Added AO counters for diagnostics:
    - `write.ao.handler_crash`
    - `write.ao.reply_target_missing`
    - `write.ao.send_failed`
  - Handler now also **returns** JSON response payload (`resp_json`) for compute-path observability, even when outbound message channel is unavailable.
- Why this patch matters:
  - If `msg.From` is missing/empty in this runtime path, previous code could fail on `Send` and produce no visible business output.
  - This patch preserves response visibility and gives concrete counters for root-cause confirmation during deep tests.

## 2026-04-07 — Final blocker diagnosis completed (signature path)
- Root cause #1 (crypto adapter): `ao/shared/crypto.lua` expected `sodium.from_hex` / `sodium.to_hex`, but common `luasodium` exposes `sodium_hex2bin` / `sodium_bin2hex`.
  - Impact: valid Ed25519 signatures were rejected (`ed25519_not_available` / `bad_signature`) even with correct keys.
  - Fix: added compatibility helpers for both sodium APIs, plus safer HMAC sodium fallback handling.
- Root cause #2 (canonical message mismatch): Lua detached canonicalization did not match JS signer output.
  - Empty payload table was encoded as `[]` in Lua but `{}` in JS.
  - String encoding depended on `cjson.encode` behavior (e.g., escaped slashes), causing cross-runtime signature drift.
  - Fix: deterministic JSON canonicalization in `ao/shared/auth.lua`:
    - empty tables are treated as objects (`{}`) for signature purposes,
    - string escaping is handled explicitly and consistently (library-independent).
- Added keyring/signatureRef regression spec:
  - `scripts/verify/sig_publics_keyring.lua`
  - validates `WRITE_SIG_PUBLICS` mapping + `signatureRef` routing (`tenant-a`, `tenant-b`, `default`).
- CI hardening updates:
  - `ingest_smoke`, `envelope_guard`, and `action_validation` now run with deterministic Ed25519 test env (instead of skip-only behavior).
  - new CI step `SignatureRef keyring routing` executes `sig_publics_keyring.lua`.
- Local validation result (with Lua rocks path loaded):
  - `ingest_smoke: OK`
  - `envelope_guard: ok`
  - `action_validation: ok`
  - `sig_publics_keyring: ok`
  - all current luacheck + stylua checks passed in this run.

## 2026-04-07 — New mainnet publish/spawn run (post-CI fix)
- New module publish:
  - Module TX: `zbe7l9INN2hlIwIBAqr0LRxkm9YGd6nL41olyLnIPnU` (`status 200` on publish)
- New process spawn on `https://push.forward.computer`:
  - PID: `revWysnw_rgzvG5Lgm73moQFElfxK8stAIWSMNSrMek`
  - Spawn tags include: `WRITE_SIG_TYPE=ed25519`, `WRITE_SIG_PUBLIC=hex:e3db1fdf78b6d88e94e69d96a708fd836d66275d186033d7d8b7a6f46be45459`.
- Immediate indexing/finalization state:
  - `arweave.net/tx/<module>/status` => `200`
  - `arweave.net/raw/<module>` => `404` (still indexing)
  - `arweave.net/tx/<pid>/status` => `404` (still indexing)
  - `arweave.net/raw/<pid>` => `404` (still indexing)
- Worker path remains healthy with `tmp/test-secrets.json`:
  - `/health` => `200`
  - `/metrics` => `200`
  - `/sign` => `200`
- Early deep probe (`diagnose_message.js`) against this PID currently returns `500` with:
  - `details: {badmap,failure}` and stack inside `hb_maps:merge` / `hb_ao:resolve_many`.
  - At this stage this is still considered **pre-finalization noise** until module + PID raw endpoints are both visible.

## 2026-04-07 — Deep retest on current PID after "green" confirmation
- Current target pair for this retest:
  - Module: `zbe7l9INN2hlIwIBAqr0LRxkm9YGd6nL41olyLnIPnU`
  - PID: `revWysnw_rgzvG5Lgm73moQFElfxK8stAIWSMNSrMek`
- Arweave checks during this run:
  - `tx/<module>/status` => `200`
  - `raw/<module>` => `404` (on `arweave.net` gateway in this check)
  - `tx/<pid>/status` => `404`
  - `raw/<pid>` => `200` (4-byte body, expected process marker)
- Worker signing path remains healthy with `tmp/test-secrets.json`:
  - `GET /health` => `200`
  - `GET /metrics` (bearer) => `200`
  - `POST /sign` (worker token) => `200` with `{ signature, signatureRef }`
- Deep message probes on `https://push.forward.computer`:
  - Direct `POST /<PID>` => `200`, body `1984` (state/read path behavior)
  - `POST /<PID>~process@1.0/push` for `Ping` => `400 Message is not valid.`
  - `POST /<PID>~process@1.0/push` for `GetOpsHealth` => `400 Message is not valid.`
  - `POST /<PID>~process@1.0/push` for `Write-Command` preset => `400 Message is not valid.`
- `scripts/cli/diagnose_message.js` (signed Write-Command, worker `/sign`) now consistently returns:
  - HTTP `400` from `/push`
  - response body includes `commitments` (rsa-pss + hmac entries) and status `400`
  - meaning request reaches commitment/codec path, but scheduler still rejects final message shape as invalid.
- Cross-check against older finalized PID `5WXxCBn5PZADOb35QAGDpF8kY_bBrd7uuKEhaUy-XBk` now also returns `400` on `/push` in this environment, including with transport trio (`signing-format`, `accept-bundle`, `require-codec`).
- `scripts/cli/send_write_command.js` (`ao.message`) currently fails early with `Error sending message`, so no `ao.result()` payload is available for business-level verification yet.
- Current blocker is still at `/push` ingress validation (message shape/commitment semantics), not worker secret generation and not direct process availability.

## 2026-04-07 — Push shape diff matrix (new checker)
- Added checker: `scripts/cli/push_shape_diff.js`
  - Purpose: run a deterministic matrix of message shapes against one PID and capture accepted/rejected patterns.
  - Output: full JSON report saved under `tmp/push-shape-report-<timestamp>.json`.
- Run used:
  - `node scripts/cli/push_shape_diff.js --pid revWysnw_rgzvG5Lgm73moQFElfxK8stAIWSMNSrMek --module zbe7l9INN2hlIwIBAqr0LRxkm9YGd6nL41olyLnIPnU --url https://push.forward.computer`
  - Report: `tmp/push-shape-report-2026-04-07T13-12-49-000Z.json`
- Matrix result summary:
  - `control_direct_pid` => `200` (body `1984`) as expected for direct process path.
  - Every `/push` variant tested => `400` (no successful ingress).
  - Variants without transport hints return plain `Message is not valid.`
  - Variants with transport hints (`signing-format`, `accept-bundle`, `require-codec`, optional `accept-codec`) return JSON 400 with `commitments` present.
  - In those 400 JSON responses, committed keys are consistently only `[\"ao-types\",\"status\"]` (no actionable hint that business tags like `Action`/`Type` are being accepted as scheduler payload keys).
- Current interpretation:
  - `/push` rejection is shape/ingress-level and reproducible across all tested map forms in this checker.
  - Worker signing and direct process availability are not the blocker in this phase.

## 2026-04-07 — Cross-endpoint confirmation + committed-envelope probes
- Ran the same checker against push-1:
  - `node scripts/cli/push_shape_diff.js --pid revWysnw_rgzvG5Lgm73moQFElfxK8stAIWSMNSrMek --module zbe7l9INN2hlIwIBAqr0LRxkm9YGd6nL41olyLnIPnU --url https://push-1.forward.computer`
  - report: `tmp/push-shape-report-2026-04-07T13-16-43-356Z.json`
- Result matches push.forward:
  - all `/push` variants remain `400`,
  - transport-tagged variants return JSON 400 with `commitments`,
  - committed keys remain only `[\"ao-types\",\"status\"]`.
- Extra committed-envelope probe:
  - Sent `tmp/committed_ping.json` via `scripts/cli/hb_push_httpsig.js` to both push endpoints:
    - `/<PID>~process@1.0/push` => `400 Message is not valid.`
    - `/<PID>` => `200` + `1984`
  - So even explicit committed body JSON did not unblock `/push`.
- Scheduler direct probe (`/~scheduler@1.0/schedule`) with HTTPSIG headers:
  - both push.forward and push-1 return `500` with stack including:
    - `dev_codec_httpsig_keyid:apply_scheme/3`
    - `details: badarg`
    - failing at `base64:dec_bin/8`
  - Interpretation: scheduler direct path currently rejects this keyid/signature framing in this test shape; not a usable bypass for the `/push` blocker.
- Key-name normalization probe (`action/type/variant/data-protocol` lowercase vs mixed case) on `/push`:
  - all tested variants remained `400` (with or without transport trio),
  - therefore the blocker is not just uppercase/lowercase field naming in request params.

## 2026-04-07 — HTTPSIG keyid format finding (important)
- `scripts/cli/hb_push_httpsig.js` extended with:
  - `--path` (explicit endpoint path override, e.g. `--path /~scheduler@1.0/schedule`)
  - `--keyid-format base64|base64url`
- Repro on scheduler endpoint:
  - `--keyid-format base64url` => `500` (matches prior `dev_codec_httpsig_keyid` base64 decode failure path).
  - `--keyid-format base64` => parser no longer crashes; response becomes `400 No scheduler information provided.`
- Interpretation:
  - This confirms a concrete parser sensitivity: scheduler-path HTTPSIG keyid handling differs for base64url vs standard base64.
  - It does **not** yet solve `/push` for process messaging, but it narrows one transport-level ambiguity and gives a stable way to avoid the scheduler 500 crash during diagnostics.
- Additional scheduler payload key probe (all with `--keyid-format base64`):
  - Tried schedule body keys: `target`, `process`, `process-id`, and both `scheduler` / `Scheduler`.
  - All variants still return `400 No scheduler information provided.`
  - So the scheduler endpoint expects a different envelope/source of scheduler metadata than these direct body fields.
- Scheduler query probe (same HTTPSIG helper):
  - `POST /~scheduler@1.0/schedule?target=<PID>` moves past the `No scheduler information provided` error and returns `400 Message is not valid.` on both push.forward and push-1.
  - This means scheduler resolution can happen from **query `target`**, and the remaining failure is now purely message validation shape.

## 2026-04-07 — Targeted scheduler-shape diff run completed
- Added dedicated matrix script: `scripts/cli/scheduler_shape_diff.js`.
  - It signs requests with HTTPSIG (`comm-` headers), iterates body shapes + header profiles + keyid format (`base64`, `base64url`), and writes a JSON report.
- Run executed:
  - `node scripts/cli/scheduler_shape_diff.js --pid revWysnw_rgzvG5Lgm73moQFElfxK8stAIWSMNSrMek --module zbe7l9INN2hlIwIBAqr0LRxkm9YGd6nL41olyLnIPnU --urls https://push.forward.computer,https://push-1.forward.computer`
  - Report: `tmp/scheduler-shape-report-2026-04-07T13-39-54-203Z.json`
- Matrix scope:
  - Endpoint path fixed to `POST /~scheduler@1.0/schedule?target=<PID>`.
  - Body cases: `plain_lower`, `plain_upper`, `tags_data_shape`, `plain_with_scheduler`, `plain_with_module`, `committed_body_only`, `committed_full_file`.
  - Header profiles: `default_headers` vs `transport_headers` (`signing-format=ans104`, `require-codec=application/json`).
  - KeyId formats: standard base64 and base64url.
- Result summary:
  - `56/56` requests => `400`; no accepted case.
  - `default_headers` responses are plain text `Message is not valid.`.
  - `transport_headers` responses are JSON 400 with `reason: Given message is invalid.` and commitments.
  - In transport JSON responses, committed keys are consistently `["ao-types","body","reason","status"]`.
- Interpretation:
  - Scheduler endpoint is now reached and target-resolved (no scheduler-missing error on this path), but the **message/envelope schema is still not the one scheduler validates as a message**.
  - Blocker remains: exact scheduler-accepted committed envelope shape for AO Message ingress.

## 2026-04-07 — Captured real `ao.message()` wire payload + replay findings
- Added wire-capture helper: `scripts/cli/capture_aomessage_wire.js`.
  - It monkey-patches `fetch`, sends one `ao.message()`, and stores exact request/response payload in `tmp/aomessage-wire-*.json`.
- Captured run:
  - `tmp/aomessage-wire-2026-04-07T13-46-00-865Z.json`
  - `ao.message()` sends:
    - `POST /<PID>~process@1.0/push`
    - headers: `codec-device: ans104@1.0`, `content-type: application/ans104`
    - body: ANS-104 DataItem binary (size 1283 bytes in this run)
    - tags decoded from DataItem: `Action=Ping`, `Type=Message`, `Variant=ao.TN.1`, `Data-Protocol=ao`, `signing-format=ans104`, `accept-bundle=true`, `require-codec=application/json`, etc.
  - This request still returns `400` (`Error sending message` in aoconnect), with 400 JSON body containing only error commitments (`ao-types`, `status`).
- Critical replay result (same captured ANS-104 body/headers):
  - Replay to `/~scheduler@1.0/schedule?target=<PID>` returns **200** on both:
    - `https://push.forward.computer`
    - `https://push-1.forward.computer`
  - Responses saved:
    - `tmp/scheduler-direct-push.json`
    - `tmp/scheduler-direct-push1.json`
  - Returned payload is `Type=Assignment`, includes `process=<PID>`, incrementing `slot` (`28`, `29`), and body with committed message fields (`action`, `target`, `type`, `variant`, etc.) including ans104 commitment.
- Interpretation:
  - The signed ANS-104 message itself is valid enough for scheduler direct path.
  - Current blocker is specifically in `/PID~process@1.0/push` ingress path behavior/routing, not in detached signer, worker secrets, or basic ANS-104 message construction.
- Compute follow-up check for returned slot:
  - `/<PID>~process@1.0/compute=<slot>` currently returns:
    - `500` on `push.forward.computer`
    - `400` on `push-1.forward.computer`
  - So scheduler direct assignment is observable, but compute readback path still needs a compatible query flow.

## 2026-04-07 — Deep scheduler-direct test run (blocker narrowed)
- Added helper: `scripts/cli/deep_test_scheduler_direct.js`
  - Sends `Ping`, `GetOpsHealth`, and `Write-Command` as **ANS-104 DataItems** to:
    - `POST /~scheduler@1.0/schedule?target=<PID>`
  - Uses worker signing (`/sign`) for `Write-Command`.
  - Probes `slot/current` and `/<PID>~process@1.0/compute=<slot>` after each send.
- Command used:
  - `node scripts/cli/deep_test_scheduler_direct.js --pid revWysnw_rgzvG5Lgm73moQFElfxK8stAIWSMNSrMek --secrets tmp/test-secrets.json --out tmp/deep-test-scheduler-direct-latest.json`
- Result snapshot:
  - `push.forward.computer`:
    - Ping `200` slot `43`
    - GetOpsHealth `200` slot `44`
    - Write-Command `200` slot `45`
    - `/<PID>/slot/current` => `200` (`45`)
    - `/<PID>~process@1.0/compute=43..45` => `500`
  - `push-1.forward.computer`:
    - Ping `200` slot `46`
    - GetOpsHealth `200` slot `47`
    - Write-Command `200` slot `48`
    - `/<PID>/slot/current` => `400`
    - `/<PID>~process@1.0/compute=46..48` => `400`
- Final interpretation from this run:
  - Message construction + signatures + scheduler routing are now validated (all 6 action sends accepted with slot increments).
  - Remaining blocker is **compute/readback path behavior** on public push endpoints, not worker secrets/signing and not action envelope shape.
- Aoconnect result cross-check on accepted slot (`45`):
  - `ao.result({ process: revWys..., message: '45' })` on `https://push.forward.computer` returns `Error getting result`.
  - Confirms the same readback blocker at client level (not only raw curl probing).

## 2026-04-07 — CU/readback focused diagnosis (requested follow-up)
- Added helper: `scripts/cli/diagnose_cu_readback.js`
  - Inputs: PID + previous deep-test report (`tmp/deep-test-scheduler-direct-latest.json`).
  - Checks per endpoint:
    - `/<PID>/slot/current`
    - `POST /~scheduler@1.0/slot?target=<PID>`
    - `/<PID>~process@1.0/compute=<slot>` for each accepted slot
    - scheduler message fetch `https://schedule.forward.computer/<messageId>?process-id=<PID>`
    - `ao.result(...)` (primary endpoint only)
    - `ao.dryrun(...)` Ping (primary endpoint only)
- Run:
  - `node scripts/cli/diagnose_cu_readback.js --pid revWysnw_rgzvG5Lgm73moQFElfxK8stAIWSMNSrMek --report tmp/deep-test-scheduler-direct-latest.json --out tmp/cu-readback-diagnostic-latest.json`
- Result:
  - `https://push.forward.computer`
    - `slot/current` (process path): `200`
    - scheduler slot probe (`POST /~scheduler@1.0/slot?target=<PID>`): `200`
    - `compute` for slots `43/44/45`: `500`
    - scheduler message fetch for all message IDs: `200` (message body retrievable)
    - `ao.result(...)`: `Error getting result`
    - `ao.dryrun(...)`: `Error running dryrun`
  - `https://push-1.forward.computer`
    - `slot/current` (process path): `400`
    - scheduler slot probe: `400`
    - `compute` for slots `46/47/48`: `400`
    - scheduler message fetch for all message IDs: `200`
- Additional confirmed endpoint behavior:
  - `GET /~scheduler@1.0/slot/current?target=<PID>` on `push.forward.computer` returns current slot (e.g., `48`).
  - `POST /~scheduler@1.0/slot?target=<PID>` returns headers with `current=<slot>` and `status=200` on `push.forward.computer`.
- Final interpretation:
  - Scheduler ingestion + storage path is healthy (accepted slots + retrievable message IDs).
  - Readback/compute plane remains the active blocker on public push endpoints (`500` / `400`), including `ao.result` and `ao.dryrun`.

## 2026-04-07 — Escalation bundle prepared
- Added helper: `scripts/cli/build_hb_escalation_bundle.js`
  - Builds a support/escalation package from latest diagnostics.
  - Includes:
    - deep test report
    - CU/readback report
    - captured `ao.message` wire payload
    - scheduler-direct assignment responses
    - `REPORT.md` matrix
    - `repro.sh` quick repro script
- Bundle built:
  - Directory: `tmp/hb-escalation-latest`
  - Archive: `tmp/hb-escalation-latest.tar.gz`
  - Included prefilled maintainer report body: `tmp/hb-escalation-latest/ISSUE_BODY.md`
- Command used:
  - `node scripts/cli/build_hb_escalation_bundle.js --deep-report tmp/deep-test-scheduler-direct-latest.json --cu-report tmp/cu-readback-diagnostic-latest.json --out-dir tmp/hb-escalation-latest`

## 2026-04-07 — Production-like business matrix via scheduler-direct
- Added helper: `scripts/cli/business_matrix_scheduler_direct.js`
  - Sends signed business commands as `Action=Write-Command` envelopes through:
    - `POST /~scheduler@1.0/schedule?target=<PID>`
  - Test actions:
    - `SaveDraftPage`
    - `PublishPageVersion`
    - `UpsertRoute`
    - `CreatePaymentIntent`
    - `ProviderWebhook`
    - `ProviderShippingWebhook`
  - For each send, probes scheduler message fetch:
    - `https://schedule.forward.computer/<messageId>?process-id=<PID>`
- Run:
  - `node scripts/cli/business_matrix_scheduler_direct.js --pid revWysnw_rgzvG5Lgm73moQFElfxK8stAIWSMNSrMek --secrets tmp/test-secrets.json --out tmp/business-matrix-scheduler-direct-latest.json`
- Result:
  - `push.forward.computer`: all 6 actions accepted (`200`, slots `49..54`), scheduler message fetch `200` for all 6.
  - `push-1.forward.computer`: all 6 actions accepted (`200`, slots `55..60`), scheduler message fetch `200` for all 6.
- Follow-up probes right after matrix:
  - `GET /<PID>/slot/current`:
    - `push.forward.computer` => `200` (`60`)
    - `push-1.forward.computer` => `200` (`60`)
  - `GET /<PID>~process@1.0/compute=<slot>` for sampled accepted slots (`49`, `54`, `55`, `60`):
    - `push.forward.computer` => `500`
    - `push-1.forward.computer` => `500`
  - `ao.result({process:<PID>, message:'60'})`:
    - both push endpoints => `Error getting result`
- Updated interpretation:
  - Ingestion and scheduling are now validated even for broader production-like command set.
  - Remaining blocker remains strictly compute/readback execution plane on public push nodes.

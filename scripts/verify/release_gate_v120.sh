#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT_DIR"

DEFAULT_URLS="https://push.forward.computer"
PID="${AO_PID:-}"
URLS="${AO_URLS:-${HB_URLS:-$DEFAULT_URLS}}"
SECRETS_PATH="${AO_SECRETS_PATH:-${SECRETS_PATH:-tmp/test-secrets.json}}"
WALLET_PATH="${AO_WALLET_PATH:-${WALLET_PATH:-wallet.json}}"
STRICT="${RELEASE_GATE_STRICT:-${STRICT:-0}}"

usage() {
  cat <<'EOF'
Usage:
  scripts/verify/release_gate_v120.sh --pid <pid> --urls <url1,url2> --secrets <path> [--strict]

Env mirrors the flags:
  AO_PID, AO_URLS or HB_URLS, AO_SECRETS_PATH or SECRETS_PATH, AO_WALLET_PATH or WALLET_PATH, RELEASE_GATE_STRICT or STRICT

Notes:
  - URL lists are comma-separated.
  - Default URL is https://push.forward.computer.
  - --strict expands the AO readback assertions to every URL you pass.
EOF
}

trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

join_by_comma() {
  local out=""
  local item
  for item in "$@"; do
    if [ -z "$out" ]; then
      out="$item"
    else
      out="$out,$item"
    fi
  done
  printf '%s' "$out"
}

run_phase() {
  local label="$1"
  shift
  echo
  echo "==> $label"
  if "$@"; then
    PHASE_LOG+=("$label|ok")
    echo "[ok] $label"
  else
    PHASE_LOG+=("$label|fail")
    echo "[fail] $label" >&2
    return 1
  fi
}

check_write_bundle_freshness() {
  local bundle="dist/write-bundle.lua"
  if [ ! -f "$bundle" ]; then
    echo "[bundle] missing $bundle" >&2
    echo "[bundle] run: node scripts/build-write-bundle.js" >&2
    return 1
  fi

  local stale=0
  local path
  for path in ao/write/process.lua ao/templates.lua; do
    if [ "$path" -nt "$bundle" ]; then
      echo "[bundle] stale: $path is newer than $bundle" >&2
      stale=1
    fi
  done

  while IFS= read -r path; do
    [ -z "$path" ] && continue
    echo "[bundle] stale: $path is newer than $bundle" >&2
    stale=1
  done < <(find ao/shared -type f -name '*.lua' -newer "$bundle" -print 2>/dev/null | sort)

  if [ "$stale" -ne 0 ]; then
    echo "[bundle] run: node scripts/build-write-bundle.js" >&2
    return 1
  fi
  return 0
}

assert_deep_report() {
  local report_path="$1"
  local strict_mode="$2"
  local expected_url_count="$3"
  node - "$report_path" "$strict_mode" "$expected_url_count" <<'NODE'
const fs = require('fs')
const reportPath = process.argv[2]
const strictMode = process.argv[3] === '1'
const expectedUrlCount = Number(process.argv[4])

function fail(msg) {
  console.error(`[deep-test] ${msg}`)
  process.exit(1)
}

const report = JSON.parse(fs.readFileSync(reportPath, 'utf8'))
if (!Array.isArray(report.steps)) fail('missing steps array')
if (report.steps.length !== expectedUrlCount) {
  fail(`expected ${expectedUrlCount} step(s), got ${report.steps.length}`)
}

const expectedActions = ['Ping', 'GetOpsHealth', 'RuntimeSignal']

for (const [index, step] of report.steps.entries()) {
  const label = step.baseUrl || `step-${index}`
  if (!Array.isArray(step.sends) || step.sends.length !== expectedActions.length) {
    fail(`${label}: expected ${expectedActions.length} sends`)
  }
  if (!step.slotCurrent || step.slotCurrent.status !== 200) {
    fail(`${label}: slot/current status must be 200`)
  }
  expectedActions.forEach((action, actionIndex) => {
    const send = step.sends[actionIndex]
    if (send.action !== action) fail(`${label}: expected action ${action}, got ${send.action}`)
    if (send.status !== 200) fail(`${label}: ${action} status must be 200`)
    if (!send.headers || !Number.isFinite(Number(send.headers.slot || ''))) {
      fail(`${label}: ${action} missing numeric slot header`)
    }
    if (send.parsedAction && send.parsedAction !== action && send.parsedAction !== 'Write-Command') {
      fail(`${label}: ${action} echo mismatch (${send.parsedAction})`)
    }
    if (strictMode) {
      const cmp = Array.isArray(step.computeChecks) ? step.computeChecks[actionIndex] : null
      if (!cmp || cmp.status !== 200) fail(`${label}: ${action} compute status must be 200`)
      if (!cmp.parsed || cmp.parsed.hasError) fail(`${label}: ${action} compute returned an error`)
      if (!cmp.parsed.hasResults) fail(`${label}: ${action} compute missing results`)
    }
  })
}

console.log(`[deep-test] ok for ${report.steps.length} URL(s)`)
NODE
}

assert_diag_report() {
  local report_path="$1"
  local strict_mode="$2"
  node - "$report_path" "$strict_mode" <<'NODE'
const fs = require('fs')
const reportPath = process.argv[2]
const strictMode = process.argv[3] === '1'

function fail(msg) {
  console.error(`[readback] ${msg}`)
  process.exit(1)
}

const report = JSON.parse(fs.readFileSync(reportPath, 'utf8'))
if (!Array.isArray(report.steps) || report.steps.length === 0) fail('missing steps array')
const expectedActions = ['Ping', 'GetOpsHealth', 'RuntimeSignal']

for (const [index, step] of report.steps.entries()) {
  const label = step.baseUrl || `step-${index}`
  const probes = step.probes || {}
  if (!Array.isArray(step.sends) || step.sends.length !== expectedActions.length) {
    fail(`${label}: expected ${expectedActions.length} sends`)
  }
  if (!probes.slotCurrentViaProcess || probes.slotCurrentViaProcess.status !== 200) {
    fail(`${label}: process slot/current must be 200`)
  }
  if (!probes.slotCurrentViaScheduler || probes.slotCurrentViaScheduler.status !== 200) {
    fail(`${label}: scheduler slot/current must be 200`)
  }
  if (!probes.aoconnectDryrunPing || probes.aoconnectDryrunPing.ok !== true) {
    const mode = strictMode ? 'strict' : 'non-strict'
    console.log(`${label}: note: aoconnect dryrun Ping unavailable (${mode} mode)`)
  }

  step.sends.forEach((send, actionIndex) => {
    const action = send.action || 'unknown'
    if (send.action !== expectedActions[actionIndex]) {
      fail(`${label}: expected action ${expectedActions[actionIndex]}, got ${send.action}`)
    }
    if (!send.schedulerMessageProbe || send.schedulerMessageProbe.status !== 200) {
      fail(`${label}: ${action} scheduler message probe must be 200`)
    }
    if (strictMode) {
      if (!send.computeProbe || send.computeProbe.status !== 200) {
        fail(`${label}: ${action} compute probe must be 200`)
      }
      if (send.aoconnectResultProbe && send.aoconnectResultProbe.ok !== true) {
        fail(`${label}: ${action} ao.result probe must succeed when available`)
      }
      if (!send.aoconnectResultProbe) {
        console.log(`${label}: note: ${action} ao.result probe unavailable on this URL`)
      }
    }
  })
}

console.log(`[readback] ok for ${report.steps.length} URL(s)`)
NODE
}

filter_primary_report() {
  local src="$1"
  local dst="$2"
  node - "$src" "$dst" <<'NODE'
const fs = require('fs')
const src = process.argv[2]
const dst = process.argv[3]
const report = JSON.parse(fs.readFileSync(src, 'utf8'))
const steps = Array.isArray(report.steps) && report.steps.length > 0 ? [report.steps[0]] : []
fs.writeFileSync(dst, JSON.stringify({ ...report, steps }, null, 2))
NODE
}

resolve_tool() {
  local name="$1"
  if command -v "$name" >/dev/null 2>&1; then
    command -v "$name"
    return 0
  fi
  local d
  for d in "$HOME/.luarocks/bin" "$HOME/.local/bin"; do
    if [ -x "$d/$name" ]; then
      printf '%s\n' "$d/$name"
      return 0
    fi
  done
  return 1
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  usage
  exit 0
fi

while (($#)); do
  case "$1" in
    --pid)
      PID="${2:-}"
      shift 2
      ;;
    --urls)
      URLS="${2:-}"
      shift 2
      ;;
    --secrets)
      SECRETS_PATH="${2:-}"
      shift 2
      ;;
    --wallet)
      WALLET_PATH="${2:-}"
      shift 2
      ;;
    --strict)
      STRICT=1
      shift
      ;;
    *)
      echo "Unknown arg: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

PID="$(trim "$PID")"
URLS="$(trim "$URLS")"
SECRETS_PATH="$(trim "$SECRETS_PATH")"
WALLET_PATH="$(trim "$WALLET_PATH")"
STRICT="$(trim "$STRICT")"

if [ -z "$PID" ]; then
  echo "PID is required" >&2
  usage >&2
  exit 2
fi
if [ -z "$URLS" ]; then
  echo "At least one URL is required" >&2
  usage >&2
  exit 2
fi
if [ ! -f "$SECRETS_PATH" ]; then
  echo "Secrets file not found: $SECRETS_PATH" >&2
  exit 2
fi
if [ ! -f "$WALLET_PATH" ]; then
  echo "Wallet file not found: $WALLET_PATH" >&2
  exit 2
fi

for tool in node lua5.4 luarocks python3; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "Missing required tool: $tool" >&2
    exit 1
  fi
done

LUACHECK_BIN="$(resolve_tool luacheck || true)"
STYLUA_BIN="$(resolve_tool stylua || true)"
if [ -z "$LUACHECK_BIN" ]; then
  echo "Missing required tool: luacheck" >&2
  exit 1
fi
if [ -z "$STYLUA_BIN" ]; then
  echo "Missing required tool: stylua" >&2
  exit 1
fi

IFS=',' read -r -a URL_LIST <<< "$URLS"
NORMALIZED_URLS=()
for raw_url in "${URL_LIST[@]}"; do
  url="$(trim "$raw_url")"
  url="${url%/}"
  if [ -n "$url" ]; then
    NORMALIZED_URLS+=("$url")
  fi
done

if [ "${#NORMALIZED_URLS[@]}" -eq 0 ]; then
  echo "No usable URLs found in: $URLS" >&2
  exit 2
fi

URLS="$(join_by_comma "${NORMALIZED_URLS[@]}")"

EXTRA_PATH=""
for d in "$HOME/.luarocks/bin" "$HOME/.local/bin"; do
  if [ -d "$d" ]; then
    if [ -z "$EXTRA_PATH" ]; then
      EXTRA_PATH="$d"
    else
      EXTRA_PATH="$EXTRA_PATH:$d"
    fi
  fi
done
if [ -n "$EXTRA_PATH" ]; then
  PATH="$EXTRA_PATH:$PATH"
fi

ROCKS_LUA_PATH="$(luarocks --lua-version=5.4 path --lr-path 2>/dev/null || true)"
ROCKS_LUA_CPATH="$(luarocks --lua-version=5.4 path --lr-cpath 2>/dev/null || true)"
LUA_PATH_VALUE="?.lua;?/init.lua;ao/?.lua;ao/?/init.lua"
if [ -n "$ROCKS_LUA_PATH" ]; then
  LUA_PATH_VALUE="$LUA_PATH_VALUE;$ROCKS_LUA_PATH"
fi

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/blackcat-write-gate.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

PHASE_LOG=()

COMMON_ENV=(
  PATH="${PATH:-/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin}"
  HOME="${HOME:-$ROOT_DIR}"
  LANG="${LANG:-C}"
  LC_ALL="${LC_ALL:-C}"
  TZ=UTC
)

LUA_ENV=(
  LUA_PATH="$LUA_PATH_VALUE"
  LUA_CPATH="$ROCKS_LUA_CPATH"
)

CI_SIGNATURE_ENV=(
  WRITE_REQUIRE_SIGNATURE=1
  WRITE_SIG_TYPE=ed25519
  WRITE_SIG_PRIV_HEX=4f3c5f2a0d1b4a8c9e6f7d2b3c4e5a6f7b1c2d3e4f5a6b7c8d9e0f1a2b3c4d5e
  WRITE_SIG_PUBLIC=hex:65c29ed7228fce639284da05d84fbc37ef736c44ddec2ce53226033c80312ace
  WRITE_SIG_REF=write-ed25519-test
  OUTBOX_HMAC_SECRET=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
  WRITE_REQUIRE_NONCE=0
  WRITE_REQUIRE_TIMESTAMP=0
  WRITE_REQUIRE_JWT=0
  WRITE_RL_MAX_REQUESTS=100000
  WRITE_RL_CALLER_MAX=100000
)

CI_RELAXED_ENV=(
  WRITE_REQUIRE_SIGNATURE=0
  WRITE_REQUIRE_NONCE=0
  WRITE_REQUIRE_TIMESTAMP=0
  WRITE_REQUIRE_JWT=0
  WRITE_RL_MAX_REQUESTS=100000
  WRITE_RL_CALLER_MAX=100000
)

DEEP_REPORT="$TMP_DIR/deep-test-report.json"
DIAG_INPUT="$TMP_DIR/diagnose-input.json"
DIAG_REPORT="$TMP_DIR/diagnose-report.json"
SUMMARY_PRINTED=0

print_summary() {
  local exit_code="$1"
  if [ "$SUMMARY_PRINTED" -eq 1 ]; then
    return
  fi
  SUMMARY_PRINTED=1
  echo
  echo "==> Summary"
  if [ "$exit_code" -eq 0 ]; then
    printf '  status: PASS\n'
  else
    printf '  status: FAIL (exit %s)\n' "$exit_code"
  fi
  printf '  pid: %s\n' "$PID"
  printf '  urls: %s\n' "$URLS"
  printf '  strict: %s\n' "$STRICT"
  printf '  wallet: %s\n' "$WALLET_PATH"
  printf '  secrets: %s\n' "$SECRETS_PATH"
  printf '  reports: %s %s %s\n' "$DEEP_REPORT" "$DIAG_INPUT" "$DIAG_REPORT"
  printf '  phases: %s\n' "${#PHASE_LOG[@]}"
  local entry
  for entry in "${PHASE_LOG[@]}"; do
    printf '    - %s\n' "${entry//|/ : }"
  done
}

trap 'code=$?; print_summary "$code"; rm -rf "$TMP_DIR"' EXIT

if ! run_phase "Static: write bundle freshness" check_write_bundle_freshness; then
  exit 1
fi

if ! run_phase "Static: preflight" env -i "${COMMON_ENV[@]}" \
  RUN_BATCH=1 \
  RUN_DEPS_CHECK=1 \
  RUN_SCHEMA_MANIFEST=1 \
  WRITE_REQUIRE_SIGNATURE=1 \
  bash scripts/verify/preflight.sh; then
  exit 1
fi

if ! run_phase "Static: luacheck" env -i "${COMMON_ENV[@]}" \
  "$LUACHECK_BIN" ao scripts; then
  exit 1
fi

if ! run_phase "Static: stylua" env -i "${COMMON_ENV[@]}" \
  "$STYLUA_BIN" --check ao scripts; then
  exit 1
fi

if ! run_phase "Verify: ingest_smoke" env -i "${COMMON_ENV[@]}" "${LUA_ENV[@]}" "${CI_SIGNATURE_ENV[@]}" \
  lua5.4 scripts/verify/ingest_smoke.lua; then
  exit 1
fi

if ! run_phase "Verify: envelope_guard" env -i "${COMMON_ENV[@]}" "${LUA_ENV[@]}" "${CI_SIGNATURE_ENV[@]}" \
  lua5.4 scripts/verify/envelope_guard.lua; then
  exit 1
fi

if ! run_phase "Verify: action_validation" env -i "${COMMON_ENV[@]}" "${LUA_ENV[@]}" "${CI_SIGNATURE_ENV[@]}" \
  lua5.4 scripts/verify/action_validation.lua; then
  exit 1
fi

if ! run_phase "Verify: action_validation_shipping" env -i "${COMMON_ENV[@]}" "${LUA_ENV[@]}" "${CI_RELAXED_ENV[@]}" \
  lua5.4 scripts/verify/action_validation_shipping.lua; then
  exit 1
fi

if ! run_phase "Verify: publish_flow" env -i "${COMMON_ENV[@]}" "${LUA_ENV[@]}" "${CI_RELAXED_ENV[@]}" \
  lua5.4 scripts/verify/publish_flow.lua; then
  exit 1
fi

if ! run_phase "Verify: idempotency_replay" env -i "${COMMON_ENV[@]}" "${LUA_ENV[@]}" "${CI_RELAXED_ENV[@]}" \
  lua5.4 scripts/verify/idempotency_replay.lua; then
  exit 1
fi

if ! run_phase "Verify: conflicts" env -i "${COMMON_ENV[@]}" "${LUA_ENV[@]}" "${CI_RELAXED_ENV[@]}" \
  lua5.4 scripts/verify/conflicts.lua; then
  exit 1
fi

if ! run_phase "Verify: publish_outbox_mock_ao" env -i "${COMMON_ENV[@]}" "${LUA_ENV[@]}" "${CI_RELAXED_ENV[@]}" \
  OUTBOX_HMAC_SECRET=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef \
  lua5.4 scripts/verify/publish_outbox_mock_ao.lua; then
  exit 1
fi

DEEP_CMD=(
  node scripts/cli/deep_test_scheduler_direct.js
  --pid "$PID"
  --urls "$URLS"
  --secrets "$SECRETS_PATH"
  --wallet "$WALLET_PATH"
  --out "$DEEP_REPORT"
)
if [ "$STRICT" = "1" ]; then
  DEEP_CMD+=(--execution-mode strict)
fi

if ! run_phase "AO deep: scheduler direct" env -i "${COMMON_ENV[@]}" \
  "${DEEP_CMD[@]}"; then
  exit 1
fi

if ! assert_deep_report "$DEEP_REPORT" "$STRICT" "${#NORMALIZED_URLS[@]}"; then
  exit 1
fi

if [ "$STRICT" = "1" ]; then
  cp "$DEEP_REPORT" "$DIAG_INPUT"
else
  filter_primary_report "$DEEP_REPORT" "$DIAG_INPUT"
fi

if ! run_phase "AO deep: cu readback" env -i "${COMMON_ENV[@]}" \
  node scripts/cli/diagnose_cu_readback.js \
  --pid "$PID" \
  --report "$DIAG_INPUT" \
  --wallet "$WALLET_PATH" \
  --out "$DIAG_REPORT"; then
  exit 1
fi

if ! assert_diag_report "$DIAG_REPORT" "$STRICT"; then
  exit 1
fi

print_summary 0

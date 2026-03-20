#!/usr/bin/env bash
# Lightweight preflight checks for the write repo.
# - validates JSON schemas are well-formed
# - ensures Lua sources have no syntax errors

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
export ROOT_DIR

echo "[verify] JSON schemas"
python3 - <<'PY'
import json
import os
from pathlib import Path

root = Path(os.environ["ROOT_DIR"])
schemas = sorted((root / "schemas").glob("*.json"))
if not schemas:
    raise SystemExit("No schemas found under schemas/")

for path in schemas:
    with path.open("r", encoding="utf-8") as f:
        json.load(f)
    print(f"  ✓ {path.relative_to(root)}")
PY

echo "[verify] Lua syntax"

lua_runner=()
if command -v luac >/dev/null 2>&1; then
  lua_runner=(luac -p)
elif command -v lua5.4 >/dev/null 2>&1; then
  lua_runner=(lua5.4 -e "assert(loadfile(arg[1]))")
elif command -v lua >/dev/null 2>&1; then
  lua_runner=(lua -e "assert(loadfile(arg[1]))")
fi

if [ ${#lua_runner[@]} -eq 0 ]; then
  echo "Lua interpreter/compiler not found. Install lua5.4 (or luac) to run syntax checks." >&2
  exit 1
fi

find "$ROOT_DIR/ao" -name '*.lua' -print -exec "${lua_runner[@]}" {} \;

echo "[verify] done"

# optional contract smoke tests
if command -v lua5.4 >/dev/null 2>&1; then
  # capture luarocks paths (Lua 5.4) so optional deps can be resolved
  ROCKS_LUA_PATH=$(luarocks --lua-version=5.4 path --lr-path 2>/dev/null || true)
  ROCKS_LUA_CPATH=$(luarocks --lua-version=5.4 path --lr-cpath 2>/dev/null || true)

  if [ "${RUN_DEPS_CHECK:-0}" -eq 1 ]; then
    echo "[verify] deps check"
    LUA_PATH="?.lua;?/init.lua;ao/?.lua;ao/?/init.lua;${ROCKS_LUA_PATH}" \
    LUA_CPATH="${ROCKS_LUA_CPATH}" \
      lua5.4 "$ROOT_DIR/scripts/verify/deps_check.lua"
  fi
  if [ "${RUN_CONTRACTS:-1}" -eq 1 ]; then
    echo "[verify] contract smoke tests"
    WRITE_REQUIRE_NONCE=0 \
    WRITE_REQUIRE_TIMESTAMP=0 \
    WRITE_REQUIRE_SIGNATURE=0 \
    WRITE_REQUIRE_JWT=0 \
    WRITE_RL_MAX_REQUESTS=100000 \
    WRITE_RL_CALLER_MAX=100000 \
    ALLOW_DEV_JWT=1 \
    RUN_CONTRACTS=1 \
    LUA_PATH="?.lua;?/init.lua;ao/?.lua;ao/?/init.lua;${ROCKS_LUA_PATH}" \
    LUA_CPATH="${ROCKS_LUA_CPATH}" \
      lua5.4 "$ROOT_DIR/scripts/verify/contracts.lua"
  fi
  if [ "${RUN_CONFLICTS:-1}" -eq 1 ]; then
    echo "[verify] conflict/security tests"
    WRITE_REQUIRE_NONCE=0 \
    WRITE_REQUIRE_TIMESTAMP=0 \
    WRITE_REQUIRE_SIGNATURE=0 \
    WRITE_REQUIRE_JWT=0 \
    WRITE_RL_MAX_REQUESTS=100000 \
    WRITE_RL_CALLER_MAX=100000 \
    ALLOW_DEV_JWT=1 \
    RUN_CONTRACTS=1 \
    LUA_PATH="?.lua;?/init.lua;ao/?.lua;ao/?/init.lua;${ROCKS_LUA_PATH}" \
    LUA_CPATH="${ROCKS_LUA_CPATH}" \
      lua5.4 "$ROOT_DIR/scripts/verify/conflicts.lua"
  fi
  if [ "${RUN_SCHEMA_CONSISTENCY:-1}" -eq 1 ]; then
    echo "[verify] schema/handler consistency"
    LUA_PATH="?.lua;?/init.lua;ao/?.lua;ao/?/init.lua;${ROCKS_LUA_PATH}" \
    LUA_CPATH="${ROCKS_LUA_CPATH}" \
      lua5.4 "$ROOT_DIR/scripts/verify/schema_consistency.lua"
  fi
  if [ "${RUN_GOPAY_SPEC:-1}" -eq 1 ]; then
    echo "[verify] gopay webhook spec"
    WRITE_REQUIRE_NONCE=0 \
    WRITE_REQUIRE_TIMESTAMP=0 \
    WRITE_REQUIRE_SIGNATURE=0 \
    WRITE_REQUIRE_JWT=0 \
    GOPAY_WEBHOOK_SECRET="${GOPAY_WEBHOOK_SECRET:-}" \
    LUA_PATH="?.lua;?/init.lua;ao/?.lua;ao/?/init.lua;${ROCKS_LUA_PATH}" \
    LUA_CPATH="${ROCKS_LUA_CPATH}" \
      lua5.4 "$ROOT_DIR/scripts/verify/gopay_webhook_spec.lua"
  fi
  if [ "${RUN_PSP_WEBHOOK_SPEC:-1}" -eq 1 ]; then
    echo "[verify] psp webhook spec"
    WRITE_REQUIRE_NONCE=0 \
    WRITE_REQUIRE_TIMESTAMP=0 \
    WRITE_REQUIRE_SIGNATURE=0 \
    WRITE_REQUIRE_JWT=0 \
    LUA_PATH="?.lua;?/init.lua;ao/?.lua;ao/?/init.lua;${ROCKS_LUA_PATH}" \
    LUA_CPATH="${ROCKS_LUA_CPATH}" \
      lua5.4 "$ROOT_DIR/scripts/verify/webhook_psp_spec.lua"
  fi
  if [ "${RUN_IDEM_PROPERTY:-1}" -eq 1 ]; then
    echo "[verify] idempotency property test"
    WRITE_REQUIRE_SIGNATURE=0 \
    WRITE_REQUIRE_TIMESTAMP=0 \
    WRITE_REQUIRE_NONCE=0 \
    WRITE_REQUIRE_JWT=0 \
    LUA_PATH="?.lua;?/init.lua;ao/?.lua;ao/?/init.lua;${ROCKS_LUA_PATH}" \
    LUA_CPATH="${ROCKS_LUA_CPATH}" \
      lua5.4 "$ROOT_DIR/scripts/verify/idempotency_property.lua"
  fi
  if [ -n "${WRITE_IDEM_PATH:-}" ]; then
    echo "[verify] idempotency persistence"
    LUA_PATH="?.lua;?/init.lua;ao/?.lua;ao/?/init.lua" lua5.4 - <<'LUA'
local idem = require("ao.shared.idempotency")
local write = require("ao.write.process")
local tmp = os.getenv("WRITE_IDEM_PATH")
local cmd = { action = "SaveDraftPage", requestId = "rid-persist-1", actor = "a", tenant = "t", role = "admin", timestamp = "2026-03-15T00:00:00Z", nonce = "nonce-persist-1", signatureRef = "sigref-persist-1", payload = { siteId = "s", pageId = "p", locale = "en", blocks = {} } }
write.route(cmd)
package.loaded["ao.write.process"] = nil
package.loaded["ao.shared.idempotency"] = nil
local idem2 = require("ao.shared.idempotency")
local resp = idem2.lookup("rid-persist-1")
if not resp or resp.status ~= "OK" then error("persisted idempotency missing") end
os.remove(tmp)
LUA
  fi
  if [ -n "${WRITE_OUTBOX_PATH:-}" ]; then
    echo "[verify] outbox persistence"
    LUA_PATH="?.lua;?/init.lua;ao/?.lua;ao/?/init.lua" lua5.4 - <<'LUA'
local write = require("ao.write.process")
local tmp = os.getenv("WRITE_OUTBOX_PATH")
write.route({ action = "PublishPageVersion", requestId = "rid-outbox-1", actor = "a", tenant = "t", role = "publisher", timestamp = "2026-03-15T00:00:00Z", nonce = "nonce-outbox-1", signatureRef = "sigref-outbox-1", payload = { siteId = "s", pageId = "p", versionId = "v1", manifestTx = "tx1" } })
package.loaded["ao.write.process"] = nil
local storage = require("ao.shared.storage")
storage.load(tmp)
local events = storage.all("outbox")
if #events == 0 then error("outbox persistence missing") end
os.remove(tmp)
LUA
  fi
  if [ "${RUN_BATCH:-1}" -eq 1 ]; then
    echo "[verify] fixtures batch run"
    WRITE_REQUIRE_NONCE=0 \
    WRITE_REQUIRE_TIMESTAMP=0 \
    WRITE_REQUIRE_SIGNATURE=0 \
    WRITE_REQUIRE_JWT=0 \
    WRITE_RL_MAX_REQUESTS=100000 \
    WRITE_RL_CALLER_MAX=100000 \
    ALLOW_DEV_JWT=1 \
    LUA_PATH="?.lua;?/init.lua;ao/?.lua;ao/?/init.lua;${ROCKS_LUA_PATH}" \
    LUA_CPATH="${ROCKS_LUA_CPATH}" \
      lua5.4 "$ROOT_DIR/scripts/cli/batch_run.lua"
  fi
  if [ "${RUN_RATE_SPEC:-0}" -eq 1 ]; then
    echo "[verify] rate store persistence"
    WRITE_RATE_STORE_PATH="${WRITE_RATE_STORE_PATH:-dev/write-rate-store.json}" \
    LUA_PATH="?.lua;?/init.lua;ao/?.lua;ao/?/init.lua;${ROCKS_LUA_PATH}" \
    LUA_CPATH="${ROCKS_LUA_CPATH}" \
      lua5.4 "$ROOT_DIR/scripts/verify/rate_store_spec.lua"
    echo "[verify] tenant-scoped rate limits"
    LUA_PATH="?.lua;?/init.lua;ao/?.lua;ao/?/init.lua;${ROCKS_LUA_PATH}" \
    LUA_CPATH="${ROCKS_LUA_CPATH}" \
      lua5.4 "$ROOT_DIR/scripts/verify/rate_tenant_scope_spec.lua"
    echo "[verify] nonce persistence"
    WRITE_NONCE_STORE_PATH="${WRITE_NONCE_STORE_PATH:-dev/write-nonce-store.json}" \
    LUA_PATH="?.lua;?/init.lua;ao/?.lua;ao/?/init.lua;${ROCKS_LUA_PATH}" \
    LUA_CPATH="${ROCKS_LUA_CPATH}" \
      lua5.4 "$ROOT_DIR/scripts/verify/nonce_persist_spec.lua"
  fi
  if [ "${RUN_JWT_SPEC:-0}" -eq 1 ]; then
    echo "[verify] jwt actor mapping"
    WRITE_REQUIRE_JWT=1 WRITE_JWT_HS_SECRET="${WRITE_JWT_HS_SECRET:-dev-secret}" \
      LUA_PATH="?.lua;?/init.lua;ao/?.lua;ao/?/init.lua;${ROCKS_LUA_PATH}" \
      LUA_CPATH="${ROCKS_LUA_CPATH}" \
      lua5.4 "$ROOT_DIR/scripts/verify/jwt_actor_spec.lua"
    echo "[verify] jwt expiry/consistency"
    WRITE_REQUIRE_JWT=1 WRITE_JWT_HS_SECRET="${WRITE_JWT_HS_SECRET:-dev-secret}" \
      LUA_PATH="?.lua;?/init.lua;ao/?.lua;ao/?/init.lua;${ROCKS_LUA_PATH}" \
      LUA_CPATH="${ROCKS_LUA_CPATH}" \
      lua5.4 "$ROOT_DIR/scripts/verify/jwt_expiry_spec.lua"
  fi
  if [ "${RUN_CHECKSUM_ALERT:-0}" -eq 1 ]; then
    echo "[verify] checksum alert"
    WRITE_WAL_PATH="${WRITE_WAL_PATH:-dev/write-wal.ndjson}" \
    AO_QUEUE_PATH="${AO_QUEUE_PATH:-dev/outbox-queue.ndjson}" \
    LUA_PATH="?.lua;?/init.lua;ao/?.lua;ao/?/init.lua" \
    "$ROOT_DIR/scripts/verify/checksum_alert.sh"
  fi
fi

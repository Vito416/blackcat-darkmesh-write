-- Verify nonce persistence across restarts and TTL expiry (optional).
-- Requires WRITE_NONCE_STORE_PATH set before invoking this script.

local path = os.getenv("WRITE_NONCE_STORE_PATH") or "dev/write-nonce-store.json"
assert(path ~= "", "WRITE_NONCE_STORE_PATH is required for nonce_persist_spec")

-- cleanup previous state
os.remove(path)
os.remove(path .. ".tmp")

local function reload_auth()
  package.loaded["ao.shared.auth"] = nil
  return require("ao.shared.auth")
end

local auth = reload_auth()

local msg = {
  action = "SaveDraftPage",
  requestId = "nonce-persist-1",
  actor = "actor-1",
  tenant = "tenant-1",
  nonce = "nonce-xyz",
  timestamp = tostring(os.time()),
}

assert(auth.require_nonce(msg))

-- after reload, same nonce should be replayed
local auth2 = reload_auth()
local ok, err = auth2.require_nonce(msg)
assert(not ok and err == "replay_nonce", "expected replay_nonce after reload")

-- if TTL is short (<=2), allow reuse after expiry
local ttl = tonumber(os.getenv("AUTH_NONCE_TTL_SECONDS") or os.getenv("WRITE_NONCE_TTL_SECONDS") or "0")
if ttl > 0 and ttl <= 2 then
  os.execute("sleep " .. tostring(ttl + 1))
  local auth3 = reload_auth()
  local ok2 = auth3.require_nonce(msg)
  assert(ok2, "nonce should expire after TTL")
end

print("nonce_persist_spec: ok")

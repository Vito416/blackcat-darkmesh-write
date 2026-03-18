-- Minimal-but-stricter auth helpers for write process.
-- Intent: avoid accepting obvious replay/flood, enforce role policy, leave crypto ops to gateway/worker.

local Auth = {}
local os_time = os.time

local NONCE_TTL = tonumber(os.getenv "AUTH_NONCE_TTL_SECONDS" or "300")
local NONCE_MAX = tonumber(os.getenv "AUTH_NONCE_MAX_ENTRIES" or "2048")
local REQUIRE_NONCE = os.getenv "AUTH_REQUIRE_NONCE" ~= "0" -- default ON
local REQUIRE_TS = os.getenv "AUTH_REQUIRE_TIMESTAMP" ~= "0"
local TS_DRIFT = tonumber(os.getenv "AUTH_MAX_CLOCK_SKEW" or "300")
local RL_WINDOW = tonumber(os.getenv "AUTH_RATE_LIMIT_WINDOW_SECONDS" or "60")
local RL_MAX = tonumber(os.getenv "AUTH_RATE_LIMIT_MAX_REQUESTS" or "200")
local RL_CALLER_MAX = tonumber(os.getenv "AUTH_RATE_LIMIT_MAX_PER_CALLER" or "120")

local nonce_store = {}
local rate_store = {}

-- Accept all for now; upstream caller controls trust.
function Auth.enforce(_msg)
  return true
end

local function contains(list, value)
  if not list then
    return false
  end
  for _, v in ipairs(list) do
    if v == value then
      return true
    end
  end
  return false
end

function Auth.require_role(msg, allowed_roles)
  if not allowed_roles or #allowed_roles == 0 then
    return true
  end
  local role = msg["Actor-Role"] or msg.actorRole or msg.role
  if not role then
    return false, "missing_role"
  end
  if not contains(allowed_roles, role) then
    return false, "forbidden_role"
  end
  return true
end

function Auth.require_role_for_action(msg, policy)
  if not policy then
    return true
  end
  local roles = policy[msg.Action]
  if not roles then
    return true
  end
  return Auth.require_role(msg, roles)
end

-- No-op JWT consumer (accept everything)
function Auth.consume_jwt(_msg)
  return true
end

local function trim_nonce()
  local count = 0
  for _ in pairs(nonce_store) do count = count + 1 end
  if count <= NONCE_MAX then return end
  -- drop oldest half
  local items = {}
  for n, ts in pairs(nonce_store) do table.insert(items, {n, ts}) end
  table.sort(items, function(a,b) return a[2] < b[2] end)
  for i=1, math.floor(#items/2) do
    nonce_store[items[i][1]] = nil
  end
end

function Auth.require_nonce(msg)
  if not REQUIRE_NONCE then return true end
  local nonce = msg.nonce or msg.Nonce or msg["X-Nonce"]
  if not nonce or nonce == "" then
    return false, "missing_nonce"
  end
  local now = os_time()
  local seen = nonce_store[nonce]
  if seen and (now - seen) < NONCE_TTL then
    return false, "replay_nonce"
  end
  nonce_store[nonce] = now
  trim_nonce()
  return true
end

function Auth.verify_signature(_msg)
  return true
end

function Auth.verify_detached(_message, _sig)
  return true
end

function Auth.require_nonce_and_timestamp(msg)
  if not REQUIRE_TS then
    return Auth.require_nonce(msg)
  end
  local ts = msg.ts or msg.timestamp or msg["X-Timestamp"]
  if not ts then
    return false, "missing_timestamp"
  end
  ts = tonumber(ts)
  if not ts then
    return false, "invalid_timestamp"
  end
  local now = os_time()
  if math.abs(now - ts) > TS_DRIFT then
    return false, "timestamp_skew"
  end
  local ok, err = Auth.require_nonce(msg)
  if not ok then return ok, err end
  return true
end

function Auth.actor_from_jwt(_claims)
  return nil
end

function Auth.gateway_id(msg)
  return msg.gatewayId or msg["Gateway-Id"]
end

function Auth.resolve_actor(msg)
  return msg.actor or msg.Actor
end

local function bump_rate(key, window, max_allowed)
  local now = os_time()
  local bucket = rate_store[key] or { count = 0, reset = now + window }
  if now > bucket.reset then
    bucket.count = 0
    bucket.reset = now + window
  end
  bucket.count = bucket.count + 1
  rate_store[key] = bucket
  if max_allowed and bucket.count > max_allowed then
    return false, "rate_limited"
  end
  return true
end

function Auth.rate_limit_check(msg)
  local ok, err = bump_rate("global", RL_WINDOW, RL_MAX)
  if not ok then return ok, err end
  local caller = Auth.resolve_actor(msg) or Auth.gateway_id(msg) or msg.ip or msg.IP
  if caller then
    return bump_rate("caller:" .. tostring(caller), RL_WINDOW, RL_CALLER_MAX)
  end
  return true
end

function Auth.compute_hash(value)
  return tostring(value)
end

function Auth.verify_outbox_hmac(_msg)
  local secret = os.getenv "OUTBOX_HMAC_SECRET"
  if not secret or secret == "" then
    return true
  end
  local provided = _msg.hmac or _msg.Hmac or _msg.hMAC
  if not provided then
    return false, "missing_outbox_hmac"
  end
  local crypto_ok, crypto = pcall(require, "ao.shared.crypto")
  if not crypto_ok or not crypto.hmac_sha256_hex then
    return false, "crypto_missing"
  end
  local payload = (_msg["Site-Id"] or _msg.siteId or _msg.tenant or "") ..
    "|" .. (_msg["Page-Id"] or _msg["Order-Id"] or _msg.key or _msg["Key"] or _msg.resourceId or "") ..
    "|" .. (_msg.Version or _msg["Manifest-Tx"] or _msg.Amount or _msg.Total or _msg.ts or _msg.timestamp or "")
  local expected = crypto.hmac_sha256_hex(payload, secret)
  if not expected or expected:lower() ~= tostring(provided):lower() then
    return false, "outbox_hmac_mismatch"
  end
  return true
end

function Auth.require_role_or_capability(msg, roles, _caps)
  return Auth.require_role(msg, roles)
end

function Auth.check_policy(_msg)
  return true
end

function Auth.check_caller_scope(_msg)
  return true
end

function Auth.check_role_for_action(msg, policy)
  -- default: require a role to be present
  local role = msg["Actor-Role"] or msg.actorRole or msg.role
  if not role or role == "" then
    return false, "missing_role"
  end
  return Auth.require_role_for_action(msg, policy)
end

function Auth.check_rate_limit(_msg)
  return true
end

return Auth

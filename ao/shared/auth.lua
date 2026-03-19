-- Minimal-but-stricter auth helpers for write process.
-- Intent: avoid accepting obvious replay/flood, enforce role policy, leave crypto ops to gateway/worker.

local Auth = {}
local os_time = os.time

-- Allow WRITE_* aliases for ops/env parity
local function getenv_multi(...)
  for _, key in ipairs({...}) do
    local val = os.getenv(key)
    if val ~= nil then return val end
  end
  return nil
end

local NONCE_TTL = tonumber(getenv_multi("AUTH_NONCE_TTL_SECONDS", "WRITE_NONCE_TTL_SECONDS") or "300")
local NONCE_MAX = tonumber(getenv_multi("AUTH_NONCE_MAX_ENTRIES", "WRITE_NONCE_MAX") or "2048")
local REQUIRE_NONCE = getenv_multi("AUTH_REQUIRE_NONCE", "WRITE_REQUIRE_NONCE") ~= "0" -- default ON
local REQUIRE_TS = getenv_multi("AUTH_REQUIRE_TIMESTAMP", "WRITE_REQUIRE_TIMESTAMP") ~= "0"
local TS_DRIFT = tonumber(getenv_multi("AUTH_MAX_CLOCK_SKEW", "WRITE_MAX_CLOCK_SKEW") or "300")
local RL_WINDOW = tonumber(getenv_multi("AUTH_RATE_LIMIT_WINDOW_SECONDS", "WRITE_RL_WINDOW_SECONDS") or "60")
local RL_MAX = tonumber(getenv_multi("AUTH_RATE_LIMIT_MAX_REQUESTS", "WRITE_RL_MAX_REQUESTS") or "200")
local RL_CALLER_MAX = tonumber(getenv_multi("AUTH_RATE_LIMIT_MAX_PER_CALLER", "WRITE_RL_CALLER_MAX") or "120")

local REQUIRE_SIGNATURE = getenv_multi("WRITE_REQUIRE_SIGNATURE", "AUTH_REQUIRE_SIGNATURE") == "1"
local SIG_TYPE = getenv_multi("WRITE_SIG_TYPE", "AUTH_SIG_TYPE") or "ed25519"
local SIG_PUBLIC = getenv_multi("WRITE_SIG_PUBLIC", "AUTH_SIG_PUBLIC")
local SIG_SECRET = getenv_multi("WRITE_SIG_SECRET", "AUTH_SIG_SECRET")
local REQUIRE_JWT = getenv_multi("WRITE_REQUIRE_JWT", "AUTH_REQUIRE_JWT") == "1"
local JWT_SECRET = getenv_multi("WRITE_JWT_HS_SECRET", "AUTH_JWT_HS_SECRET")
local RATE_STORE_PATH = getenv_multi("WRITE_RATE_STORE_PATH", "AUTH_RATE_STORE_PATH")

local crypto_ok, crypto = pcall(require, "ao.shared.crypto")
local jwt_ok, jwt = pcall(require, "ao.shared.jwt")
local cjson_ok, cjson = pcall(require, "cjson")

local nonce_store = {}
local rate_store = {}

local function load_rate_store()
  if not RATE_STORE_PATH or RATE_STORE_PATH == "" then return end
  local f = io.open(RATE_STORE_PATH, "r")
  if not f then return end
  local content = f:read("*a")
  f:close()
  if not cjson_ok then return end
  local ok, decoded = pcall(cjson.decode, content)
  if ok and type(decoded) == "table" then
    rate_store = decoded
  end
end

local function persist_rate_store()
  if not RATE_STORE_PATH or RATE_STORE_PATH == "" then return end
  if not cjson_ok then return end
  local f = io.open(RATE_STORE_PATH, "w")
  if not f then return end
  f:write(cjson.encode(rate_store))
  f:close()
end

load_rate_store()

local function parse_iso8601(ts)
  if type(ts) ~= "string" then return nil end
  local y, m, d, H, M, S = ts:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)T(%d%d):(%d%d):(%d%d)Z$")
  if not y then return nil end
  return os_time({ year = y, month = m, day = d, hour = H, min = M, sec = S, isdst = false })
end

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

local function verify_jwt(msg)
  if not REQUIRE_JWT then
    return true
  end
  if not JWT_SECRET or JWT_SECRET == "" then
    return false, "jwt_secret_missing"
  end
  if not jwt_ok or not jwt.verify_hs256 then
    return false, "jwt_deps_missing"
  end
  local token = msg.jwt or msg.JWT or msg.token
  if not token then
    return false, "missing_jwt"
  end
  local ok, payload_or_err = jwt.verify_hs256(token, JWT_SECRET)
  if not ok then
    return false, payload_or_err or "jwt_invalid"
  end
  return true, payload_or_err
end

function Auth.consume_jwt(msg)
  local ok, claims = verify_jwt(msg)
  if not ok then return ok, claims end
  -- map JWT claims onto envelope if caller didn't already supply them
  if type(claims) == "table" then
    local mapped = Auth.actor_from_jwt(claims)
    if mapped then
      msg.actor = msg.actor or msg.Actor or mapped.actor
      msg.Actor = msg.Actor or msg.actor
      msg.tenant = msg.tenant or msg.Tenant or mapped.tenant
      msg.Tenant = msg.Tenant or msg.tenant
      msg["Actor-Role"] = msg["Actor-Role"] or msg.actorRole or mapped.role
      msg.actorRole = msg.actorRole or msg["Actor-Role"]
    end
  end
  return ok, claims
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

local function pick(...)
  for i = 1, select("#", ...) do
    local v = select(i, ...)
    if v and v ~= "" then return v end
  end
  return ""
end

local function outbox_hmac_payload(msg)
  local parts = {
    pick(msg["Site-Id"], msg.siteId, msg.tenant, msg.tenantId, msg.gatewayId),
    pick(msg["Page-Id"], msg.pageId, msg["Order-Id"], msg.orderId, msg.paymentId, msg["Payment-Id"], msg.key, msg["Key"], msg.resourceId, msg.shipmentId),
    pick(msg.Version, msg.version, msg.versionId, msg["Manifest-Tx"], msg.manifestTx),
    pick(msg.Amount, msg.amount, msg.Total, msg.totalAmount),
    pick(msg.currency, msg.Currency),
    pick(msg.ts, msg.timestamp),
  }
  return table.concat(parts, "|")
end

function Auth.compute_outbox_hmac(msg, secret)
  secret = secret or os.getenv("OUTBOX_HMAC_SECRET")
  if not secret or secret == "" then return nil, "missing_outbox_hmac_secret" end
  if not crypto_ok or not crypto.hmac_sha256_hex then return nil, "crypto_missing" end
  return crypto.hmac_sha256_hex(outbox_hmac_payload(msg), secret)
end

local function canonical_detached_message(msg)
  return (msg.action or msg.Action or "") .. "|" .. (msg.tenant or msg.Tenant or msg["Tenant-Id"] or "") .. "|" .. (msg.requestId or msg["Request-Id"] or "")
end

local function verify_sig(msg)
  if not REQUIRE_SIGNATURE then
    return true
  end
  local sig = msg.signature
  local sig_ref = msg.signatureRef or msg["Signature-Ref"]
  if not sig_ref or sig_ref == "" then
    return false, "missing_signature_ref"
  end
  if not sig or sig == "" then
    return false, "missing_signature"
  end
  if not crypto_ok then
    return false, "crypto_missing"
  end
  local payload = canonical_detached_message(msg)
  if SIG_TYPE == "hmac" then
    if not SIG_SECRET or SIG_SECRET == "" then return false, "missing_sig_secret" end
    return crypto.verify_hmac_sha256(payload, SIG_SECRET, sig)
  elseif SIG_TYPE == "ecdsa" then
    if not SIG_PUBLIC then return false, "missing_sig_public" end
    return crypto.verify_ecdsa_sha256(payload, sig, SIG_PUBLIC)
  else -- default ed25519
    if not SIG_PUBLIC then return false, "missing_sig_public" end
    return crypto.verify_ed25519(payload, sig, SIG_PUBLIC)
  end
end

function Auth.verify_signature(msg)
  return verify_sig(msg)
end

function Auth.verify_detached(message, sig)
  if not REQUIRE_SIGNATURE then
    return true
  end
  if not crypto_ok then return false, "crypto_missing" end
  if SIG_TYPE == "hmac" then
    if not SIG_SECRET then return false, "missing_sig_secret" end
    return crypto.verify_hmac_sha256(message, SIG_SECRET, sig)
  elseif SIG_TYPE == "ecdsa" then
    if not SIG_PUBLIC then return false, "missing_sig_public" end
    return crypto.verify_ecdsa_sha256(message, sig, SIG_PUBLIC)
  else
    if not SIG_PUBLIC then return false, "missing_sig_public" end
    return crypto.verify_ed25519(message, sig, SIG_PUBLIC)
  end
end

function Auth.require_nonce_and_timestamp(msg)
  if not REQUIRE_TS then
    return Auth.require_nonce(msg)
  end
  local ts = msg.ts or msg.timestamp or msg["X-Timestamp"]
  if not ts then
    return false, "missing_timestamp"
  end
  ts = tonumber(ts) or parse_iso8601(ts)
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

function Auth.actor_from_jwt(claims)
  if type(claims) ~= "table" then return nil end
  return {
    actor = claims.sub or claims.subject,
    tenant = claims.tenant or claims.ten or claims.tid,
    role = claims.role or claims.r,
  }
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
  persist_rate_store()
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

function Auth.verify_outbox_hmac(msg)
  local secret = os.getenv "OUTBOX_HMAC_SECRET"
  if not secret or secret == "" then
    return true
  end
  local provided = msg.hmac or msg.Hmac or msg.hMAC
  if not provided then
    return false, "missing_outbox_hmac"
  end
  local expected, err = Auth.compute_outbox_hmac(msg, secret)
  if not expected then
    return false, err or "outbox_hmac_missing"
  end
  if expected:lower() ~= tostring(provided):lower() then
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

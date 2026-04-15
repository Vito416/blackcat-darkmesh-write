-- Minimal-but-stricter auth helpers for write process.
-- Intent:
--   avoid obvious replay/flood,
--   enforce signatureRef policy + role policy,
--   keep crypto ops at gateway/worker layer.

local Auth = {}
local os_time = os.time
local os_date = os.date
local os_difftime = os.difftime
local START_EPOCH = os_time()
local getenv_override = package.loaded["ao.shared.auth.getenv_override"]

-- Allow WRITE_* aliases for ops/env parity
local function getenv_multi(...)
  for _, key in ipairs { ... } do
    if type(getenv_override) == "function" then
      local override = getenv_override(key)
      if override ~= nil then
        return override
      end
    end
    local val = os.getenv(key)
    if val ~= nil then
      return val
    end
  end
  return nil
end

local NONCE_TTL =
  tonumber(getenv_multi("AUTH_NONCE_TTL_SECONDS", "WRITE_NONCE_TTL_SECONDS") or "300")
local NONCE_MAX = tonumber(getenv_multi("AUTH_NONCE_MAX_ENTRIES", "WRITE_NONCE_MAX") or "2048")
-- default ON
local REQUIRE_NONCE = getenv_multi("AUTH_REQUIRE_NONCE", "WRITE_REQUIRE_NONCE") ~= "0"
local REQUIRE_TS = getenv_multi("AUTH_REQUIRE_TIMESTAMP", "WRITE_REQUIRE_TIMESTAMP") ~= "0"
local TS_DRIFT = tonumber(getenv_multi("AUTH_MAX_CLOCK_SKEW", "WRITE_MAX_CLOCK_SKEW") or "300")
local RL_WINDOW =
  tonumber(getenv_multi("AUTH_RATE_LIMIT_WINDOW_SECONDS", "WRITE_RL_WINDOW_SECONDS") or "60")
local RL_MAX =
  tonumber(getenv_multi("AUTH_RATE_LIMIT_MAX_REQUESTS", "WRITE_RL_MAX_REQUESTS") or "200")
local RL_CALLER_MAX =
  tonumber(getenv_multi("AUTH_RATE_LIMIT_MAX_PER_CALLER", "WRITE_RL_CALLER_MAX") or "120")
local UNIQUE_SUBJECT_MAX_PER_IP =
  tonumber(getenv_multi("WRITE_UNIQUE_SUBJECT_MAX_PER_IP", "AUTH_UNIQUE_SUBJECT_MAX_PER_IP") or "0")
local RL_BUCKET_TTL = tonumber(
  getenv_multi("AUTH_RATE_BUCKET_TTL_SECONDS", "WRITE_RL_BUCKET_TTL_SECONDS")
    or tostring(RL_WINDOW * 4)
)
local RL_MAX_BUCKETS =
  tonumber(getenv_multi("AUTH_RATE_MAX_BUCKETS", "WRITE_RL_MAX_BUCKETS") or "4096")

-- Default ON: signatures required unless explicitly disabled with WRITE_REQUIRE_SIGNATURE=0.
local REQUIRE_SIGNATURE = getenv_multi("WRITE_REQUIRE_SIGNATURE", "AUTH_REQUIRE_SIGNATURE") ~= "0"
local SIG_TYPE = getenv_multi("WRITE_SIG_TYPE", "AUTH_SIG_TYPE") or "ed25519"
local SIG_PUBLIC = getenv_multi("WRITE_SIG_PUBLIC", "AUTH_SIG_PUBLIC")
local SIG_PUBLICS = getenv_multi("WRITE_SIG_PUBLICS", "AUTH_SIG_PUBLICS")
local SIG_SECRET = getenv_multi("WRITE_SIG_SECRET", "AUTH_SIG_SECRET")
local SIG_POLICY_JSON = getenv_multi("WRITE_SIGNATURE_POLICY_JSON", "AUTH_SIGNATURE_POLICY_JSON")
local SIG_POLICY_PATH = getenv_multi("WRITE_SIGNATURE_POLICY_PATH", "AUTH_SIGNATURE_POLICY_PATH")
local REQUIRE_JWT = getenv_multi("WRITE_REQUIRE_JWT", "AUTH_REQUIRE_JWT") == "1"
local JWT_SECRET = getenv_multi("WRITE_JWT_HS_SECRET", "AUTH_JWT_HS_SECRET")
local RATE_STORE_PATH = getenv_multi("WRITE_RATE_STORE_PATH", "AUTH_RATE_STORE_PATH")
local NONCE_STORE_PATH = getenv_multi("WRITE_NONCE_STORE_PATH", "AUTH_NONCE_STORE_PATH")

local crypto_ok, crypto = pcall(require, "ao.shared.crypto")
local jwt_ok, jwt = pcall(require, "ao.shared.jwt")
local cjson_ok, cjson = pcall(require, "cjson")
local metrics_ok, metrics = pcall(require, "ao.shared.metrics")
local function m_counter(name, value)
  if metrics_ok and metrics and metrics.counter then
    metrics.counter(name, value or 1)
  end
end

local nonce_store = {}
local rate_store = {}

local function load_rate_store()
  if not RATE_STORE_PATH or RATE_STORE_PATH == "" then
    return
  end
  local f = io.open(RATE_STORE_PATH, "r")
  if not f then
    return
  end
  local content = f:read "*a"
  f:close()
  if not cjson_ok then
    return
  end
  local ok, decoded = pcall(cjson.decode, content)
  if ok and type(decoded) == "table" then
    rate_store = decoded
  end
end

local function persist_rate_store()
  if not RATE_STORE_PATH or RATE_STORE_PATH == "" then
    return
  end
  if not cjson_ok then
    return
  end
  local tmp = RATE_STORE_PATH .. ".tmp"
  local f = io.open(tmp, "w")
  if not f then
    return
  end
  f:write(cjson.encode(rate_store))
  f:close()
  os.rename(tmp, RATE_STORE_PATH)
end

local function trim_rate_store(now)
  now = now or os_time()
  -- drop stale buckets beyond TTL or process start
  for key, bucket in pairs(rate_store) do
    local updated = bucket.updated or bucket.reset or 0
    if (now - updated) > RL_BUCKET_TTL or updated < START_EPOCH then
      rate_store[key] = nil
    end
  end
  -- size bound
  local count = 0
  for _ in pairs(rate_store) do
    count = count + 1
  end
  if count <= RL_MAX_BUCKETS then
    return
  end
  local items = {}
  for k, v in pairs(rate_store) do
    items[#items + 1] = { k = k, updated = v.updated or v.reset or 0 }
  end
  table.sort(items, function(a, b)
    return a.updated < b.updated
  end)
  local to_drop = count - RL_MAX_BUCKETS
  for i = 1, to_drop do
    rate_store[items[i].k] = nil
  end
end

load_rate_store()
trim_rate_store(START_EPOCH)

local function load_nonce_store()
  if not NONCE_STORE_PATH or NONCE_STORE_PATH == "" then
    return
  end
  if not cjson_ok then
    return
  end
  local f = io.open(NONCE_STORE_PATH, "r")
  if not f then
    return
  end
  local content = f:read "*a"
  f:close()
  local ok, decoded = pcall(cjson.decode, content)
  if ok and type(decoded) == "table" then
    nonce_store = decoded
  end
end

local function persist_nonce_store()
  if not NONCE_STORE_PATH or NONCE_STORE_PATH == "" then
    return
  end
  if not cjson_ok then
    return
  end
  local tmp = NONCE_STORE_PATH .. ".tmp"
  local f = io.open(tmp, "w")
  if not f then
    return
  end
  f:write(cjson.encode(nonce_store))
  f:close()
  os.rename(tmp, NONCE_STORE_PATH)
end

load_nonce_store()

local function parse_iso8601(ts)
  if type(ts) ~= "string" then
    return nil
  end
  local y, m, d, H, M, S = ts:match "^(%d%d%d%d)%-(%d%d)%-(%d%d)T(%d%d):(%d%d):(%d%d)Z$"
  if not y then
    return nil
  end
  local local_epoch = os_time {
    year = tonumber(y),
    month = tonumber(m),
    day = tonumber(d),
    hour = tonumber(H),
    min = tonumber(M),
    sec = tonumber(S),
    isdst = false,
  }
  if not local_epoch then
    return nil
  end
  local local_t = os_date("*t", local_epoch)
  local utc_t = os_date("!*t", local_epoch)
  return local_epoch + os_difftime(os_time(local_t), os_time(utc_t))
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

local SIG_PUBLICS_CACHE = nil
local SIG_PUBLICS_CACHE_OK = false
local function resolve_sig_public(sig_ref)
  if SIG_PUBLICS and SIG_PUBLICS ~= "" then
    if not SIG_PUBLICS_CACHE_OK then
      SIG_PUBLICS_CACHE_OK = true
      local parsed_map = nil
      if cjson_ok and cjson and cjson.decode then
        local ok, parsed = pcall(cjson.decode, SIG_PUBLICS)
        if ok and type(parsed) == "table" then
          parsed_map = parsed
        end
      end
      if not parsed_map then
        local map = {}
        for pair in tostring(SIG_PUBLICS):gmatch "[^,;]+" do
          local k, v = pair:match "^%s*([^=%s]+)%s*=%s*(.-)%s*$"
          if k and v and v ~= "" then
            map[k] = v
          end
        end
        if next(map) then
          parsed_map = map
        end
      end
      SIG_PUBLICS_CACHE = parsed_map
    end
    if type(SIG_PUBLICS_CACHE) == "table" then
      local key = sig_ref or ""
      local found = SIG_PUBLICS_CACHE[key]
      if type(found) == "string" and found ~= "" then
        return found
      end
      local default_ref = SIG_PUBLICS_CACHE.default or SIG_PUBLICS_CACHE.DEFAULT
      if type(default_ref) == "string" and default_ref ~= "" then
        return default_ref
      end
    end
  end
  return SIG_PUBLIC
end

local function list_from_value(value)
  if value == nil then
    return nil
  end
  if value == "*" then
    return "*"
  end
  if type(value) == "string" then
    if value == "" then
      return nil
    end
    return { value }
  end
  if type(value) ~= "table" then
    return nil
  end
  if value[1] == "*" and #value == 1 then
    return "*"
  end
  local out = {}
  for i = 1, #value do
    local item = value[i]
    if type(item) ~= "string" or item == "" then
      return nil
    end
    out[#out + 1] = item
  end
  if #out == 0 then
    return nil
  end
  return out
end

local function normalize_policy_entry(entry)
  if type(entry) == "string" then
    local actions = list_from_value(entry)
    if not actions then
      return nil
    end
    return { actions = actions }
  end
  if type(entry) ~= "table" then
    return nil
  end

  local actions = entry.actions or entry.action or entry.allowedActions
  local roles = entry.roles or entry.role or entry.allowedRoles
  if actions == nil and roles == nil then
    if #entry > 0 then
      actions = entry
    else
      return nil
    end
  end

  local normalized = {}
  if actions ~= nil then
    normalized.actions = list_from_value(actions)
    if not normalized.actions then
      return nil
    end
  end
  if roles ~= nil then
    normalized.roles = list_from_value(roles)
    if not normalized.roles then
      return nil
    end
  end
  if not normalized.actions and not normalized.roles then
    return nil
  end
  return normalized
end

local SIGNATURE_POLICY_CONFIGURED = (SIG_POLICY_JSON and SIG_POLICY_JSON ~= "")
  or (SIG_POLICY_PATH and SIG_POLICY_PATH ~= "")
local SIGNATURE_POLICY_CACHE = nil
local SIGNATURE_POLICY_ERROR = nil
local SIGNATURE_POLICY_LOADED = false

local function load_signature_policy()
  if not SIGNATURE_POLICY_CONFIGURED then
    return nil, nil
  end
  if not cjson_ok or not cjson then
    return nil, "signature_policy_json_unavailable"
  end

  local raw = SIG_POLICY_JSON
  if (not raw or raw == "") and SIG_POLICY_PATH and SIG_POLICY_PATH ~= "" then
    local f = io.open(SIG_POLICY_PATH, "r")
    if not f then
      return nil, "signature_policy_unreadable"
    end
    raw = f:read "*a"
    f:close()
  end

  if not raw or raw == "" then
    return nil, "signature_policy_missing_source"
  end

  local ok, decoded = pcall(cjson.decode, raw)
  if not ok or type(decoded) ~= "table" then
    return nil, "signature_policy_invalid"
  end

  local map = {}
  for sig_ref, entry in pairs(decoded) do
    if type(sig_ref) ~= "string" or sig_ref == "" then
      return nil, "signature_policy_invalid"
    end
    local normalized = normalize_policy_entry(entry)
    if not normalized then
      return nil, "signature_policy_invalid"
    end
    map[sig_ref] = normalized
  end

  if not next(map) then
    return nil, "signature_policy_invalid"
  end

  return map, nil
end

local function ensure_signature_policy()
  if SIGNATURE_POLICY_LOADED then
    return SIGNATURE_POLICY_CACHE, SIGNATURE_POLICY_ERROR, SIGNATURE_POLICY_CONFIGURED
  end
  SIGNATURE_POLICY_LOADED = true
  SIGNATURE_POLICY_CACHE, SIGNATURE_POLICY_ERROR = load_signature_policy()
  return SIGNATURE_POLICY_CACHE, SIGNATURE_POLICY_ERROR, SIGNATURE_POLICY_CONFIGURED
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

local function resolve_action(msg)
  return msg.action or msg.Action
end

function Auth.require_role_for_action(msg, policy)
  if not policy then
    return true
  end
  local action = resolve_action(msg)
  if not action or action == "" then
    return true
  end
  local roles = policy[action]
  if not roles then
    return true
  end
  return Auth.require_role(msg, roles)
end

local function verify_jwt(msg)
  local token = msg.jwt or msg.JWT or msg.token
  if not token then
    if REQUIRE_JWT then
      return false, "missing_jwt"
    end
    return true
  end
  if not JWT_SECRET or JWT_SECRET == "" then
    if REQUIRE_JWT then
      return false, "jwt_secret_missing"
    end
    return true
  end
  if not jwt_ok or not jwt.verify_hs256 then
    return false, "jwt_deps_missing"
  end
  local ok, payload_or_err = jwt.verify_hs256(token, JWT_SECRET)
  if not ok then
    m_counter "write_auth_jwt_invalid_total"
    return false, payload_or_err or "jwt_invalid"
  end
  local claims = payload_or_err
  if type(claims) == "table" then
    local now = os_time()
    local exp = tonumber(claims.exp)
    if exp and (now - TS_DRIFT) > exp then
      m_counter "write_auth_jwt_expired_total"
      return false, "jwt_expired"
    end
    local nbf = tonumber(claims.nbf)
    if nbf and (now + TS_DRIFT) < nbf then
      m_counter "write_auth_jwt_not_before_total"
      return false, "jwt_not_before"
    end
    local iat = tonumber(claims.iat)
    if iat and math.abs(now - iat) > TS_DRIFT then
      m_counter "write_auth_jwt_skew_total"
      return false, "jwt_iat_skew"
    end
  end
  return true, payload_or_err
end

function Auth.consume_jwt(msg)
  local ok, claims = verify_jwt(msg)
  if not ok then
    return ok, claims
  end
  -- map JWT claims onto envelope if caller didn't already supply them
  if type(claims) == "table" then
    local mapped = Auth.actor_from_jwt(claims)
    msg._jwt_sub = claims.sub or claims.subj or msg._jwt_sub
    if REQUIRE_JWT and mapped then
      local env_actor = msg.actor or msg.Actor
      local env_tenant = msg.tenant or msg.Tenant
      local env_role = msg["Actor-Role"] or msg.actorRole
      if mapped.actor and env_actor and tostring(env_actor) ~= tostring(mapped.actor) then
        m_counter "write_auth_jwt_actor_mismatch_total"
        return false, "jwt_actor_mismatch"
      end
      if mapped.tenant and env_tenant and tostring(env_tenant) ~= tostring(mapped.tenant) then
        m_counter "write_auth_jwt_tenant_mismatch_total"
        return false, "jwt_tenant_mismatch"
      end
      if mapped.role and env_role and tostring(env_role) ~= tostring(mapped.role) then
        m_counter "write_auth_jwt_role_mismatch_total"
        return false, "jwt_role_mismatch"
      end
    end
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

local function trim_nonce(now)
  local count = 0
  for _ in pairs(nonce_store) do
    count = count + 1
  end
  -- purge expired entries first
  if now then
    for key, ts in pairs(nonce_store) do
      if (now - ts) > NONCE_TTL then
        nonce_store[key] = nil
        count = count - 1
      end
    end
  end
  if count <= NONCE_MAX then
    return
  end
  -- drop oldest half of remaining
  local items = {}
  for n, ts in pairs(nonce_store) do
    table.insert(items, { n, ts })
  end
  table.sort(items, function(a, b)
    return a[2] < b[2]
  end)
  for i = 1, math.floor(#items / 2) do
    nonce_store[items[i][1]] = nil
  end
end

trim_nonce(START_EPOCH)

function Auth.require_nonce(msg)
  if not REQUIRE_NONCE then
    return true
  end
  local nonce = msg.nonce or msg.Nonce or msg["X-Nonce"]
  if not nonce or nonce == "" then
    return false, "missing_nonce"
  end
  local tenant = msg.tenant or msg.Tenant or msg["Tenant-Id"] or "global"
  local actor = Auth.resolve_actor(msg) or Auth.gateway_id(msg) or ""
  local key = tenant .. ":" .. tostring(actor) .. ":" .. tostring(nonce)
  local now = os_time()
  local seen = nonce_store[key]
  if seen and (now - seen) < NONCE_TTL then
    m_counter "write_auth_nonce_replay_total"
    return false, "replay_nonce"
  end
  nonce_store[key] = now
  trim_nonce(now)
  persist_nonce_store()
  return true
end

local function pick(...)
  for i = 1, select("#", ...) do
    local v = select(i, ...)
    if v and v ~= "" then
      return v
    end
  end
  return ""
end

local function outbox_hmac_payload(msg)
  local parts = {
    pick(msg["Site-Id"], msg.siteId, msg.tenant, msg.tenantId, msg.gatewayId),
    pick(
      msg["Page-Id"],
      msg.pageId,
      msg["Order-Id"],
      msg.orderId,
      msg.paymentId,
      msg["Payment-Id"],
      msg.key,
      msg["Key"],
      msg.resourceId,
      msg.shipmentId
    ),
    pick(msg.Version, msg.version, msg.versionId, msg["Manifest-Tx"], msg.manifestTx),
    pick(msg.Amount, msg.amount, msg.Total, msg.totalAmount),
    pick(msg.currency, msg.Currency),
    pick(msg.ts, msg.timestamp),
  }
  return table.concat(parts, "|")
end

function Auth.compute_outbox_hmac(msg, secret)
  secret = secret or os.getenv "OUTBOX_HMAC_SECRET"
  if not secret or secret == "" then
    return nil, "missing_outbox_hmac_secret"
  end
  -- Decode hex secrets to raw bytes for sodium; fail fast on wrong length
  if type(secret) == "string" and #secret % 2 == 0 and secret:match "^[0-9a-fA-F]+$" then
    secret = secret:gsub("..", function(cc)
      return string.char(tonumber(cc, 16))
    end)
  end
  if #secret ~= 32 then
    return nil, "hmac_key_bad_len"
  end
  if not crypto_ok or not crypto.hmac_sha256_hex then
    return nil, "crypto_missing"
  end
  return crypto.hmac_sha256_hex(outbox_hmac_payload(msg), secret)
end

local function is_array(tbl)
  local count = 0
  for k in pairs(tbl) do
    if type(k) ~= "number" then
      return false
    end
    count = count + 1
  end
  for i = 1, count do
    if tbl[i] == nil then
      return false
    end
  end
  if count == 0 then
    -- Keep empty payload table canonicalized as `{}` so Lua and JS detached
    -- signers generate the same message string.
    return false
  end
  return true
end

local function canonical_json(value)
  -- Deterministic JSON encoder (sorted keys for objects, preserve array order).
  local t = type(value)
  if t == "table" then
    if is_array(value) then
      local parts = {}
      for i = 1, #value do
        parts[#parts + 1] = canonical_json(value[i])
      end
      return "[" .. table.concat(parts, ",") .. "]"
    else
      local keys = {}
      for k in pairs(value) do
        keys[#keys + 1] = k
      end
      table.sort(keys, function(a, b)
        return tostring(a) < tostring(b)
      end)
      local parts = {}
      for _, k in ipairs(keys) do
        local key_encoded = tostring(k)
          :gsub("\\", "\\\\")
          :gsub('"', '\\"')
          :gsub("\b", "\\b")
          :gsub("\f", "\\f")
          :gsub("\n", "\\n")
          :gsub("\r", "\\r")
          :gsub("\t", "\\t")
          :gsub("[%z\1-\31]", function(ch)
            return string.format("\\u%04x", string.byte(ch))
          end)
        key_encoded = '"' .. key_encoded .. '"'
        parts[#parts + 1] = key_encoded .. ":" .. canonical_json(value[k])
      end
      return "{" .. table.concat(parts, ",") .. "}"
    end
  else
    if value == nil then
      return "null"
    end
    if t == "boolean" then
      return value and "true" or "false"
    end
    if t == "number" then
      if value ~= value or value == math.huge or value == -math.huge then
        return "null"
      end
      return tostring(value)
    end
    if t == "string" then
      local escaped = value
        :gsub("\\", "\\\\")
        :gsub('"', '\\"')
        :gsub("\b", "\\b")
        :gsub("\f", "\\f")
        :gsub("\n", "\\n")
        :gsub("\r", "\\r")
        :gsub("\t", "\\t")
        :gsub("[%z\1-\31]", function(ch)
          return string.format("\\u%04x", string.byte(ch))
        end)
      return '"' .. escaped .. '"'
    end
    return '"' .. tostring(value) .. '"'
  end
end

local function canonical_payload(msg)
  local payload = msg.payload or msg.Payload or {}
  local ok, encoded = pcall(canonical_json, payload)
  if ok then
    return encoded
  end
  return tostring(payload)
end

local function canonical_detached_message(msg)
  -- sign the important envelope parts + payload hash to prevent tampering
  local parts = {
    msg.action or msg.Action or "",
    pick(msg.tenant, msg.Tenant, msg["Tenant-Id"]),
    pick(msg.actor, msg.Actor),
    pick(msg.ts, msg.timestamp, msg["X-Timestamp"]),
    pick(msg.nonce, msg.Nonce, msg["X-Nonce"]),
    pick(msg.role, msg.Role, msg["Actor-Role"], msg.actorRole),
    canonical_payload(msg),
    msg.requestId or msg["Request-Id"] or "",
  }
  return table.concat(parts, "|")
end

local function verify_sig(msg)
  if not REQUIRE_SIGNATURE then
    return true
  end

  local sig = msg.signature
  local sig_ref = msg.signatureRef or msg["Signature-Ref"]
  if not sig_ref or sig_ref == "" then
    m_counter "write_auth_signature_missing_total"
    return false, "missing_signature_ref"
  end
  if not sig or sig == "" then
    m_counter "write_auth_signature_missing_total"
    return false, "missing_signature"
  end
  if not crypto_ok then
    m_counter "write_auth_signature_failed_total"
    return false, "crypto_missing"
  end
  local payload = canonical_detached_message(msg)
  if SIG_TYPE == "hmac" then
    if not SIG_SECRET or SIG_SECRET == "" then
      return false, "missing_sig_secret"
    end
    local ok, verify_err = crypto.verify_hmac_sha256(payload, SIG_SECRET, sig)
    if not ok then
      m_counter "write_auth_signature_failed_total"
      return false, verify_err or "bad_signature"
    end
    return true
  elseif SIG_TYPE == "ecdsa" then
    local sig_public = resolve_sig_public(sig_ref)
    if not sig_public then
      return false, "missing_sig_public"
    end
    local ok, verify_err = crypto.verify_ecdsa_sha256(payload, sig, sig_public)
    if not ok then
      m_counter "write_auth_signature_failed_total"
      return false, verify_err or "bad_signature"
    end
    return true
  else -- default ed25519
    local sig_public = resolve_sig_public(sig_ref)
    if not sig_public then
      return false, "missing_sig_public"
    end
    local ok, verify_err = crypto.verify_ed25519(payload, sig, sig_public)
    if not ok then
      m_counter "write_auth_signature_failed_total"
      return false, verify_err or "bad_signature"
    end
    return true
  end
end

function Auth.verify_signature(msg)
  return verify_sig(msg)
end

function Auth.verify_detached(message, sig)
  if not REQUIRE_SIGNATURE then
    return true
  end
  if not crypto_ok then
    return false, "crypto_missing"
  end
  if SIG_TYPE == "hmac" then
    if not SIG_SECRET then
      return false, "missing_sig_secret"
    end
    local ok, verify_err = crypto.verify_hmac_sha256(message, SIG_SECRET, sig)
    if ok then
      return true
    end
    return false, verify_err or "bad_signature"
  elseif SIG_TYPE == "ecdsa" then
    local sig_public = resolve_sig_public(nil)
    if not sig_public then
      return false, "missing_sig_public"
    end
    local ok, verify_err = crypto.verify_ecdsa_sha256(message, sig, sig_public)
    if ok then
      return true
    end
    return false, verify_err or "bad_signature"
  else
    local sig_public = resolve_sig_public(nil)
    if not sig_public then
      return false, "missing_sig_public"
    end
    local ok, verify_err = crypto.verify_ed25519(message, sig, sig_public)
    if ok then
      return true
    end
    return false, verify_err or "bad_signature"
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
  if not ok then
    return ok, err
  end
  return true
end

function Auth.actor_from_jwt(claims)
  if type(claims) ~= "table" then
    return nil
  end
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
  bucket.updated = now
  rate_store[key] = bucket
  trim_rate_store(now)
  persist_rate_store()
  if max_allowed and bucket.count > max_allowed then
    return false, "rate_limited"
  end
  return true
end

local function metrics_counter(name, value)
  local m = _G.metrics
  if m and type(m.counter) == "function" then
    pcall(m.counter, name, value or 1)
  end
end

local function caller_identity(msg)
  -- prefer verified identity (JWT subject), then signature reference, else envelope actor/gateway/ip
  if msg._jwt_sub and msg._jwt_sub ~= "" then
    return "jwt:" .. tostring(msg._jwt_sub)
  end
  local sig_ref = msg.signatureRef or msg["Signature-Ref"]
  if sig_ref and sig_ref ~= "" then
    return "sig:" .. tostring(sig_ref)
  end
  if (not REQUIRE_SIGNATURE and not REQUIRE_JWT) and Auth.resolve_actor(msg) then
    return "actor:" .. tostring(Auth.resolve_actor(msg))
  end
  if Auth.gateway_id(msg) then
    return "gw:" .. tostring(Auth.gateway_id(msg))
  end
  if msg.ip or msg.IP then
    return "ip:" .. tostring(msg.ip or msg.IP)
  end
  return "anon"
end

local function extract_subject(msg)
  if msg.subject or msg.Subject then
    return tostring(msg.subject or msg.Subject)
  end
  local payload = msg.payload or msg.Payload
  if type(payload) == "table" then
    return tostring(
      payload.subject
        or payload.pageId
        or payload.orderId
        or payload.cartId
        or payload.resourceId
        or payload.paymentId
        or payload.subscriptionId
        or payload.siteId
        or payload.key
        or payload.sku
        or payload.id
    )
  end
  return nil
end

local function bump_unique_subject(ip, subject)
  if not UNIQUE_SUBJECT_MAX_PER_IP or UNIQUE_SUBJECT_MAX_PER_IP < 1 then
    return true
  end
  if not ip or ip == "" or not subject or subject == "" then
    return true
  end
  local now = os_time()
  local key = "uniqsubj:" .. tostring(ip)
  local bucket = rate_store[key] or { subjects = {}, count = 0, reset = now + RL_WINDOW }
  if now > (bucket.reset or 0) then
    bucket.subjects = {}
    bucket.count = 0
    bucket.reset = now + RL_WINDOW
  end
  if not bucket.subjects[subject] then
    bucket.subjects[subject] = now
    bucket.count = bucket.count + 1
  else
    bucket.subjects[subject] = now
  end
  bucket.updated = now
  rate_store[key] = bucket
  trim_rate_store(now)
  persist_rate_store()
  if bucket.count > UNIQUE_SUBJECT_MAX_PER_IP then
    metrics_counter("write_auth_subject_spray_total", 1)
    return false, "rate_limited"
  end
  return true
end

function Auth.rate_limit_check(msg)
  local ok, err = bump_rate("global", RL_WINDOW, RL_MAX)
  if not ok then
    return ok, err
  end
  local tenant = msg.tenant or msg.Tenant or msg["Tenant-Id"] or "global"
  local caller = caller_identity(msg)
  local key = string.format("tenant:%s:caller:%s", tenant, caller)
  local ok_caller, err_caller = bump_rate(key, RL_WINDOW, RL_CALLER_MAX)
  if not ok_caller then
    metrics_counter("write_auth_rate_limited_total", 1)
  end
  if not ok_caller then
    return ok_caller, err_caller
  end
  local ip = msg.ip or msg.IP
  local subject = extract_subject(msg)
  if ip and subject then
    local ok_subj, err_subj = bump_unique_subject(ip, subject)
    if not ok_subj then
      return ok_subj, err_subj
    end
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
    m_counter "write_outbox_hmac_missing_total"
    return false, "missing_outbox_hmac"
  end
  local expected, err = Auth.compute_outbox_hmac(msg, secret)
  if not expected then
    return false, err or "outbox_hmac_missing"
  end
  if expected:lower() ~= tostring(provided):lower() then
    m_counter "write_outbox_hmac_mismatch_total"
    return false, "outbox_hmac_mismatch"
  end
  return true
end

function Auth.require_role_or_capability(msg, roles, _caps)
  return Auth.require_role(msg, roles)
end

function Auth.check_policy(msg)
  local policy_map, policy_err, configured = ensure_signature_policy()
  if not configured then
    return true
  end
  if not policy_map then
    return false, policy_err or "signature_policy_invalid"
  end
  msg = msg or {}
  local sig_ref = msg.signatureRef or msg["Signature-Ref"] or msg.signature_ref
  if not sig_ref or sig_ref == "" then
    m_counter "write_auth_signature_policy_missing_ref_total"
    return false, "signature_policy_missing_signature_ref"
  end

  local entry = policy_map[tostring(sig_ref)]
  if not entry then
    m_counter "write_auth_signature_policy_unknown_ref_total"
    return false, "signature_policy_not_found"
  end

  local action = msg.action or msg.Action
  if not action or action == "" then
    m_counter "write_auth_signature_policy_missing_action_total"
    return false, "signature_policy_missing_action"
  end
  if entry.actions ~= "*" and not contains(entry.actions, action) then
    m_counter "write_auth_signature_policy_action_forbidden_total"
    return false, "signature_policy_action_forbidden"
  end

  if entry.roles then
    local role = msg["Actor-Role"] or msg.actorRole or msg.role
    if not role or role == "" then
      m_counter "write_auth_signature_policy_missing_role_total"
      return false, "signature_policy_missing_role"
    end
    if entry.roles ~= "*" and not contains(entry.roles, role) then
      m_counter "write_auth_signature_policy_role_forbidden_total"
      return false, "signature_policy_role_forbidden"
    end
  end

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

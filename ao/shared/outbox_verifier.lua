-- Shared outbox HMAC verifier (full or legacy modes).

local Verifier = {}

local crypto_ok, crypto = pcall(require, "ao.shared.crypto")
local auth_ok, auth = pcall(require, "ao.shared.auth")
local cjson_ok, cjson = pcall(require, "cjson")

local function is_array(tbl)
  if type(tbl) ~= "table" then
    return false
  end
  local max, count = 0, 0
  for k, _ in pairs(tbl) do
    if type(k) ~= "number" then
      return false
    end
    if k > max then
      max = k
    end
    count = count + 1
  end
  return max == count
end

local function stable_encode(val)
  local t = type(val)
  if t == "nil" then
    return "null"
  end
  if t == "boolean" or t == "number" then
    return tostring(val)
  end
  if t == "string" then
    return cjson_ok and cjson.encode(val) or string.format("%q", val)
  end
  if t == "table" then
    if is_array(val) then
      local parts = {}
      for i = 1, #val do
        parts[#parts + 1] = stable_encode(val[i])
      end
      return "[" .. table.concat(parts, ",") .. "]"
    else
      local keys = {}
      for k in pairs(val) do
        keys[#keys + 1] = k
      end
      table.sort(keys, function(a, b)
        return tostring(a) < tostring(b)
      end)
      local parts = {}
      for _, k in ipairs(keys) do
        local key_encoded = cjson_ok and cjson.encode(tostring(k))
          or string.format("%q", tostring(k))
        parts[#parts + 1] = key_encoded .. ":" .. stable_encode(val[k])
      end
      return "{" .. table.concat(parts, ",") .. "}"
    end
  end
  return "null"
end

local function stable_encode_without_hmac(ev)
  if type(ev) ~= "table" then
    return stable_encode(ev)
  end
  local copy = {}
  for k, v in pairs(ev) do
    if k ~= "hmac" and k ~= "Hmac" and k ~= "hMAC" then
      copy[k] = v
    end
  end
  return stable_encode(copy)
end

local function legacy_payload(ev)
  if auth_ok and auth.compute_outbox_hmac then
    return auth.compute_outbox_hmac(ev, ev.__secret_override)
  end
  local parts = {
    ev.siteId or "",
    ev.pageId or ev.orderId or "",
    ev.versionId or ev.amount or "",
  }
  return table.concat(parts, "|")
end

local function pick_mode(mode)
  if mode == "legacy" then
    return "legacy"
  end
  return "full"
end

function Verifier.compute(event, opts)
  opts = opts or {}
  local secret = opts.secret or os.getenv "OUTBOX_HMAC_SECRET"
  if not secret or secret == "" then
    if opts.require_secret then
      return nil, "missing_secret"
    end
    return nil, "no_secret"
  end
  local mode = pick_mode(opts.mode or os.getenv "WRITE_OUTBOX_HMAC_MODE")
  if mode == "legacy" then
    if auth_ok and auth.compute_outbox_hmac then
      return auth.compute_outbox_hmac(event, secret)
    end
    if not crypto_ok or not crypto.hmac_sha256_hex then
      return nil, "crypto_missing"
    end
    event.__secret_override = secret
    local payload = legacy_payload(event)
    event.__secret_override = nil
    return crypto.hmac_sha256_hex(payload, secret)
  end
  if not crypto_ok or not crypto.hmac_sha256_hex then
    return nil, "crypto_missing"
  end
  return crypto.hmac_sha256_hex(stable_encode_without_hmac(event), secret)
end

function Verifier.verify(event, opts)
  opts = opts or {}
  local strict = opts.strict or (os.getenv "WRITE_STRICT_OUTBOX_HMAC" == "1")
  local provided = event and (event.hmac or event.Hmac or event.hMAC)
  if not provided and strict then
    return false, "hmac_missing"
  end
  local expected, err = Verifier.compute(event, opts)
  if not expected then
    if err == "no_secret" and not (opts.require_secret or strict) then
      return true, "skipped_no_secret"
    end
    return false, err or "hmac_compute_failed"
  end
  if provided and tostring(expected):lower() ~= tostring(provided):lower() then
    return false, "hmac_mismatch"
  end
  return true, "ok"
end

function Verifier.make_verifier(opts)
  opts = opts or {}
  return function(ev)
    return Verifier.verify(ev, opts)
  end
end

function Verifier.canonical_without_hmac(ev)
  return stable_encode_without_hmac(ev)
end

return Verifier

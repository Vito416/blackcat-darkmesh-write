local crypto = require "ao.shared.crypto"
local cjson = require "cjson"

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
    return cjson.encode(val)
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
        parts[#parts + 1] = cjson.encode(tostring(k)) .. ":" .. stable_encode(val[k])
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
    if k ~= "hmac" then
      copy[k] = v
    end
  end
  return stable_encode(copy)
end

local function legacy_payload(ev)
  return (ev.siteId or "")
    .. "|"
    .. (ev.pageId or ev.orderId or "")
    .. "|"
    .. (ev.versionId or ev.amount or "")
end

local function verify(ev, mode, strict, secret)
  secret = secret or "secret"
  mode = mode or "full"
  if strict and not ev.hmac then
    return false, "hmac_missing"
  end
  if ev.hmac then
    local msg = mode == "legacy" and legacy_payload(ev) or stable_encode_without_hmac(ev)
    local expected = crypto.hmac_sha256_hex(msg, secret)
    if not expected or expected:lower() ~= tostring(ev.hmac):lower() then
      return false, "hmac_mismatch"
    end
  end
  return true, "ok"
end

local secret = "secret"

local full_event = {
  requestId = "rid-1",
  type = "PublishPageVersion",
  siteId = "s1",
  pageId = "home",
  versionId = "v1",
  payload = { manifest = { tx = "tx1", size = 123 }, tags = { "a", "b" } },
}
full_event.hmac = crypto.hmac_sha256_hex(stable_encode_without_hmac(full_event), secret)

local ok, why = verify(full_event, "full", false, secret)
assert(ok, "full hmac should verify: " .. tostring(why))

local legacy_event = {
  siteId = "s2",
  pageId = "home",
  versionId = "v2",
  amount = nil,
}
legacy_event.hmac = crypto.hmac_sha256_hex(legacy_payload(legacy_event), secret)
local ok_legacy, why_legacy = verify(legacy_event, "legacy", false, secret)
assert(ok_legacy, "legacy hmac should verify: " .. tostring(why_legacy))
local ok_full_wrong, why_full_wrong = verify(legacy_event, "full", false, secret)
assert(
  not ok_full_wrong and why_full_wrong == "hmac_mismatch",
  "legacy hmac must fail in full mode"
)

local strict_missing = { siteId = "s3" }
local ok_strict, why_strict = verify(strict_missing, "full", true, secret)
assert(not ok_strict and why_strict == "hmac_missing", "strict mode should reject missing hmac")

local tampered = cjson.decode(cjson.encode(full_event))
tampered.payload.manifest.tx = "tx2"
local ok_tampered, why_tampered = verify(tampered, "full", false, secret)
assert(not ok_tampered and why_tampered == "hmac_mismatch", "tampering should be detected")

print "outbox_hmac_spec: ok"

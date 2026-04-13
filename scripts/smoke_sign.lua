-- Generate ed25519 signature for write commands using sodium (preferred) or openssl.
-- Env:
--   WRITE_SIG_PRIV_HEX (required)
--   WRITE_SIG_REF (optional, default "write-ed25519-test")
--
-- Input: JSON on stdin with fields action/tenant/actor/nonce/role/ts/payload/requestId
-- Output: JSON with signature, signatureRef, cmd

local cjson = require "cjson.safe"
local ok_sodium, sodium = pcall(require, "sodium")
local openssl_ok, openssl = pcall(require, "openssl")

local function canonical_payload(v)
  local t = type(v)
  if t == "table" then
    local keys = {}
    for k in pairs(v) do
      keys[#keys + 1] = k
    end
    table.sort(keys, function(a, b)
      return tostring(a) < tostring(b)
    end)
    local parts = {}
    for _, k in ipairs(keys) do
      parts[#parts + 1] = string.format("%q:%s", k, canonical_payload(v[k]))
    end
    return "{" .. table.concat(parts, ",") .. "}"
  elseif t == "string" then
    return string.format("%q", v)
  elseif t == "number" or t == "boolean" then
    return tostring(v)
  end
  return "null"
end

local function canonical_detached(cmd)
  return table.concat({
    cmd.action or cmd.Action or "",
    cmd.tenant or cmd.Tenant or cmd["Tenant-Id"] or "",
    cmd.actor or cmd.Actor or "",
    cmd.ts or cmd.timestamp or cmd["X-Timestamp"] or "",
    cmd.nonce or cmd.Nonce or cmd["X-Nonce"] or "",
    cmd.role or cmd.Role or cmd["Actor-Role"] or "",
    canonical_payload(cmd.payload or cmd.Payload or {}),
    cmd.requestId or cmd["Request-Id"] or "",
  }, "|")
end

local function read_all()
  local data = {}
  while true do
    local chunk = io.read "*l"
    if not chunk then
      break
    end
    table.insert(data, chunk)
  end
  return table.concat(data, "\n")
end

local priv = os.getenv "WRITE_SIG_PRIV_HEX"
if not priv or #priv ~= 64 then
  io.stderr:write "WRITE_SIG_PRIV_HEX (64 hex chars) required\n"
  os.exit(1)
end

local ref = os.getenv "WRITE_SIG_REF" or "write-ed25519-test"
local raw = read_all()
local cmd = cjson.decode(raw or "{}") or {}
local msg = canonical_detached(cmd)

local sig_hex
if ok_sodium and sodium.crypto_sign_detached then
  local sig = sodium.crypto_sign_detached(msg, sodium.from_hex(priv))
  sig_hex = sodium.to_hex(sig)
elseif openssl_ok and openssl.sign then
  local key = openssl.pkey.new { type = "ed25519", private = priv }
  local sig = openssl.sign.detached(msg, key)
  sig_hex = openssl.hex(sig)
else
  io.stderr:write "no ed25519 provider available (sodium or openssl)\n"
  os.exit(1)
end

print(cjson.encode { signature = sig_hex, signatureRef = ref, cmd = cmd })

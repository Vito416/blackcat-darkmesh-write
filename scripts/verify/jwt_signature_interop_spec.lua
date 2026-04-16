-- luacheck: max_line_length 220
package.path =
  table.concat({ "?.lua", "?/init.lua", "ao/?.lua", "ao/?/init.lua", package.path }, ";")

if os.getenv "WRITE_REQUIRE_SIGNATURE" ~= "1" then
  print "jwt_signature_interop_spec: skipped (WRITE_REQUIRE_SIGNATURE must be 1)"
  os.exit(0)
end
if os.getenv "WRITE_REQUIRE_JWT" ~= "1" then
  print "jwt_signature_interop_spec: skipped (WRITE_REQUIRE_JWT must be 1)"
  os.exit(0)
end
if not os.getenv "WRITE_SIG_PRIV_HEX" or not os.getenv "WRITE_SIG_PUBLIC" then
  print "jwt_signature_interop_spec: skipped (WRITE_SIG_PRIV_HEX/WRITE_SIG_PUBLIC missing)"
  os.exit(0)
end
if not os.getenv "WRITE_JWT_HS_SECRET" or os.getenv "WRITE_JWT_HS_SECRET" == "" then
  print "jwt_signature_interop_spec: skipped (WRITE_JWT_HS_SECRET missing)"
  os.exit(0)
end

local ok_mime, mime = pcall(require, "mime")

local ok_cjson, cjson = pcall(require, "cjson.safe")
if not ok_cjson or not cjson then
  print "jwt_signature_interop_spec: skipped (cjson missing)"
  os.exit(0)
end

local crypto = require "ao.shared.crypto"
local write = require "ao.write.process"
local sign = require "scripts.verify._test_sign"

local b64chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local function b64(str)
  if ok_mime and mime and mime.b64 then
    return mime.b64(str)
  end
  return (
    (str:gsub(".", function(x)
      local r, byte = "", x:byte()
      for i = 8, 1, -1 do
        r = r .. (byte % 2 ^ i - byte % 2 ^ (i - 1) > 0 and "1" or "0")
      end
      return r
    end) .. "0000"):gsub("%d%d%d?%d?%d?%d?", function(x)
      if #x < 6 then
        return ""
      end
      local c = tonumber(x, 2)
      return b64chars:sub(c + 1, c + 1)
    end) .. ({ "", "==", "=" })[#str % 3 + 1]
  )
end

local function b64url(str)
  return b64(str):gsub("+", "-"):gsub("/", "_"):gsub("=", "")
end

local function sign_jwt(payload, secret)
  local header = b64url '{"alg":"HS256","typ":"JWT"}'
  local body = b64url(cjson.encode(payload))
  local signing = header .. "." .. body
  local sig_hex = crypto.hmac_sha256_hex(signing, secret)
  local sig = sig_hex:gsub("%x%x", function(x)
    return string.char(tonumber(x, 16))
  end)
  return signing .. "." .. b64url(sig)
end

local now = os.time()
local tenant = "jwt-tenant-interop"
local actor = "jwt-actor-interop"
local token = sign_jwt({
  sub = actor,
  tenant = tenant,
  role = "admin",
  exp = now + 600,
}, os.getenv "WRITE_JWT_HS_SECRET")

local cmd = {
  Action = "GetOpsHealth",
  ["Request-Id"] = "jwt-sig-interop-1",
  actor = actor,
  tenant = tenant,
  nonce = "nonce-jwt-sig-interop-1",
  ts = now,
  payload = {},
  jwt = token,
}
sign.maybe_sign(cmd)
local res = write.route(cmd)
assert(res and res.status == "OK", "jwt+signature interop should pass without explicit Actor-Role")

print "jwt_signature_interop_spec: ok"

-- luacheck: max_line_length 220
-- Minimal JWT mapping check.
-- Run with:
-- WRITE_REQUIRE_JWT=1 WRITE_JWT_HS_SECRET=dev-secret lua5.4 scripts/verify/jwt_actor_spec.lua

if os.getenv "WRITE_REQUIRE_JWT" ~= "1" then
  print "jwt_actor_spec: skipped (WRITE_REQUIRE_JWT must be 1)"
  os.exit(0)
end

local secret = os.getenv "WRITE_JWT_HS_SECRET"
if not secret or secret == "" then
  print "jwt_actor_spec: skipped (WRITE_JWT_HS_SECRET missing)"
  os.exit(0)
end

local ok_mime, _ = pcall(require, "mime")
if not ok_mime then
  print "jwt_actor_spec: skipped (mime module missing)"
  os.exit(0)
end

local auth = require "ao.shared.auth"
local ok_cjson, cjson = pcall(require, "cjson.safe")
if not ok_cjson then
  print "jwt_actor_spec: skipped (cjson missing)"
  os.exit(0)
end

local crypto = require "ao.shared.crypto"
local ok_mime2, mime = pcall(require, "mime")
local b64chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local function b64(str)
  if ok_mime2 and mime.b64 then
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
local function sign(payload, sec)
  local header = b64url '{"alg":"HS256","typ":"JWT"}'
  local body = b64url(cjson.encode(payload))
  local signing = header .. "." .. body
  local sig_hex = crypto.hmac_sha256_hex(signing, sec)
  local sig = sig_hex:gsub("%x%x", function(x)
    return string.char(tonumber(x, 16))
  end)
  return signing .. "." .. b64url(sig)
end

local token = sign({
  sub = "jwt-editor-1",
  tenant = "jwt-tenant-1",
  role = "editor",
  exp = os.time() + 600,
}, secret)

local msg = { jwt = token }
local ok, claims = auth.consume_jwt(msg)
assert(ok, "jwt validation failed: " .. tostring(claims))
assert(msg.actor == "jwt-editor-1", "actor not mapped")
assert(msg.tenant == "jwt-tenant-1", "tenant not mapped")
assert(msg["Actor-Role"] == "editor", "role not mapped")
print "jwt_actor_spec: ok"
-- luacheck: max_line_length 200

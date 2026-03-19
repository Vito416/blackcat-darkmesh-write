-- luacheck: max_line_length 200
-- JWT expiry & claim consistency spec.
-- Run with: WRITE_REQUIRE_JWT=1 WRITE_JWT_HS_SECRET=dev-secret lua5.4 scripts/verify/jwt_expiry_spec.lua

local ok_mime, mime = pcall(require, "mime")
local cjson_ok, cjson = pcall(require, "cjson.safe")
if not cjson_ok then
  print "jwt_expiry_spec: skipped (cjson missing)"
  os.exit(0)
end

local crypto = require "ao.shared.crypto"
local auth = require "ao.shared.auth"

local secret = os.getenv "WRITE_JWT_HS_SECRET" or "dev-secret"

local b64chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local function b64(str)
  if ok_mime and mime.b64 then
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

local function sign(payload)
  local header = b64url '{"alg":"HS256","typ":"JWT"}'
  local body = b64url(cjson.encode(payload))
  local signing = header .. "." .. body
  local sig_hex = crypto.hmac_sha256_hex(signing, secret)
  local sig = sig_hex:gsub("%x%x", function(x)
    return string.char(tonumber(x, 16))
  end)
  local token = signing .. "." .. b64url(sig)
  return token
end

local now = os.time()

-- valid token
local valid_token = sign {
  sub = "jwt-editor-1",
  tenant = "jwt-tenant-1",
  role = "editor",
  exp = now + 600,
  iat = now - 30,
  nbf = now - 10,
}
local ok, claims = auth.consume_jwt { jwt = valid_token }
assert(ok, "valid jwt should pass: " .. tostring(claims))

-- expired token
local expired_token = sign {
  sub = "jwt-editor-1",
  tenant = "jwt-tenant-1",
  role = "editor",
  exp = now - 10,
  iat = now - 60,
  nbf = now - 60,
}
local ok_exp, err_exp = auth.consume_jwt { jwt = expired_token }
assert(not ok_exp and err_exp == "jwt_expired", "expected jwt_expired, got " .. tostring(err_exp))

-- mismatch actor (only fails when REQUIRE_JWT=1)
local msg = {
  jwt = sign { sub = "jwt-actor-x", tenant = "jwt-tenant-1", role = "editor", exp = now + 600 },
  actor = "jwt-editor-1",
}
local ok_mis, err_mis = auth.consume_jwt(msg)
assert(
  not ok_mis and err_mis == "jwt_actor_mismatch",
  "expected jwt_actor_mismatch, got " .. tostring(err_mis)
)

print "jwt_expiry_spec: ok"
-- luacheck: max_line_length 200

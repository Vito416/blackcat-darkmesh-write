-- luacheck: max_line_length 200
-- Basic signature verification stubs (ed25519/hmac where available).

local Crypto = {}

local function has(mod)
  local ok, m = pcall(require, mod)
  if ok then
    return m
  end
  return nil
end

local openssl = has "openssl"
local openssl_hmac = has "openssl.hmac"
local ed25519 = has "ed25519"

local function hmac_digest(algo, message, secret)
  local mod = (openssl and openssl.hmac) or openssl_hmac
  if not mod then
    return nil
  end
  if type(mod.digest) == "function" then
    return mod.digest(algo, message, secret, true)
  end
  if type(mod) == "function" then
    -- some builds expose hmac as a callable
    return mod(algo, message, secret, true)
  end
  return nil
end
local sodium = has "sodium"

local function sodium_decode_hex(hex)
  if not sodium or type(hex) ~= "string" then
    return nil
  end
  local clean = hex:gsub("^hex:", "")
  if sodium.from_hex then
    return sodium.from_hex(clean)
  end
  if sodium.sodium_hex2bin then
    local ok, out = pcall(sodium.sodium_hex2bin, clean)
    if ok then
      return out
    end
  end
  return nil
end

local function sodium_encode_hex(bytes)
  if not sodium or not bytes then
    return nil
  end
  if sodium.to_hex then
    return sodium.to_hex(bytes)
  end
  if sodium.sodium_bin2hex then
    local ok, out = pcall(sodium.sodium_bin2hex, bytes)
    if ok then
      return out
    end
  end
  return nil
end

local function sodium_secret(secret)
  if type(secret) ~= "string" then
    return secret
  end
  if #secret == 64 and secret:match "^[0-9a-fA-F]+$" then
    local raw = sodium_decode_hex(secret)
    if raw then
      return raw
    end
  end
  return secret
end

function Crypto.verify_ed25519(message, signature_hex, pubkey_or_path)
  if not pubkey_or_path or pubkey_or_path == "" then
    return false, "missing_pubkey"
  end

  local is_hex = pubkey_or_path:match "^hex:" or pubkey_or_path:match "^[0-9a-fA-F]+$"
  local pub_bytes

  if is_hex and sodium then
    pub_bytes = sodium_decode_hex(pubkey_or_path)
  elseif not is_hex and io.open(pubkey_or_path, "rb") then
    pub_bytes = assert(io.open(pubkey_or_path, "rb")):read "*a"
  end

  -- libsodium path (preferred)
  if sodium and sodium.crypto_sign_verify_detached and pub_bytes then
    local sig = sodium_decode_hex(signature_hex)
    if not sig then
      return false, "bad_hex"
    end
    local ok = sodium.crypto_sign_verify_detached(sig, message, pub_bytes)
    return ok, ok and nil or "bad_signature"
  end

  -- pure-lua ed25519 module path (if bundled/available in AO runtime)
  if ed25519 and ed25519.verify then
    local from_hex = ed25519.fromhex
      or function(hex)
        if type(hex) ~= "string" or #hex % 2 ~= 0 then
          return nil
        end
        return (
          hex:gsub("..", function(cc)
            return string.char(tonumber(cc, 16))
          end)
        )
      end
    local sig = from_hex(signature_hex)
    local pub = pub_bytes
    if is_hex and not pub and from_hex then
      pub = from_hex((pubkey_or_path:gsub("^hex:", "")))
    end
    if sig and pub and ed25519.verify(sig, message, pub) then
      return true
    end
    return false, "bad_signature"
  end

  -- openssl path (needs PEM file)
  if openssl and openssl.pkey and openssl.hex and not is_hex then
    local pem = assert(io.open(pubkey_or_path, "r")):read "*a"
    local pkey = openssl.pkey.read(pem, true, "public")
    local raw = openssl.hex(signature_hex)
    local ok = pkey:verify(raw, message, "NONE")
    return ok, ok and nil or "bad_signature"
  end

  return false, "ed25519_not_available"
end

function Crypto.verify_ecdsa_sha256(message, signature_hex, pubkey_path)
  if not openssl or not openssl.pkey or not openssl.digest then
    return false, "ecdsa_not_available"
  end
  local pem = assert(io.open(pubkey_path, "r")):read "*a"
  local pkey = openssl.pkey.read(pem, true, "public")
  local sig = openssl.hex(signature_hex)
  local verifier = openssl.verify.new "sha256"
  verifier:update(message)
  local ok = verifier:verify(sig, pkey)
  return ok, ok and nil or "bad_signature"
end

function Crypto.verify_hmac_sha256(message, secret, signature_hex)
  local raw = hmac_digest("sha256", message, secret)
  if raw then
    local hex = (openssl.hex and openssl.hex(raw))
      or raw:gsub(".", function(c)
        return string.format("%02x", string.byte(c))
      end)
    return hex:lower() == tostring(signature_hex):lower(), nil
  end
  if sodium and sodium.crypto_auth then
    local key = sodium_secret(secret)
    local ok, tag = pcall(sodium.crypto_auth, message, key)
    if ok and tag then
      local hex = sodium_encode_hex(tag)
        or tag:gsub(".", function(c)
          return string.format("%02x", string.byte(c))
        end)
      return hex:lower() == tostring(signature_hex):lower(), nil
    end
    return false, "hmac_not_available"
  end
  return false, "hmac_not_available"
end

function Crypto.hmac_sha256_hex(message, secret)
  local raw = hmac_digest("sha256", message, secret)
  if raw then
    return (openssl.hex and openssl.hex(raw))
      or raw:gsub(".", function(c)
        return string.format("%02x", string.byte(c))
      end)
  end
  if sodium and sodium.crypto_auth then
    local key = sodium_secret(secret)
    local ok, tag = pcall(sodium.crypto_auth, message, key)
    if not ok or not tag then
      return nil
    end
    return sodium_encode_hex(tag)
      or tag:gsub(".", function(c)
        return string.format("%02x", string.byte(c))
      end)
  end
  return nil
end

return Crypto

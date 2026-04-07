-- Verify signatureRef -> public key routing via WRITE_SIG_PUBLICS.
-- This spec uses a stub crypto backend so it does not require ed25519 libs.
--
-- Run:
--   WRITE_REQUIRE_SIGNATURE=1 \
--   WRITE_SIG_TYPE=ecdsa \
--   WRITE_SIG_PUBLICS='tenant-a=key-a.pem,tenant-b=key-b.pem,default=default.pem' \
--   lua5.4 scripts/verify/sig_publics_keyring.lua

package.path =
  table.concat({ "?.lua", "?/init.lua", "ao/?.lua", "ao/?/init.lua", package.path }, ";")

if os.getenv "WRITE_REQUIRE_SIGNATURE" ~= "1" then
  io.stderr:write "SKIP sig_publics_keyring: WRITE_REQUIRE_SIGNATURE must be 1\n"
  os.exit(0)
end

if os.getenv "WRITE_SIG_TYPE" ~= "ecdsa" then
  io.stderr:write "SKIP sig_publics_keyring: WRITE_SIG_TYPE must be ecdsa\n"
  os.exit(0)
end

if not os.getenv "WRITE_SIG_PUBLICS" or os.getenv "WRITE_SIG_PUBLICS" == "" then
  io.stderr:write "SKIP sig_publics_keyring: WRITE_SIG_PUBLICS is required\n"
  os.exit(0)
end

local seen = {}
package.loaded["ao.shared.crypto"] = {
  verify_ecdsa_sha256 = function(_message, _sig, pubkey_path)
    seen[#seen + 1] = pubkey_path
    return true
  end,
  verify_ed25519 = function()
    return false, "unexpected_ed25519_call"
  end,
  verify_hmac_sha256 = function()
    return false, "unexpected_hmac_call"
  end,
}

local write = require "ao.write.process"

local function run_case(request_id, sig_ref)
  local res = write.route {
    Action = "GetOpsHealth",
    ["Request-Id"] = request_id,
    ["Actor-Role"] = "admin",
    actor = "sig-keyring-test",
    tenant = "blackcat",
    nonce = "nonce-" .. request_id,
    ts = os.time(),
    signature = "deadbeef",
    signatureRef = sig_ref,
  }
  assert(res and res.status == "OK", "request should pass for " .. tostring(sig_ref))
end

run_case("keyring-1", "tenant-a")
assert(seen[#seen] == "key-a.pem", "tenant-a should resolve to key-a.pem")

run_case("keyring-2", "tenant-b")
assert(seen[#seen] == "key-b.pem", "tenant-b should resolve to key-b.pem")

run_case("keyring-3", "unknown-ref")
assert(seen[#seen] == "default.pem", "unknown ref should resolve to default.pem")

print "sig_publics_keyring: ok"

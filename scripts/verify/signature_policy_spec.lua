-- luacheck: max_line_length 220
-- Focused spec for signatureRef policy enforcement.

package.path =
  table.concat({ "?.lua", "?/init.lua", "ao/?.lua", "ao/?/init.lua", package.path }, ";")

local policy_json = [[
{
  "sig-editor": { "actions": ["PublishPageVersion", "UpsertRoute"], "roles": ["editor", "admin"] },
  "sig-ops": { "actions": ["RunWebhookRetries"], "roles": ["ops", "admin"] }
}
]]

package.preload["cjson"] = function()
  return {
    decode = function(raw)
      assert(raw == policy_json, "unexpected policy payload")
      return {
        ["sig-editor"] = {
          actions = { "PublishPageVersion", "UpsertRoute" },
          roles = { "editor", "admin" },
        },
        ["sig-ops"] = {
          actions = { "RunWebhookRetries" },
          roles = { "ops", "admin" },
        },
      }
    end,
  }
end

package.loaded["ao.shared.auth.getenv_override"] = function(key)
  if key == "WRITE_SIGNATURE_POLICY_JSON" or key == "AUTH_SIGNATURE_POLICY_JSON" then
    return policy_json
  end
  if key == "WRITE_SIG_PUBLICS" or key == "AUTH_SIG_PUBLICS" then
    return "sig-editor=pub-editor,sig-ops=pub-ops"
  end
  return nil
end

package.loaded["ao.shared.auth"] = nil
local auth = require "ao.shared.auth"
package.loaded["ao.shared.auth.getenv_override"] = nil

local function assert_denied(msg, expected_code)
  local ok, code = auth.check_policy(msg)
  assert(not ok, "expected policy denial for " .. tostring(msg.action))
  assert(code == expected_code, "expected " .. expected_code .. ", got " .. tostring(code))
end

local allowed, allowed_err = auth.check_policy {
  action = "PublishPageVersion",
  signatureRef = "sig-editor",
  ["Actor-Role"] = "editor",
}
assert(allowed, "allowed policy should pass: " .. tostring(allowed_err))

assert_denied({
  action = "RunWebhookRetries",
  signatureRef = "sig-editor",
  ["Actor-Role"] = "editor",
}, "signature_policy_action_forbidden")

assert_denied({
  action = "PublishPageVersion",
  signatureRef = "sig-editor",
  ["Actor-Role"] = "viewer",
}, "signature_policy_role_forbidden")

assert_denied({
  action = "PublishPageVersion",
  signatureRef = "missing-ref",
  ["Actor-Role"] = "editor",
}, "signature_policy_not_found")

print "signature_policy_spec: ok"

package.loaded["ao.shared.auth.getenv_override"] = function(key)
  if key == "WRITE_SIGNATURE_POLICY_JSON" or key == "AUTH_SIGNATURE_POLICY_JSON" then
    return policy_json
  end
  if key == "WRITE_SIG_PUBLICS" or key == "AUTH_SIG_PUBLICS" then
    return "sig-editor=pub-shared,sig-ops=pub-shared"
  end
  return nil
end

package.loaded["ao.shared.auth"] = nil
local auth_duplicate = require "ao.shared.auth"
package.loaded["ao.shared.auth.getenv_override"] = nil

local ok_duplicate, duplicate_err = auth_duplicate.check_policy {
  action = "PublishPageVersion",
  signatureRef = "sig-editor",
  ["Actor-Role"] = "editor",
}
assert(not ok_duplicate, "duplicate policy public should fail closed")
assert(
  duplicate_err == "signature_policy_duplicate_sig_public",
  "expected signature_policy_duplicate_sig_public, got " .. tostring(duplicate_err)
)

print "signature_policy_spec duplicate-public: ok"

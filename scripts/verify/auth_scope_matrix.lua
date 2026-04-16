package.path =
  table.concat({ "?.lua", "?/init.lua", "ao/?.lua", "ao/?/init.lua", package.path }, ";")

local auth = require "ao.shared.auth"
local write = require "ao.write.process"
local sign = require "scripts.verify._test_sign"

local function fail(msg)
  io.stderr:write(msg .. "\n")
  os.exit(1)
end

local function expect(condition, msg)
  if not condition then
    fail(msg)
  end
end

local function expect_err(resp, code, marker)
  expect(type(resp) == "table", "response missing")
  expect(resp.status == "ERROR", "expected ERROR status")
  if code then
    expect(resp.code == code, ("expected code %s got %s"):format(code, tostring(resp.code)))
  end
  if marker then
    expect(
      tostring(resp.message or ""):find(marker, 1, true) ~= nil,
      ("expected marker '%s' in message '%s'"):format(marker, tostring(resp.message))
    )
  end
end

local function now()
  return os.time()
end

-- 1) Route must fail closed when actor/tenant are missing and anon is disabled.
local missing_identity = write.route(sign.maybe_sign {
  Action = "GetOpsHealth",
  ["Request-Id"] = "auth-missing-identity-1",
  ["Actor-Role"] = "admin",
  nonce = "auth-missing-identity-n1",
  ts = now(),
  payload = {},
})
expect_err(missing_identity, "INVALID_INPUT")
expect(
  type(missing_identity.details) == "table"
    and #missing_identity.details >= 1
    and tostring(missing_identity.details[1]):find("missing:", 1, true) ~= nil,
  "expected missing identity details"
)

-- 2) Caller scope tenant mismatch must fail closed.
local tenant_mismatch = write.route(sign.maybe_sign {
  Action = "GetOpsHealth",
  ["Request-Id"] = "auth-caller-scope-tenant-1",
  ["Actor-Role"] = "admin",
  actor = "auth-checker",
  tenant = "tenant-a",
  nonce = "auth-caller-scope-n1",
  ts = now(),
  payload = { tenant = "tenant-b" },
})
expect_err(tenant_mismatch, "FORBIDDEN", "caller_scope_tenant_mismatch")

-- 3) Role policy strict-mode check at auth helper layer.
local strict_enabled = os.getenv "WRITE_ROLE_POLICY_STRICT" == "1"
local allowed_by_policy, allowed_err = auth.check_role_for_action(
  { action = "Ping", ["Actor-Role"] = "admin" },
  { Ping = { "admin" } }
)
expect(allowed_by_policy == true, "expected policy allow for mapped action")
expect(allowed_err == nil, "unexpected allow error")

local missing_action_ok, missing_action_err = auth.check_role_for_action(
  { action = "UnmappedAction", ["Actor-Role"] = "admin" },
  { Ping = { "admin" } }
)
if strict_enabled then
  expect(missing_action_ok == false, "strict mode should deny missing role-policy action")
  expect(missing_action_err == "role_policy_missing_action", "expected role_policy_missing_action")
else
  expect(missing_action_ok == true, "non-strict mode should allow missing role-policy action")
end

print "auth_scope_matrix: ok"

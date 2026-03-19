-- Verifies rate limit buckets are namespaced by tenant+actor.
-- luacheck: globals os.setenv
local auth = require("ao.shared.auth")

-- tighten limits for the test
if os.setenv then
  os.setenv("WRITE_RL_WINDOW_SECONDS", "60")
  os.setenv("WRITE_RL_CALLER_MAX", "1")
end

local msg1 = { tenant = "tenant-a", actor = "alice" }
assert(auth.rate_limit_check(msg1))
local ok, err = auth.rate_limit_check(msg1)
assert(not ok and err == "rate_limited", "second call should rate-limit within same tenant+actor")

local msg2 = { tenant = "tenant-b", actor = "alice" }
local ok2, err2 = auth.rate_limit_check(msg2)
assert(ok2, "separate tenant should have independent bucket: " .. tostring(err2))

print("rate_tenant_scope_spec: ok")

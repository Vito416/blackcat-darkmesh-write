-- Verifies rate limit buckets are namespaced by tenant+actor.
local auth = require("ao.shared.auth")

-- tighten limits for the test
os.setenv("WRITE_RL_WINDOW_SECONDS", "60")
os.setenv("WRITE_RL_CALLER_MAX", "1")

local msg1 = { tenant = "tenant-a", actor = "alice" }
assert(auth.rate_limit_check(msg1))
local ok, err = auth.rate_limit_check(msg1)
assert(not ok and err == "rate_limited", "second call should rate-limit within same tenant+actor")

local msg2 = { tenant = "tenant-b", actor = "alice" }
local ok2, err2 = auth.rate_limit_check(msg2)
assert(ok2, "separate tenant should have independent bucket: " .. tostring(err2))

print("rate_tenant_scope_spec: ok")

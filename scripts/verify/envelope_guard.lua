package.path =
  table.concat({ "?.lua", "?/init.lua", "ao/?.lua", "ao/?/init.lua", package.path }, ";")
local write = require "ao.write.process"

local function assert_eq(a, b, msg)
  if a ~= b then
    io.stderr:write(
      (msg or "assert failed") .. string.format(" (%s ~= %s)\n", tostring(a), tostring(b))
    )
    os.exit(1)
  end
end

-- missing nonce/ts should be rejected
local bad = write.route { Action = "GetOpsHealth", ["Request-Id"] = "r1", ["Actor-Role"] = "admin" }
assert_eq(bad.status, "ERROR", "missing nonce should error")

-- valid envelope passes
local ts = os.time()
local ok = write.route {
  Action = "GetOpsHealth",
  ["Request-Id"] = "r2",
  ["Actor-Role"] = "admin",
  nonce = "n123",
  ts = ts,
}
assert_eq(ok.status, "OK", "valid envelope should succeed")
print "envelope_guard: ok"

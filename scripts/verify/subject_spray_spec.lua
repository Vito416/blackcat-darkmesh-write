local max = tonumber(os.getenv("WRITE_UNIQUE_SUBJECT_MAX_PER_IP") or "0")
if not max or max < 1 then
  io.stderr:write("[skip] WRITE_UNIQUE_SUBJECT_MAX_PER_IP not set or <1\n")
  os.exit(0)
end
package.loaded["ao.shared.auth"] = nil
local Auth = require "ao.shared.auth"
local ip = "10.0.0.1"
-- fill up to the limit
for i = 1, max do
  local ok, err = Auth.rate_limit_check {
    ip = ip,
    subject = "s" .. tostring(i),
  }
  assert(ok, err or "unexpected_rate_limit_before_cap")
end
-- next distinct subject should be blocked
local ok, err = Auth.rate_limit_check {
  ip = ip,
  subject = "s" .. tostring(max + 1),
}
assert(ok == false, "expected rate limited on subject spray")
assert(err == "rate_limited", "expected rate_limited, got " .. tostring(err))
print("subject_spray_spec: ok")

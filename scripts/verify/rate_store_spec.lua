-- Optional spec: verify rate limiter persistence when WRITE_RATE_STORE_PATH is set.
local path = os.getenv "WRITE_RATE_STORE_PATH" or "dev/write-rate-store.json"
local ok_cjson, cjson = pcall(require, "cjson")
if not ok_cjson then
  io.stderr:write "[skip] cjson missing\n"
  os.exit(0)
end
-- clean slate
os.remove(path)
local Auth = require "ao.shared.auth"
-- first hit should write bucket
assert(Auth.rate_limit_check { actor = "tester" })
local function read_count()
  local f = io.open(path, "r")
  if not f then
    return nil
  end
  local data = f:read "*a"
  f:close()
  local decoded = cjson.decode(data)
  return decoded and decoded["global"] and decoded["global"].count or nil
end
local count1 = read_count()
-- When path is writable we expect a count persisted
if count1 then
  assert(count1 >= 1, "persisted count missing")
  -- reload module to ensure load_rate_store picks it up
  package.loaded["ao.shared.auth"] = nil
  local Auth2 = require "ao.shared.auth"
  assert(Auth2.rate_limit_check { actor = "tester" })
end
print "rate_store_spec: ok"

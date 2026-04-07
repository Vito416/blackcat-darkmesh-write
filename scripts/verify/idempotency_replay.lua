package.path =
  table.concat({ "?.lua", "?/init.lua", "ao/?.lua", "ao/?/init.lua", package.path }, ";")
local write = require "ao.write.process"
local sign = require "scripts.verify._test_sign"

local function expect_ok(res, msg)
  if not (res and res.status == "OK") then
    io.stderr:write(msg .. "\n")
    os.exit(1)
  end
end

local req = {
  Action = "PublishPageVersion",
  ["Request-Id"] = "idem-1",
  ["Actor-Role"] = "admin",
  actor = "idem-tester",
  tenant = "tenant-idem",
  nonce = "nid1",
  ts = os.time(),
  payload = { siteId = "sidem", pageId = "home", versionId = "v-idem", manifestTx = "tx-idem" },
}
sign.maybe_sign(req)
local first = write.route(req)
expect_ok(first, "first call failed")
local second = write.route(req)
expect_ok(second, "second call failed")
if first ~= second then
  io.stderr:write "idempotent replay returned different table reference"
  os.exit(1)
end
print "idempotency_replay: ok"

package.path =
  table.concat({ "?.lua", "?/init.lua", "ao/?.lua", "ao/?/init.lua", package.path }, ";")
local write = require "ao.write.process"
local idem = require "ao.shared.idempotency"
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

-- Backward-compatibility: pre-existing requestId-only idempotency entries
-- should still be replayed after composite key rollout.
local legacy_response = {
  status = "OK",
  requestId = "idem-legacy",
  code = "OK",
  output = { legacy = true },
}
local ok_record = idem.record("idem-legacy", legacy_response)
if not ok_record then
  io.stderr:write "failed to seed legacy idempotency entry"
  os.exit(1)
end

local legacy_req = {
  Action = "PublishPageVersion",
  ["Request-Id"] = "idem-legacy",
  ["Actor-Role"] = "admin",
  actor = "idem-tester",
  tenant = "tenant-idem",
  nonce = "nid-legacy",
  ts = os.time(),
  payload = {
    siteId = "sidem",
    pageId = "legacy",
    versionId = "v-legacy",
    manifestTx = "tx-legacy",
  },
}
sign.maybe_sign(legacy_req)
local legacy_hit = write.route(legacy_req)
expect_ok(legacy_hit, "legacy idempotency replay failed")
if legacy_hit ~= legacy_response then
  io.stderr:write "legacy idempotency key should return pre-existing cached response"
  os.exit(1)
end

print "idempotency_replay: ok"

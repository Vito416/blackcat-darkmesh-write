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
local legacy_alias = idem.lookup "idem-1"
if legacy_alias ~= first then
  io.stderr:write "legacy requestId alias should be recorded for new idempotency entries"
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

-- Regression: non-string requestId values must not crash idempotency key creation.
local numeric_req = {
  Action = "PublishPageVersion",
  ["Request-Id"] = 987654,
  ["Actor-Role"] = "admin",
  actor = "idem-tester",
  tenant = "tenant-idem",
  nonce = "nid-num",
  ts = os.time(),
  payload = {
    siteId = "sidem",
    pageId = "numeric",
    versionId = "v-numeric",
    manifestTx = "tx-numeric",
  },
}
sign.maybe_sign(numeric_req)
local numeric_first = write.route(numeric_req)
expect_ok(numeric_first, "numeric requestId first call failed")
local numeric_second = write.route(numeric_req)
expect_ok(numeric_second, "numeric requestId replay failed")
if numeric_first ~= numeric_second then
  io.stderr:write "numeric requestId replay should hit idempotency cache"
  os.exit(1)
end

-- Regression: requestId/tenant containing "|" must not collide.
local colliding_a = {
  Action = "PublishPageVersion",
  ["Request-Id"] = "rid|part",
  ["Actor-Role"] = "admin",
  actor = "idem-tester",
  tenant = "tenant-a",
  nonce = "nid-pipe-a",
  ts = os.time(),
  payload = {
    siteId = "sidem",
    pageId = "pipe-a",
    versionId = "v-pipe-a",
    manifestTx = "tx-pipe-a",
  },
}
sign.maybe_sign(colliding_a)
local colliding_a_first = write.route(colliding_a)
expect_ok(colliding_a_first, "pipe-collision seed A failed")

local colliding_b = {
  Action = "PublishPageVersion",
  ["Request-Id"] = "rid",
  ["Actor-Role"] = "admin",
  actor = "idem-tester",
  tenant = "part|tenant-a",
  nonce = "nid-pipe-b",
  ts = os.time(),
  payload = {
    siteId = "sidem",
    pageId = "pipe-b",
    versionId = "v-pipe-b",
    manifestTx = "tx-pipe-b",
  },
}
sign.maybe_sign(colliding_b)
local colliding_b_first = write.route(colliding_b)
expect_ok(colliding_b_first, "pipe-collision seed B failed")
if colliding_b_first == colliding_a_first then
  io.stderr:write "pipe-delimited idempotency key collision should not replay across distinct requests"
  os.exit(1)
end

print "idempotency_replay: ok"

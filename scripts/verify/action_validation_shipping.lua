-- luacheck: max_line_length 260
package.path =
  table.concat({ "?.lua", "?/init.lua", "ao/?.lua", "ao/?/init.lua", package.path }, ";")
local write = require "ao.write.process"

local function expect_error(res)
  return res and res.status == "ERROR"
end

local bad_ship = write.route {
  Action = "CreateShipment",
  ["Request-Id"] = "s1",
  ["Actor-Role"] = "admin",
  actor = "validator",
  tenant = "tenant-1",
  nonce = "ns1",
  ts = os.time(),
  payload = { orderId = "o1" },
}
assert(expect_error(bad_ship), "missing shipmentId/status should error")

local ok_ship = write.route {
  Action = "CreateShipment",
  ["Request-Id"] = "s2",
  ["Actor-Role"] = "admin",
  actor = "validator",
  tenant = "tenant-1",
  nonce = "ns2",
  ts = os.time(),
  payload = { orderId = "o1", shipmentId = "sh1", status = "pending" },
}
assert(ok_ship.status == "OK", "CreateShipment should pass")

local bad_return = write.route {
  Action = "UpsertReturnStatus",
  ["Request-Id"] = "r1",
  ["Actor-Role"] = "admin",
  actor = "validator",
  tenant = "tenant-1",
  nonce = "nr1",
  ts = os.time(),
  payload = { returnId = "ret1" },
}
assert(expect_error(bad_return), "missing status should error")

local ok_return = write.route {
  Action = "UpsertReturnStatus",
  ["Request-Id"] = "r2",
  ["Actor-Role"] = "admin",
  actor = "validator",
  tenant = "tenant-1",
  nonce = "nr2",
  ts = os.time(),
  payload = { returnId = "ret1", status = "requested" },
}
assert(ok_return.status == "OK", "UpsertReturnStatus should pass")

print "action_validation_shipping: ok"
-- luacheck: max_line_length 260
-- luacheck: max_line_length 260

-- Minimal smoke: load write process and run a no-op command to ensure auth/idempotency plumbing works.
package.path = table.concat({ "?.lua", "?/init.lua", "ao/?.lua", "ao/?/init.lua", package.path }, ";")
local process = require("ao.write.process")

local function assert_ok(resp)
  if not resp or resp.status ~= "OK" then
    io.stderr:write("Smoke failed: " .. (resp and resp.message or "nil") .. "\n")
    os.exit(1)
  end
end

local cmd = {
  requestId = "smoke-" .. tostring(os.time()),
  action = "CreateWebhook",
  tenant = "demo",
  actor = "smoke-admin",
  ["Actor-Role"] = "admin",
  payload = { tenant = "demo", url = "https://example.com/hook", events = { "test" } },
  gatewayId = "smoke-gw",
  nonce = "smoke-nonce-" .. tostring(math.random(1, 1e6)),
  ts = os.time(),
}

local resp = process.route(cmd)
assert_ok(resp)

-- PSP replay fixture: shipping webhook duplicate should trigger REPLAY on second pass
local ship = {
  requestId = "smoke-ship-" .. tostring(os.time()),
  action = "ProviderShippingWebhook",
  actor = "smoke-admin",
  ["Actor-Role"] = "admin",
  payload = { provider = "demo", eventId = "evt-smoke", shipmentId = "ship-123", orderId = "order-1", status = "shipped" },
  gatewayId = "smoke-gw",
  nonce = "smoke-nonce-" .. tostring(math.random(1, 1e6)),
  ts = os.time(),
}
local first = process.route(ship)
if first.status ~= "OK" and first.code ~= "REPLAY" then
  io.stderr:write("Smoke shipping webhook failed: " .. (first.message or "nil") .. "\n")
  os.exit(1)
end
local second = process.route(ship)
if second.status ~= "ERROR" or second.code ~= "REPLAY" then
  io.stderr:write("Replay window not enforced\n")
  os.exit(1)
end

-- ProviderWebhook replay + HMAC emit check
-- luacheck: globals os.setenv
if os.setenv then
  os.setenv("OUTBOX_HMAC_SECRET", os.getenv("OUTBOX_HMAC_SECRET") or "0123456789abcdef0123456789abcdef")
end
local pw = {
  requestId = "smoke-provider-" .. tostring(os.time()),
  action = "ProviderWebhook",
  actor = "smoke-admin",
  ["Actor-Role"] = "admin",
  payload = { provider = "demo", eventId = "evt-hmac", orderId = "ord-hmac", status = "paid" },
  gatewayId = "smoke-gw",
  nonce = "smoke-nonce-" .. tostring(math.random(1, 1e6)),
  ts = os.time(),
}
local p1 = process.route(pw)
if p1.status ~= "OK" and p1.code ~= "REPLAY" then
  io.stderr:write("ProviderWebhook smoke failed: " .. (p1.message or "nil") .. "\n")
  os.exit(1)
end
local p2 = process.route(pw)
if p2.code ~= "REPLAY" then
  io.stderr:write("ProviderWebhook replay not enforced\n")
  os.exit(1)
end

local storage = require "ao.shared.storage"
local q = storage.get("outbox_queue") or {}
if #q == 0 then
  io.stderr:write("Outbox empty after ProviderWebhook\n")
  os.exit(1)
end
-- we only assert presence; full-event HMAC is validated by forwarder in prod
local ev = q[#q].event
if not ev.Hmac then
  io.stderr:write("Outbox event missing HMAC\n")
  os.exit(1)
end
print("ingest_smoke: OK")

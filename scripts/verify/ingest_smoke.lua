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
  payload = { tenant = "demo", url = "https://example.com/hook", events = { "test" } },
  gatewayId = "smoke-gw",
  nonce = "smoke-nonce-" .. tostring(math.random(1, 1e6)),
  ts = os.time(),
}

local resp = process.route(cmd)
assert_ok(resp)
print("ingest_smoke: OK")

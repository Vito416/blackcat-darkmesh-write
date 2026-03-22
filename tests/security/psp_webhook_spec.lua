package.path =
  table.concat({ "?.lua", "?/init.lua", "ao/?.lua", "ao/?/init.lua", package.path }, ";")

local write = require "ao.write.process"
local storage = require "ao.shared.storage"

local function expect(cond, msg)
  if cond then
    return
  end
  io.stderr:write((msg or "failed") .. "\n")
  os.exit(1)
end

-- test-local env override (works even when os.setenv missing)
local overrides = {}
local real_getenv = os.getenv
os.getenv = function(k)
  if overrides[k] ~= nil then
    return overrides[k]
  end
  return real_getenv(k)
end
local function setenv(k, v)
  overrides[k] = v
  if os.setenv then
    os.setenv(k, v)
  end
end

-- test setup
setenv("WRITE_WEBHOOK_REPLAY_WINDOW", "600")
setenv("WRITE_WEBHOOK_RETRY_JITTER_PCT", "15")
setenv("WRITE_WEBHOOK_SEEN_PATH", "dev/test-webhook-seen.json")
setenv("WRITE_PSP_BREAKER_THRESHOLD", "1")
setenv("WRITE_PSP_BREAKER_COOLDOWN", "2")
setenv("WRITE_PSP_HOSTED_ONLY", "0")

local seen_path = os.getenv "WRITE_WEBHOOK_SEEN_PATH"
if seen_path then
  os.remove(seen_path)
end

-- seed a payment so webhook can map status
local create = {
  action = "CreatePaymentIntent",
  requestId = "req-create-1",
  actor = "tester",
  ["Actor-Role"] = "admin",
  tenant = "tenant-psp",
  ts = os.time(),
  nonce = "nonce-create-1",
  payload = { provider = "stripe", orderId = "ord-psp-1", amount = 10, currency = "USD" },
}
local r_create = write.route(create)
expect(r_create and r_create.status == "OK", "CreatePaymentIntent failed")

-- first webhook should process
local webhook = {
  action = "ProviderWebhook",
  requestId = "req-webhook-1",
  actor = "tester",
  ["Actor-Role"] = "admin",
  tenant = "tenant-psp",
  ts = os.time(),
  nonce = "nonce-webhook-1",
  payload = {
    provider = "stripe",
    eventId = "evt-psp-1",
    paymentId = "pay_ord-psp-1",
    eventType = "payment_intent.succeeded",
    raw = { body = "{}", headers = { ["Stripe-Signature"] = "t=0,v1=bogus" } },
  },
}
-- disable strict sig check for the test
local r1 = write.route(webhook)
expect(r1 and (r1.status == "OK" or r1.code == "RETRY_SCHEDULED"), "first webhook not accepted")

-- duplicate should be treated as replay
local r2 = write.route(webhook)
expect(r2 and r2.code == "REPLAY", "replay not blocked")

-- breaker block scenario: mark breaker open and ensure PSP is unavailable
local state = write._state()
state.psp_breakers["stripe"] = { count = 3, open_until = os.time() + 60 }
local create2 = {
  action = "CreatePaymentIntent",
  requestId = "req-create-2",
  actor = "tester",
  ["Actor-Role"] = "admin",
  tenant = "tenant-psp",
  ts = os.time(),
  nonce = "nonce-create-2",
  payload = { provider = "stripe", orderId = "ord-psp-2", amount = 5, currency = "USD" },
}
local r_block = write.route(create2)
expect(r_block and r_block.code == "PSP_UNAVAILABLE", "breaker did not block provider")

-- persistence file should exist after replay check
if seen_path then
  local f = io.open(seen_path, "r")
  expect(f ~= nil, "webhook seen file missing")
  if f then
    f:close()
  end
end

print "psp_webhook_spec: ok"

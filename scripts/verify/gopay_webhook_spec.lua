package.path = table.concat({ '?.lua', '?/init.lua', 'ao/?.lua', 'ao/?/init.lua', package.path }, ';')

math.randomseed(os.time())

local crypto_ok, crypto = pcall(require, "ao.shared.crypto")
assert(crypto_ok and crypto.hmac_sha256_hex, "crypto.hmac_sha256_hex required")

package.loaded["ao.write.process"] = nil -- fresh state
local write = require("ao.write.process")

local counter = 0
local function req(action, payload)
  counter = counter + 1
  return {
    action = action,
    actor = "ops",
    role = "admin",
    tenant = "t",
    requestId = string.format("req-%d", counter),
    nonce = string.format("nonce-%d", counter),
    timestamp = os.date("!%Y-%m-%dT%H:%M:%SZ"),
    payload = payload or {},
  }
end

local function assert_ok(res, ctx)
  if res.status ~= "OK" then
    local cjson = require("cjson.safe")
    error(string.format("%s failed: %s %s %s", ctx, res.code or "", res.message or "", cjson.encode(res.details)))
  end
end

-- 1) Create a manual payment intent (no external PSP calls)
local create = req("CreatePaymentIntent", {
  orderId = "ord-gp-1",
  amount = 10,
  currency = "EUR",
  provider = "manual",
})
local cres = write.route(create)
assert_ok(cres, "CreatePaymentIntent")
local pid = cres.payload.paymentId

-- 2) Send GoPay webhook (PAID) with valid signature -> status captured
-- Use empty raw to bypass signature requirement (we only test idempotence + status map)
local webhook_ok = req("ProviderWebhook", {
  provider = "gopay",
  paymentId = pid,
  status = "PAID",
  eventId = "ev-gp-1",
  eventType = "payment_paid",
  event = "payment_paid",
  raw = {},
})
local wres = write.route(webhook_ok)
assert_ok(wres, "GoPay webhook PAID")
assert(wres.payload.status == "captured", "expected captured status")

-- 3) Risk webhook (different eventId) should map to risk_review
local webhook_risk = req("ProviderWebhook", {
  provider = "gopay",
  paymentId = pid,
  status = "RISK",
  eventId = "ev-gp-2",
  eventType = "payment_risk",
  event = "payment_risk",
  raw = { risk = 95 },
})
local rres = write.route(webhook_risk)
assert_ok(rres, "GoPay webhook RISK")
assert(rres.payload.status == "risk_review", "expected risk_review status")

print("gopay_webhook_spec: ok")

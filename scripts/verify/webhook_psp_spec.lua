local process = require "ao.write.process"

-- Seed payments so webhooks find tracked payments
local state = process._state()
state.payments = state.payments or {}
state.payments["pi_123"] = { provider = "stripe", providerPaymentId = "pi_123" }
state.payments["pp_123"] = { provider = "paypal", providerPaymentId = "pp_123" }
state.payments["pi_replay"] = { provider = "stripe", providerPaymentId = "pi_replay" }

local stripe_ok = process.route {
  action = "ProviderWebhook",
  requestId = "rw-stripe-1",
  actor = "system",
  tenant = "t1",
  role = "admin",
  nonce = "n-stripe-1",
  timestamp = "2026-03-21T00:00:00Z",
  signatureRef = "sig",
  payload = {
    provider = "stripe",
    eventId = "evt_1",
    eventType = "payment_intent.succeeded",
    paymentId = "pi_123",
    raw = { body = '{"id":"pi_123","object":"payment_intent"}' },
  },
}
assert(stripe_ok.status == "OK", ("stripe expected OK got %s"):format(stripe_ok.status))

local paypal_ok = process.route {
  action = "ProviderWebhook",
  requestId = "rw-paypal-1",
  actor = "system",
  tenant = "t1",
  role = "admin",
  nonce = "n-paypal-1",
  timestamp = "2026-03-21T00:00:00Z",
  signatureRef = "sig",
  payload = {
    provider = "paypal",
    eventId = "evp_1",
    eventType = "PAYMENT.CAPTURE.COMPLETED",
    paymentId = "pp_123",
    raw = { body = '{"id":"pp_123","event_type":"PAYMENT.CAPTURE.COMPLETED"}' },
  },
}
assert(paypal_ok.status == "OK", ("paypal expected OK got %s"):format(paypal_ok.status))

local replay = {
  action = "ProviderWebhook",
  requestId = "rw-replay-1",
  actor = "system",
  tenant = "t1",
  role = "admin",
  nonce = "n-replay-1",
  timestamp = "2026-03-21T00:00:00Z",
  signatureRef = "sig",
  payload = {
    provider = "stripe",
    eventId = "evt_replay",
    eventType = "payment_intent.succeeded",
    paymentId = "pi_replay",
    raw = { body = '{"id":"pi_replay","object":"payment_intent"}' },
  },
}
local first = process.route(replay)
assert(first.status == "OK", ("replay first expected OK got %s"):format(first.status))

print "webhook_psp_spec: ok"

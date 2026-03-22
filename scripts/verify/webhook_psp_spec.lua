local process = require "ao.write.process"
local psp_webhooks = require "ao.shared.psp_webhooks"

local state = process._state()
local PSP_BREAKER_THRESHOLD = tonumber(os.getenv "WRITE_PSP_BREAKER_THRESHOLD" or "5")

local function reset()
  state.payments = {}
  state.order_payment = {}
  state.orders = {}
  state.webhook_seen = {}
  state.webhook_retry = {}
  state.psp_breakers = {}
  state.dlq = {}
end

local function run_webhook(name, payload)
  payload.raw = payload.raw or {}
  payload.raw.body = payload.raw.body or "{}"
  payload.raw.headers = payload.raw.headers or {}
  if payload.provider == "stripe" then
    local ok, crypto = pcall(require, "ao.shared.crypto")
    if ok and crypto.hmac_sha256_hex then
      local ts = tostring(os.time())
      local secret = os.getenv "STRIPE_WEBHOOK_SECRET" or "whsec_test"
      local sig = crypto.hmac_sha256_hex(ts .. "." .. payload.raw.body, secret)
      payload.raw.headers["Stripe-Signature"] = string.format("t=%s,v1=%s", ts, sig)
    end
  end
  return process.route {
    action = "ProviderWebhook",
    requestId = name,
    actor = "system",
    tenant = "t1",
    role = "admin",
    nonce = name .. "-nonce",
    timestamp = "2026-03-21T00:00:00Z",
    signatureRef = "sig",
    payload = payload,
  }
end

-- Baseline: stripe and paypal webhooks resolve tracked payments.
reset()
state.payments["pi_123"] = { provider = "stripe", providerPaymentId = "pi_123" }
state.payments["pp_123"] = { provider = "paypal", providerPaymentId = "pp_123" }
state.payments["pi_replay"] = { provider = "stripe", providerPaymentId = "pi_replay" }

local stripe_ok = run_webhook("rw-stripe-1", {
  provider = "stripe",
  eventId = "evt_1",
  eventType = "payment_intent.succeeded",
  paymentId = "pi_123",
  raw = { body = '{"id":"pi_123","object":"payment_intent"}' },
})
assert(stripe_ok.status == "OK", ("stripe expected OK got %s"):format(stripe_ok.status))

local paypal_ok = run_webhook("rw-paypal-1", {
  provider = "paypal",
  eventId = "evp_1",
  eventType = "PAYMENT.CAPTURE.COMPLETED",
  paymentId = "pp_123",
  raw = { body = '{"id":"pp_123","event_type":"PAYMENT.CAPTURE.COMPLETED"}' },
})
assert(paypal_ok.status == "OK", ("paypal expected OK got %s"):format(paypal_ok.status))

-- Replay guard
local replay_payload = {
  provider = "stripe",
  eventId = "evt_replay",
  eventType = "payment_intent.succeeded",
  paymentId = "pi_replay",
  raw = { body = '{"id":"pi_replay","object":"payment_intent"}' },
}
local first = run_webhook("rw-replay-1", replay_payload)
assert(first.status == "OK", ("replay first expected OK got %s"):format(first.status))
local second = run_webhook("rw-replay-2", replay_payload)
assert(second.status == "ERROR" and second.code == "REPLAY", "replay should be rejected")

-- Order status linkage: success -> paid, refund -> refunded.
reset()
local order_id = "ord-webhook-paid"
local payment_id = "pay_" .. order_id
state.orders[order_id] = { status = "draft", version = 1, currency = "USD" }
state.payments[payment_id] = {
  provider = "stripe",
  providerPaymentId = "pi_" .. order_id,
  orderId = order_id,
  status = "requires_capture",
}
state.order_payment[order_id] = payment_id

local paid = run_webhook("rw-paid-1", {
  provider = "stripe",
  eventId = "evt_paid_1",
  eventType = "payment_intent.succeeded",
  orderId = order_id,
  paymentId = payment_id,
  raw = { body = '{"id":"pi_' .. order_id .. '","object":"payment_intent"}' },
})
assert(paid.status == "OK", ("paid webhook expected OK got %s"):format(paid.status))
assert(state.payments[payment_id].status == "captured", "payment should be captured after paid webhook")
assert(state.orders[order_id].status == "paid", "order should be paid after provider success")

local refund = run_webhook("rw-refund-1", {
  provider = "stripe",
  eventId = "evt_refund_1",
  eventType = "charge.refunded",
  orderId = order_id,
  paymentId = payment_id,
  raw = { body = '{"id":"ch_' .. order_id .. '","object":"charge"}' },
})
assert(refund.status == "OK", ("refund webhook expected OK got %s"):format(refund.status))
assert(state.payments[payment_id].status == "refunded", "payment should be refunded after refund webhook")
assert(state.orders[order_id].status == "refunded", "order should be refunded after provider refund")

-- Retry/backoff queue should grow delay exponentially.
reset()
local missing = run_webhook("rw-missing-1", {
  provider = "stripe",
  eventId = "evt_missing_1",
  eventType = "payment_intent.succeeded",
  paymentId = "pi_missing",
  raw = { body = '{"id":"pi_missing","object":"payment_intent"}' },
})
assert(missing.status == "ERROR" and missing.code == "RETRY_SCHEDULED", "missing payment should schedule retry")
local first_job = state.webhook_retry[1]
assert(first_job and first_job.attempts == 1, "first retry should be recorded with attempt 1")
local first_delay = first_job.nextAttempt - os.time()
assert(first_delay >= 1, "retry should be scheduled in the future")
-- force due and run retries
state.webhook_retry[1].nextAttempt = os.time() - 1
local retry_run = process.route {
  action = "RunWebhookRetries",
  requestId = "rw-run-retries-1",
  actor = "system",
  tenant = "t1",
  role = "support",
  nonce = "rw-run-retries-1",
  timestamp = "2026-03-21T00:00:00Z",
  signatureRef = "sig",
  payload = {},
}
assert(retry_run.status == "OK", ("retry run expected OK got %s"):format(retry_run.status))
local second_job = state.webhook_retry[1]
assert(second_job and second_job.attempts == 2, "second retry attempt should be enqueued")
local second_delay = second_job.nextAttempt - os.time()
assert(second_delay > first_delay, "backoff delay should increase on each attempt")

-- Circuit breaker opens on repeated provider failures and closes after success.
reset()
local original_verify = psp_webhooks.registry.stripe.verify
psp_webhooks.registry.stripe.verify = function()
  return nil, "provider_unavailable"
end

for i = 1, PSP_BREAKER_THRESHOLD do
  local resp = run_webhook("rw-brk-" .. i, {
    provider = "stripe",
    eventId = "evt_brk_" .. i,
    eventType = "payment_intent.succeeded",
    paymentId = "pi_brk_" .. i,
    raw = { body = '{"id":"pi_brk_' .. i .. '","object":"payment_intent"}' },
  })
  assert(resp.status == "ERROR" and resp.code == "RETRY_SCHEDULED", "provider failure should schedule retry")
end

assert(
  state.psp_breakers.stripe
    and state.psp_breakers.stripe.open_until
    and state.psp_breakers.stripe.open_until > os.time(),
  "breaker should open after repeated failures"
)

-- allow breaker to cool and verify that a successful webhook closes it
state.psp_breakers.stripe.open_until = os.time() - 1
psp_webhooks.registry.stripe.verify = original_verify
state.payments["pi_cb_ok"] = { provider = "stripe", providerPaymentId = "pi_cb_ok" }
local recovered = run_webhook("rw-brk-close", {
  provider = "stripe",
  eventId = "evt_cb_ok",
  eventType = "payment_intent.succeeded",
  paymentId = "pi_cb_ok",
  raw = { body = '{"id":"pi_cb_ok","object":"payment_intent"}' },
})
assert(recovered.status == "OK", ("breaker close expected OK got %s"):format(recovered.status))
assert(
  state.psp_breakers.stripe.count == 0 and not state.psp_breakers.stripe.open_until,
  "breaker should reset after successful call"
)

print "webhook_psp_spec: ok"

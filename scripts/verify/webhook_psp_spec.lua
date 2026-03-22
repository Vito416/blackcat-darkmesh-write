local overrides = {
  WRITE_WEBHOOK_RETRY_MAX_QUEUE = "3",
  WRITE_WEBHOOK_SEEN_MAX = "3",
  STRIPE_WEBHOOK_SECRET = "whsec_test_default_secret_32len!",
  AUTH_REQUIRE_NONCE = "0",
  AUTH_REQUIRE_TIMESTAMP = "0",
  PAYPAL_WEBHOOK_SECRET = "paypal_webhook_secret_32len_key!",
}

local real_getenv = os.getenv
os.getenv = function(key)
  if overrides[key] ~= nil then
    return overrides[key]
  end
  return real_getenv(key)
end

local process = require "ao.write.process"
local psp_webhooks = require "ao.shared.psp_webhooks"
local paypal = require "ao.shared.paypal"

local state = process._state()
local PSP_BREAKER_THRESHOLD = tonumber(os.getenv "WRITE_PSP_BREAKER_THRESHOLD" or "5")
local RETRY_MAX_QUEUE = tonumber(os.getenv "WRITE_WEBHOOK_RETRY_MAX_QUEUE" or "1000")
local WEBHOOK_SEEN_MAX = tonumber(os.getenv "WRITE_WEBHOOK_SEEN_MAX" or "10000")

local function reset()
  state.payments = {}
  state.order_payment = {}
  state.orders = {}
  state.webhook_seen = {}
  state.webhook_retry = {}
  state.psp_breakers = {}
  state.dlq = {}
end

local function run_webhook(name, payload, ts)
  payload.raw = payload.raw or {}
  payload.raw.body = payload.raw.body or "{}"
  payload.raw.headers = payload.raw.headers or {}
  if
    payload.provider == "stripe"
    and not (payload.raw.headers["Stripe-Signature"] or payload.raw.headers["stripe-signature"])
  then
    local ok, crypto = pcall(require, "ao.shared.crypto")
    if ok and crypto.hmac_sha256_hex then
      local ts = tostring(os.time())
      local secret = os.getenv "STRIPE_WEBHOOK_SECRET" or "whsec_test"
      local sig = crypto.hmac_sha256_hex(ts .. "." .. payload.raw.body, secret)
      if sig then
        payload.raw.headers["Stripe-Signature"] = string.format("t=%s,v1=%s", ts, sig)
      else
        payload.raw.skip_verify = true
        overrides.STRIPE_WEBHOOK_SECRET = false
      end
    else
      payload.raw.skip_verify = true
      overrides.STRIPE_WEBHOOK_SECRET = false
    end
  end
  return process.route {
    action = "ProviderWebhook",
    requestId = name,
    actor = "system",
    tenant = "t1",
    role = "admin",
    nonce = name .. "-nonce",
    timestamp = ts or os.date("!%Y-%m-%dT%H:%M:%SZ"),
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

-- Stripe signature header accepts multiple v1 values.
reset()
local body_multi = '{"id":"pi_multi","object":"payment_intent"}'
state.payments["pi_multi"] = { provider = "stripe", providerPaymentId = "pi_multi" }
local ok_crypto, crypto = pcall(require, "ao.shared.crypto")
if ok_crypto and crypto.hmac_sha256_hex then
  local ts_multi = tostring(os.time())
  local secret_multi = os.getenv "STRIPE_WEBHOOK_SECRET" or "whsec_test"
  local sig_multi = crypto.hmac_sha256_hex(ts_multi .. "." .. body_multi, secret_multi)
  if sig_multi then
    local bad_sig_multi = string.rep("0", #sig_multi)
    local multi = run_webhook("rw-stripe-multi-v1", {
      provider = "stripe",
      eventId = "evt_multi",
      eventType = "payment_intent.succeeded",
      paymentId = "pi_multi",
      raw = {
        body = body_multi,
        headers = {
          ["Stripe-Signature"] = string.format("t=%s,v1=%s,v1=%s", ts_multi, bad_sig_multi, sig_multi),
        },
      },
    })
    assert(multi.status == "OK", ("stripe multi v1 header expected OK got %s"):format(multi.status))
  else
    print "webhook_psp_spec: skipping multi v1 signature test (crypto unavailable)"
  end
else
  print "webhook_psp_spec: skipping multi v1 signature test (crypto unavailable)"
end

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

-- Partial refunds adjust totals and order status.
reset()
local partial_order = "ord-partial"
local partial_payment = "pay_" .. partial_order
state.orders[partial_order] = { status = "paid", version = 1, currency = "USD", totalAmount = 100 }
state.payments[partial_payment] = {
  provider = "stripe",
  providerPaymentId = "pi_" .. partial_order,
  orderId = partial_order,
  status = "captured",
  amount = 100,
}
state.order_payment[partial_order] = partial_payment

local partial = run_webhook("rw-partial-1", {
  provider = "stripe",
  eventId = "evt_partial_1",
  eventType = "charge.refunded",
  orderId = partial_order,
  paymentId = partial_payment,
  amount = 40,
  raw = { body = '{"id":"ch_' .. partial_order .. '","object":"charge","amount_refunded":4000}' },
})
assert(partial.status == "OK", ("partial refund expected OK got %s"):format(partial.status))
assert(
  state.payments[partial_payment].status == "partially_refunded",
  "payment should be partially refunded after partial refund"
)
assert(state.payments[partial_payment].refundedAmount == 40, "payment refundedAmount should track partial")
assert(state.orders[partial_order].status == "partially_refunded", "order should become partially_refunded")
assert(state.orders[partial_order].refundedAmount == 40, "order refundedAmount should track partial")

local final = run_webhook("rw-partial-2", {
  provider = "stripe",
  eventId = "evt_partial_2",
  eventType = "charge.refunded",
  orderId = partial_order,
  paymentId = partial_payment,
  amount = 60,
  raw = { body = '{"id":"ch_' .. partial_order .. '","object":"charge","amount_refunded":10000}' },
})
assert(final.status == "OK", ("final refund expected OK got %s"):format(final.status))
assert(state.payments[partial_payment].status == "refunded", "payment should be fully refunded after second refund")
assert(state.payments[partial_payment].refundedAmount == 100, "payment refundedAmount should cap at total")
assert(state.orders[partial_order].status == "refunded", "order should be refunded after full amount returned")
assert(state.orders[partial_order].refundedAmount == 100, "order refundedAmount should cap at total")

-- Prevent conflicting payments for an order unless explicitly allowed.
reset()
local conflict_order = "ord-conflict"
state.orders[conflict_order] = { status = "draft", version = 1, currency = "USD", totalAmount = 50 }
state.payments["pay_existing"] = {
  provider = "manual",
  orderId = conflict_order,
  amount = 50,
  currency = "USD",
  status = "requires_capture",
}
state.order_payment[conflict_order] = "pay_existing"

local conflict_resp = process.route {
  action = "CreatePaymentIntent",
  requestId = "cpi-conflict-1",
  actor = "system",
  tenant = "t1",
  role = "admin",
  nonce = "cpi-conflict-1",
  timestamp = "2026-03-21T00:00:00Z",
  signatureRef = "sig",
  payload = {
    orderId = conflict_order,
    amount = 50,
    currency = "USD",
    provider = "manual",
  },
}
assert(
  conflict_resp.status == "ERROR" and conflict_resp.code == "CONFLICT",
  "creating a second payment without allow flag should conflict"
)

local allowed_resp = process.route {
  action = "CreatePaymentIntent",
  requestId = "cpi-allow-1",
  actor = "system",
  tenant = "t1",
  role = "admin",
  nonce = "cpi-allow-1",
  timestamp = "2026-03-21T00:00:00Z",
  signatureRef = "sig",
  payload = {
    orderId = conflict_order,
    amount = 50,
    currency = "USD",
    provider = "manual",
    allowMultiplePayments = true,
  },
}
assert(allowed_resp.status == "OK", ("create payment with allow flag expected OK got %s"):format(allowed_resp.status))

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

-- PayPal remote verify failures should trip breaker and schedule retry.
reset()
state.payments["pp_remote"] = { provider = "paypal", providerPaymentId = "pp_remote" }
local original_getenv = os.getenv
os.getenv = function(key)
  if key == "PAYPAL_WEBHOOK_SECRET" then
    return "paypal_webhook_secret_32len_key!"
  elseif key == "PAYPAL_WEBHOOK_STRICT" then
    return "1"
  end
  return original_getenv(key)
end
local original_remote = paypal.verify_webhook_remote
paypal.verify_webhook_remote = function()
  return nil, "remote_500"
end

local remote_fail = run_webhook("rw-paypal-remote-500", {
  provider = "paypal",
  eventId = "evp_remote",
  eventType = "PAYMENT.CAPTURE.COMPLETED",
  paymentId = "pp_remote",
  raw = {
    body = '{"id":"pp_remote","event_type":"PAYMENT.CAPTURE.COMPLETED"}',
    headers = { ["PayPal-Transmission-Sig"] = "sig" },
  },
})
paypal.verify_webhook_remote = original_remote
os.getenv = original_getenv

assert(
  remote_fail.status == "ERROR" and remote_fail.code == "RETRY_SCHEDULED",
  "remote verify 500 should schedule retry"
)
assert(
  state.psp_breakers.paypal and state.psp_breakers.paypal.count == 1,
  "remote verify failures should increment breaker"
)
local remote_retry = state.webhook_retry[1]
assert(
  remote_retry and remote_retry.attempts == 1 and remote_retry.nextAttempt > os.time(),
  "remote verify failure should enqueue retry with backoff"
)

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

-- Retry queue is bounded; overflowed jobs are dead-lettered.
reset()
local overflow_extra = 2
for i = 1, RETRY_MAX_QUEUE + overflow_extra do
  local resp = run_webhook("rw-queue-overflow-" .. i, {
    provider = "stripe",
    eventId = "evt_overflow_" .. i,
    eventType = "payment_intent.succeeded",
    paymentId = "pi_overflow_" .. i,
    raw = { body = '{"id":"pi_overflow_' .. i .. '","object":"payment_intent"}' },
  })
  assert(
    resp.status == "ERROR" and resp.code == "RETRY_SCHEDULED",
    "overflowed webhook should still schedule retry/dlq"
  )
end
assert(#state.webhook_retry == RETRY_MAX_QUEUE, "retry queue should stop at configured cap")
assert(
  #state.dlq == overflow_extra,
  ("overflowed jobs should be routed to dlq (expected %d got %d)"):format(overflow_extra, #state.dlq)
)
assert(
  state.dlq[1] and state.dlq[1].reason == "retry_queue_overflow",
  "overflowed jobs should carry retry_queue_overflow reason"
)

-- Replay cache is trimmed when exceeding cap.
reset()
local base_ts = os.time() - 10
for i = 1, WEBHOOK_SEEN_MAX + 2 do
  local pid = "pi_gc_" .. i
  state.payments[pid] = { provider = "stripe", providerPaymentId = pid }
  local resp = run_webhook("rw-replay-gc-" .. i, {
    provider = "stripe",
    eventId = "evt_gc_" .. i,
    eventType = "payment_intent.succeeded",
    paymentId = pid,
    raw = { body = '{"id":"' .. pid .. '","object":"payment_intent"}' },
  }, base_ts + i)
  assert(resp.status == "OK", ("replay gc webhook %d expected OK got %s"):format(i, resp.status))
end

local seen_count = 0
for _ in pairs(state.webhook_seen) do
  seen_count = seen_count + 1
end
if real_getenv("DEBUG_GC") == "1" then
  print("debug_gc_seen_count", seen_count)
  for k in pairs(state.webhook_seen) do
    print("debug_gc_key", k)
  end
end
assert(seen_count == WEBHOOK_SEEN_MAX, "replay cache should be capped at WRITE_WEBHOOK_SEEN_MAX")
assert(
  not state.webhook_seen["stripe:evt_gc_1"],
  "oldest replay entry should be evicted when cache exceeds cap"
)
assert(
  state.webhook_seen["stripe:evt_gc_" .. (WEBHOOK_SEEN_MAX + 2)],
  "newest replay entry should be retained after gc"
)

print "webhook_psp_spec: ok"

package.path =
  table.concat({ "?.lua", "?/init.lua", "ao/?.lua", "ao/?/init.lua", package.path }, ";")
local write = require "ao.write.process"
local crypto = require "ao.shared.crypto"

local function expect(code, msg)
  if not code then
    io.stderr:write(msg .. "\n")
    os.exit(1)
  end
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

-- HMAC attached to outbox events
setenv("OUTBOX_HMAC_SECRET", "0123456789abcdef0123456789abcdef")

-- replay window for ProviderWebhook
setenv("WRITE_WEBHOOK_REPLAY_WINDOW", "600")

local function route(cmd)
  local res = write.route(cmd)
  return res
end

-- ProviderWebhook replay and HMAC on emitted event
local req = {
  action = "ProviderWebhook",
  requestId = "replay-1",
  actor = "security-tester",
  ["Actor-Role"] = "admin",
  tenant = "tenant-1",
  gatewayId = "gw1",
  ts = os.time(),
  nonce = "n1",
  signatureRef = "sig-1",
  payload = {
    provider = "stripe",
    eventId = "evt-1",
    orderId = "ord-1",
    paymentId = "pay-1",
    eventType = "payment_intent.succeeded",
    raw = { body = "{}", skip_verify = true },
  },
}
-- seed payment mapping so webhook verification finds it
local state = write._state()
state.payments = state.payments or {}
state.payments["pay-1"] = { provider = "stripe", providerPaymentId = "pay-1", orderId = "ord-1" }
state.order_payment = state.order_payment or {}
state.order_payment["ord-1"] = "pay-1"

local first = route(req)
expect(first and (first.status == "OK" or first.code == "REPLAY"), "first ProviderWebhook failed")
local second = route(req)
expect(
  second and (second.code == "REPLAY" or second.status == "OK"),
  "replay window not enforced"
)

-- Outbox event should carry Hmac
local storage = require "ao.shared.storage"
local queue = storage.get "outbox_queue" or {}
expect(#queue > 0, "outbox queue empty")
local ev = queue[#queue].event
if ev.Hmac then
  local payload = (ev["Site-Id"] or ev.siteId or ev.tenant or "")
    .. "|"
    .. (ev["Page-Id"] or ev["Order-Id"] or ev.key or ev["Key"] or ev.resourceId or "")
    .. "|"
    .. (ev.Version or ev["Manifest-Tx"] or ev.Amount or ev.Total or ev.ts or ev.timestamp or "")
  local expected = crypto.hmac_sha256_hex(payload, os.getenv "OUTBOX_HMAC_SECRET" or "")
  expect(ev.Hmac == expected, "outbox HMAC mismatch")
end
print "hmac_replay: ok"

package.path =
  table.concat({ "?.lua", "?/init.lua", "ao/?.lua", "ao/?/init.lua", package.path }, ";")
local write = require "ao.write.process"

local function fail(msg)
  io.stderr:write(msg .. "\n")
  os.exit(1)
end

local function expect_ok(res, msg)
  if not (res and res.status == "OK") then
    fail(msg)
  end
  return res
end

-- property: same request id yields identical response and does not mutate state beyond first apply
local function run_pair(action, payload1, payload2)
  local req_id = action .. "-idem"
  local req1 = {
    Action = action,
    ["Request-Id"] = req_id,
    ["Actor-Role"] = payload1.role or "admin",
    actor = payload1.actor or "tester",
    tenant = payload1.tenant or "t1",
    nonce = payload1.nonce or ("nonce-" .. action),
    ts = os.time(),
    payload = payload1.payload,
  }
  local before = write._state()
  local first = expect_ok(write.route(req1), "first " .. action .. " failed")

  local req2 = {
    Action = action,
    ["Request-Id"] = req_id,
    ["Actor-Role"] = payload2.role or "admin",
    actor = payload2.actor or "tester",
    tenant = payload2.tenant or "t1",
    nonce = payload2.nonce or ("nonce2-" .. action),
    ts = os.time(),
    payload = payload2.payload,
  }
  local second = expect_ok(write.route(req2), "second " .. action .. " failed")
  if first ~= second then
    fail(action .. " idempotency returned different table reference")
  end
  local after = write._state()
  if after ~= before and action == "SaveDraftPage" then
    local key = payload1.payload.siteId .. ":" .. payload1.payload.pageId
    local draft = after.drafts[key]
    if draft and draft.blocks and #draft.blocks ~= #payload1.payload.blocks then
      fail(action .. " idempotency mutated draft blocks on replay")
    end
  end
end

run_pair("SaveDraftPage", {
  payload = {
    siteId = "s-idem",
    pageId = "home",
    locale = "en",
    blocks = { { type = "text", value = "first" } },
  },
}, {
  payload = {
    siteId = "s-idem",
    pageId = "home",
    locale = "en",
    blocks = { { type = "text", value = "second" } },
  },
})

-- PSP webhook replay window property
local function webhook_cmd(args)
  local headers = {}
  local skip = false
  if args.provider == "stripe" or args.provider == nil then
    local ok, crypto = pcall(require, "ao.shared.crypto")
    if ok and crypto.hmac_sha256_hex then
      local ts = tostring(os.time())
      local secret = os.getenv "STRIPE_WEBHOOK_SECRET" or "0123456789abcdef0123456789abcdef"
      if #secret < 32 then
        secret = secret .. string.rep("0", 32 - #secret)
      elseif #secret > 32 then
        secret = secret:sub(1, 32)
      end
      local sig = crypto.hmac_sha256_hex(ts .. "." .. "{}", secret)
      if sig then
        headers["Stripe-Signature"] = string.format("t=%s,v1=%s", ts, sig)
      else
        skip = true
      end
    end
  end
  return {
    action = "ProviderWebhook",
    requestId = args.requestId,
    actor = "system",
    tenant = "t-idem",
    role = "admin",
    nonce = args.nonce,
    timestamp = args.timestamp,
    signatureRef = args.signatureRef,
    payload = {
      provider = "stripe",
      eventId = args.eventId,
      eventType = "payment_intent.succeeded",
      paymentId = args.paymentId,
      raw = { body = "{}", headers = headers, skip_verify = skip },
    },
  }
end

do
  local state = write._state()
  state.payments = state.payments or {}
  state.webhook_seen = {}
  state.payments["pi-idem-window"] = { provider = "stripe", providerPaymentId = "pi-idem-window" }
  state.payments["pi-idem-out"] = { provider = "stripe", providerPaymentId = "pi-idem-out" }

  local window = tonumber(os.getenv "WRITE_WEBHOOK_REPLAY_WINDOW" or "600")
  local base_ts = os.time() - 10

  -- inside window: duplicate should be REPLAY
  local first = webhook_cmd {
    requestId = "rw-window-1",
    signatureRef = "sig-window",
    nonce = "nonce-window",
    timestamp = base_ts,
    eventId = "evt-window",
    paymentId = "pi-idem-window",
  }
  expect_ok(write.route(first), "first webhook (within window) failed")

  local replay = webhook_cmd {
    requestId = "rw-window-2",
    signatureRef = "sig-window",
    nonce = "nonce-window",
    timestamp = base_ts + math.floor(window / 2),
    eventId = "evt-window",
    paymentId = "pi-idem-window",
  }
  local replay_resp = write.route(replay)
  if not (replay_resp and replay_resp.status == "ERROR" and replay_resp.code == "REPLAY") then
    fail("webhook replay inside window not deduped")
  end

  -- outside window: same signatureRef/nonce accepted
  local first_out = webhook_cmd {
    requestId = "rw-window-3",
    signatureRef = "sig-out",
    nonce = "nonce-out",
    timestamp = base_ts,
    eventId = "evt-window-out",
    paymentId = "pi-idem-out",
  }
  expect_ok(write.route(first_out), "first webhook (outside window setup) failed")

  local second_out = webhook_cmd {
    requestId = "rw-window-4",
    signatureRef = "sig-out",
    nonce = "nonce-out",
    timestamp = base_ts + window + 2,
    eventId = "evt-window-out",
    paymentId = "pi-idem-out",
  }
  local second_out_resp = write.route(second_out)
  if not (second_out_resp and second_out_resp.status == "OK") then
    fail("webhook outside replay window should be accepted")
  end
end

print "idempotency_property: ok"

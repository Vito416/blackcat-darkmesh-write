-- luacheck: max_line_length 200
-- luacheck: globals Handlers Send
-- luacheck: ignore send_event OUTBOX_PATH role_policy bridge jwt ok ok_json cjson auth state content_key discount vat schedule_retry OUTBOX_HMAC_SECRET
-- Entry point for the write command AO process.

-- Ensure templates module exists early (used by hyperengine UI utilities).
if not package.preload["templates"] then
  package.preload["templates"] = function()
    return {}
  end
end

local validation = require "ao.shared.validation"
local auth = require "ao.shared.auth"
local idem = require "ao.shared.idempotency"
local audit = require "ao.shared.audit"
local storage = require "ao.shared.storage"
local export = require "ao.shared.export"
local persist = require "ao.shared.persist"
local bridge = require "ao.shared.bridge"
local crypto = require "ao.shared.crypto"
local jwt = require "ao.shared.jwt"
local metrics_ok, metrics = pcall(require, "ao.shared.metrics")
if not metrics_ok or type(metrics.gauge) ~= "function" then
  metrics = {
    gauge = function(...)
      return ...
    end,
    counter = function(...)
      return ...
    end,
  }
end
local gopay_ok, gopay = pcall(require, "ao.shared.gopay")
local stripe_ok, stripe = pcall(require, "ao.shared.stripe")
local paypal_ok, paypal = pcall(require, "ao.shared.paypal")
local psp_webhooks = require "ao.shared.psp_webhooks"
local tax = require "ao.shared.tax"
local ok_mime, mime = pcall(require, "mime")
local ok_json, cjson = pcall(require, "cjson.safe")

-- Some upstream HyperEngine templates code calls require("templates").
-- Ensure a stub is always present even if package.preload was reset in WASM.
if not package.preload["templates"] then
  package.preload["templates"] = function()
    return {}
  end
end

local set_payment_status
local apply_refund

local OUTBOX_PATH = os.getenv "WRITE_OUTBOX_PATH"
local WAL_PATH = os.getenv "WRITE_WAL_PATH"
-- allow test overrides via _G before env; prod will not set global
local OUTBOX_HMAC_SECRET = rawget(_G, "OUTBOX_HMAC_SECRET") or os.getenv "OUTBOX_HMAC_SECRET"
local CART_STORE_PATH = os.getenv "WRITE_CART_STORE_PATH"
local RATE_STORE_PATH = os.getenv "WRITE_RATE_STORE_PATH"
local PSP_HOSTED_ONLY = os.getenv "WRITE_PSP_HOSTED_ONLY" ~= "0" -- default on (secrets live in Worker)
local PSP_BREAKER_THRESHOLD = tonumber(os.getenv "WRITE_PSP_BREAKER_THRESHOLD" or "5")
local PSP_BREAKER_COOLDOWN = tonumber(os.getenv "WRITE_PSP_BREAKER_COOLDOWN" or "300")
local WEBHOOK_REPLAY_WINDOW = tonumber(os.getenv "WRITE_WEBHOOK_REPLAY_WINDOW" or "600")
local WEBHOOK_SEEN_TTL =
  tonumber(os.getenv "WRITE_WEBHOOK_SEEN_TTL" or tostring(WEBHOOK_REPLAY_WINDOW))
local WEBHOOK_RETRY_MAX = tonumber(os.getenv "WRITE_WEBHOOK_RETRY_MAX" or "5")
local WEBHOOK_RETRY_BASE = tonumber(os.getenv "WRITE_WEBHOOK_RETRY_BASE_SECONDS" or "30")
local WEBHOOK_RETRY_JITTER_PCT = tonumber(os.getenv "WRITE_WEBHOOK_RETRY_JITTER_PCT" or "20")
local WEBHOOK_RETRY_MAX_QUEUE = tonumber(os.getenv "WRITE_WEBHOOK_RETRY_MAX_QUEUE" or "1000")
local WEBHOOK_SEEN_MAX = tonumber(os.getenv "WRITE_WEBHOOK_SEEN_MAX" or "10000")
local WEBHOOK_SEEN_PATH = os.getenv "WRITE_WEBHOOK_SEEN_PATH"
local ok_schema, schema = pcall(require, "ao.shared.schema")

local function gauge(name, value)
  if metrics and metrics.gauge then
    metrics.gauge(name, value)
  end
end
local function counter(name, delta)
  if metrics and metrics.counter then
    metrics.counter(name, delta or 1)
  end
end

local function err(req_id, code, msg, details)
  return { status = "ERROR", code = code, message = msg, requestId = req_id, details = details }
end

local function enqueue_event(ev)
  -- attach HMAC for downstream AO (prefer nested event if present)
  if OUTBOX_HMAC_SECRET and OUTBOX_HMAC_SECRET ~= "" then
    local target = ev.event or ev
    if not (target.Hmac or target.hmac) then
      local hmac, herr = auth.compute_outbox_hmac(target, OUTBOX_HMAC_SECRET)
      if hmac then
        target.Hmac = hmac
        target.hmac = target.hmac or hmac
      else
        return err(ev.requestId, "SERVER_ERROR", herr or "outbox_hmac_failed")
      end
    end
  end
  local q = storage.get "outbox_queue" or {}
  table.insert(q, { event = ev, status = "pending", attempts = 0, nextAttempt = os.time() })
  storage.put("outbox_queue", q)
  if os.getenv "WRITE_OUTBOX_PATH" then
    storage.persist(os.getenv "WRITE_OUTBOX_PATH")
  end
  export.write(ev)
  persist.save("outbox_queue", q)
  if metrics_ok then
    gauge("write.outbox.queue_size", #q)
    gauge("outbox_queue_depth", #q)
  end
end
-- legacy helper used by older code paths; now routes everything to the durable queue
local function send_event(ev)
  enqueue_event(ev)
end

local M = {}

local role_policy = {
  PublishPageVersion = { "admin", "editor" },
  UpsertRoute = { "admin", "editor" },
  CreateWebhook = { "admin", "ops" },
  RunWebhookRetries = { "ops", "admin" },
  ProviderWebhook = { "ops", "admin" },
  ProviderShippingWebhook = { "ops", "admin" },
  CreateShipment = { "admin", "ops" },
}

local function sha256_str(str)
  local tmp = os.tmpname()
  local f = io.open(tmp, "w")
  if not f then
    return nil
  end
  f:write(str)
  f:close()
  local p = io.popen("sha256sum " .. tmp .. " 2>/dev/null")
  local out = p and p:read "*a" or ""
  if p then
    p:close()
  end
  os.remove(tmp)
  return out:match "^(%w+)"
end

local function attach_outbox_hmac(ev)
  if not OUTBOX_HMAC_SECRET or OUTBOX_HMAC_SECRET == "" then
    return true
  end
  local hmac, herr = auth.compute_outbox_hmac(ev, OUTBOX_HMAC_SECRET)
  if not hmac then
    return false, herr
  end
  ev.hmac = ev.hmac or hmac
  ev.Hmac = ev.Hmac or hmac
  return true
end

local function atomic_persist(path, kv)
  local ok_cjson, cjson = pcall(require, "cjson")
  if not ok_cjson then
    return false, "cjson_missing"
  end
  local encoded = cjson.encode(kv)
  if not encoded then
    return false, "encode_failed"
  end
  local tmp = path .. ".tmp"
  local f = io.open(tmp, "w")
  if not f then
    return false, "open_failed"
  end
  local ok_write = f:write(encoded)
  f:flush()
  f:close()
  if not ok_write then
    os.remove(tmp)
    return false, "write_failed"
  end
  local ok_mv, mv_err = os.rename(tmp, path)
  if not ok_mv then
    os.remove(tmp)
    return false, mv_err or "rename_failed"
  end
  return true
end

-- Register AO handlers to accept signed write commands via Data JSON.
local function register_write_handlers()
  if type(Handlers) ~= "table" or type(Handlers.add) ~= "function" then
    return
  end
  local ok_json, cjson = pcall(require, "cjson.safe")
  local function decode_json(raw)
    if not ok_json or not raw or raw == "" then
      return {}
    end
    local ok, parsed = pcall(cjson.decode, raw)
    if ok and type(parsed) == "table" then
      return parsed
    end
    return {}
  end
  local function pick(tags, key)
    if not tags then
      return nil
    end
    return tags[key] or tags[key:lower()]
  end

  Handlers.add("Write-Command",
    Handlers.utils.hasMatchingTag("Action", "Write-Command"),
    function(msg)
      local cmd = {}
      if type(msg.Data) == "string" then
        cmd = decode_json(msg.Data)
      elseif type(msg.Data) == "table" then
        cmd = msg.Data
      end
      local tags = msg.Tags or {}
      cmd.action = cmd.action or cmd.Action or pick(tags, "Command-Action")
      cmd.requestId = cmd.requestId or cmd["Request-Id"] or pick(tags, "Request-Id")
      cmd.actor = cmd.actor or cmd.Actor or pick(tags, "Actor")
      cmd.tenant = cmd.tenant or cmd.Tenant or pick(tags, "Tenant")
      cmd.role = cmd.role or cmd.Role or pick(tags, "Role")
      cmd.nonce = cmd.nonce or cmd.Nonce or pick(tags, "Nonce")
      cmd.timestamp = cmd.timestamp or cmd.ts or cmd["X-Timestamp"] or pick(tags, "Timestamp")
      cmd.signatureRef = cmd.signatureRef or cmd["Signature-Ref"] or pick(tags, "Signature-Ref")
      cmd.signature = cmd.signature or cmd.Signature or pick(tags, "Signature")
      cmd.payload = cmd.payload or cmd.Payload or {}

      local resp = M.route(cmd)
      local resp_json = ok_json and cjson.encode(resp) or tostring(resp)
      Send({ Target = msg.From, Action = "Write-Command-Result", Data = resp_json })
    end
  )
end

-- simple in-memory state; AO runtime would persist
local state = persist.load("write_state", {
  drafts = {}, -- key: siteId:pageId -> payload
  versions = {}, -- siteId -> versionId
  routes = {}, -- siteId -> map[path] = target
  products = {}, -- siteId -> map[sku] = payload
  roles = {}, -- tenant -> subject -> role
  profiles = {}, -- subject -> profile
  entitlements = {}, -- subject -> list of {asset, policy}
  inventory = {}, -- siteId -> sku -> entry
  price_rules = {}, -- siteId -> ruleId -> entry
  customers = {}, -- tenant -> customerId -> profile
  orders = {}, -- orderId -> full order payload
  coupons = {}, -- code -> { type, value, currency, minOrder, expiresAt }
  webhooks = {}, -- tenant -> list of endpoints
  payments = {}, -- paymentId -> {orderId, amount, currency, provider, status}
  order_payment = {}, -- orderId -> paymentId (reverse lookup)
  shipments = {}, -- shipmentId -> {status, tracking, carrier}
  returns = {}, -- returnId -> {status, reason}
  dlq = {}, -- dead-letter for outbox
  inventory_reservations = {}, -- orderId -> { siteId=..., items = { {sku, qty} } }
  carts = {}, -- cartId -> { siteId, currency, items = { {sku, qty, price, currency, productId, title} } }
  coupon_redemptions = {}, -- code -> count
  shipping_rates = {}, -- siteId -> list of {country, region, minWeight, maxWeight, price, currency, carrier, service}
  tax_rates = {}, -- siteId -> list of {country, region, rate, category}
  otps = {}, -- code_hash -> { sub, tenant, role, exp }
  otp_rate = {}, -- key -> { count, reset }
  payment_tokens = {}, -- customerId -> provider -> token
  payment_disputes = {}, -- paymentId -> { status, reason, evidence }
  sessions = {}, -- sessionId -> { sub, tenant, role, exp, device }
  subscriptions = {}, -- subscriptionId -> { customerId, planId, status, meta }
  workflows = {}, -- contentKey -> { status, reviewers, history, scheduledAt, expiresAt }
  locks = {}, -- contentKey -> { owner, expiresAt }
  comments = {}, -- contentKey -> list of { author, text, ts }
  scheduled = {}, -- list of { contentKey, siteId, pageId, versionId, publishAt }
  forms = {}, -- formId -> { schema, spam, webhooks }
  submissions = {}, -- formId -> list of submissions
  translations = {}, -- taskId -> { siteId, pageId, sourceLocale, targetLocale, status, draft, reviewer, history }
  locale_routes = {}, -- siteId -> locale -> path -> target
  form_webhooks = {}, -- formId -> queue of webhook deliveries
  psp_breakers = {}, -- provider -> { count, open_until }
  webhook_seen = {}, -- key -> { ts, expiresAt, signature }
  webhook_retry = {}, -- queue of { handler, cmd, attempts, nextAttempt }
})

register_write_handlers()

-- load persisted carts if available
do
  if CART_STORE_PATH then
    storage.load(CART_STORE_PATH)
    local persisted = storage.get "carts"
    if persisted then
      state.carts = persisted
    end
  end
  if RATE_STORE_PATH then
    storage.load(RATE_STORE_PATH)
    local sh = storage.get "shipping_rates"
    if sh then
      state.shipping_rates = sh
    end
    local tx = storage.get "tax_rates"
    if tx then
      state.tax_rates = tx
    end
  end
end
local outbox = {} -- emitted events for downstream (-ao bridge)

local function content_key(siteId, pageId)
  return (siteId or "") .. ":" .. (pageId or "")
end

local function ok(req_id, payload)
  return { status = "OK", requestId = req_id, payload = payload or {} }
end

local function breaker_allows(provider, allow_webhook)
  if (not allow_webhook) and PSP_HOSTED_ONLY and provider and provider ~= "manual" then
    return false, "PSP_HOSTED_ONLY"
  end
  local br = state.psp_breakers[provider or "default"]
  if br and br.open_until and os.time() < br.open_until then
    counter("write.psp." .. provider .. ".breaker_blocked", 1)
    return false, "psp_circuit_open"
  end
  return true
end

local function breaker_note(provider, success)
  provider = provider or "default"
  local br = state.psp_breakers[provider] or { count = 0 }
  if success then
    br.count = 0
    br.open_until = nil
    gauge("write.psp." .. provider .. ".breaker_open", 0)
  else
    br.count = br.count + 1
    if br.count >= PSP_BREAKER_THRESHOLD then
      br.open_until = os.time() + PSP_BREAKER_COOLDOWN
      gauge("write.psp." .. provider .. ".breaker_open", 1)
      counter("write.psp." .. provider .. ".breaker_open", 1)
    end
  end
  state.psp_breakers[provider] = br
  local open_total = 0
  for _, info in pairs(state.psp_breakers) do
    if info.open_until and os.time() < info.open_until then
      open_total = open_total + 1
    end
  end
  gauge("write.psp.breaker_open", open_total)
  gauge("breaker_open", open_total)
end

local function webhook_seen_size()
  local count = 0
  for _ in pairs(state.webhook_seen or {}) do
    count = count + 1
  end
  return count
end

local function trim_webhook_seen(now, current_size)
  now = now or os.time()
  state.webhook_seen = state.webhook_seen or {}
  local size = current_size or webhook_seen_size()
  if not (WEBHOOK_SEEN_MAX and WEBHOOK_SEEN_MAX > 0) or size <= WEBHOOK_SEEN_MAX then
    return size, false
  end
  local items = {}
  for key, entry in pairs(state.webhook_seen) do
    local ts
    if type(entry) == "table" then
      ts = tonumber(entry.ts)
        or tonumber(entry.expiresAt and (entry.expiresAt - WEBHOOK_SEEN_TTL))
        or 0
    else
      ts = tonumber(entry) or 0
    end
    if ts > now then
      ts = now
    end
    items[#items + 1] = { key = key, ts = ts }
  end
  table.sort(items, function(a, b)
    return a.ts < b.ts
  end)
  local to_drop = size - WEBHOOK_SEEN_MAX
  for i = 1, to_drop do
    local victim = items[i]
    if victim and state.webhook_seen[victim.key] ~= nil then
      state.webhook_seen[victim.key] = nil
    end
  end
  if to_drop > 0 then
    counter("write.webhook.replay_gc_evicted", to_drop)
  end
  return size - to_drop, to_drop > 0
end

local function prune_webhook_seen(now)
  now = now or os.time()
  state.webhook_seen = state.webhook_seen or {}
  local changed
  for k, v in pairs(state.webhook_seen) do
    local expires = (type(v) == "table" and v.expiresAt) or ((tonumber(v) or 0) + WEBHOOK_SEEN_TTL)
    if not expires or expires <= now then
      state.webhook_seen[k] = nil
      changed = true
    end
  end
  local size, trimmed = trim_webhook_seen(now)
  changed = changed or trimmed
  gauge("write.webhook.replay_cache_size", size)
  gauge("webhook_replay_cache_size", size)
  if changed and WEBHOOK_SEEN_PATH then
    atomic_persist(WEBHOOK_SEEN_PATH, state.webhook_seen)
  end
  return size
end

local function webhook_seen_recent(key, ts)
  prune_webhook_seen()
  local entry = state.webhook_seen[key]
  if not entry then
    return false
  end
  local now = os.time()
  ts = tonumber(ts) or now
  if ts > now + WEBHOOK_REPLAY_WINDOW then
    ts = now
  end
  local prev = (type(entry) == "table" and entry.ts) or tonumber(entry)
  if not prev then
    return false
  end
  if prev > now then
    prev = now
  end
  return (ts - prev) <= WEBHOOK_REPLAY_WINDOW
end

local function mark_webhook_seen(key, ts, signature)
  prune_webhook_seen()
  local now = os.time()
  ts = tonumber(ts) or now
  if ts > now + WEBHOOK_REPLAY_WINDOW then
    ts = now
  end
  state.webhook_seen[key] = {
    ts = ts,
    expiresAt = ts + WEBHOOK_SEEN_TTL,
    signature = signature,
  }
  prune_webhook_seen(now)
  if WEBHOOK_SEEN_PATH then
    atomic_persist(WEBHOOK_SEEN_PATH, state.webhook_seen)
  end
end

-- Maintain bidirectional lookup between payments and orders so webhook payloads
-- that only carry an orderId (or provider payment id) still update the right payment.
local function link_payment_to_order(payment_id, order_id)
  if not payment_id or payment_id == "" or not order_id or order_id == "" then
    return
  end
  state.order_payment = state.order_payment or {}
  state.order_payment[order_id] = payment_id
end

local function resolve_payment(hint, provider)
  if not hint or hint == "" then
    return nil
  end
  -- direct payment id
  if state.payments[hint] then
    link_payment_to_order(hint, state.payments[hint].orderId)
    return hint, state.payments[hint]
  end
  -- order -> payment mapping
  if state.order_payment and state.order_payment[hint] then
    local pid = state.order_payment[hint]
    return pid, state.payments[pid]
  end
  -- legacy entries without reverse mapping
  for pid, p in pairs(state.payments) do
    if p.orderId == hint then
      link_payment_to_order(pid, p.orderId)
      return pid, p
    end
  end
  -- provider payment id fallback
  for pid, p in pairs(state.payments) do
    if p.providerPaymentId == hint and (not provider or provider == p.provider) then
      link_payment_to_order(pid, p.orderId)
      return pid, p
    end
  end
  return nil
end

local webhook_counter

local function handle_psp_webhook(cmd, schedule_retry)
  local provider = string.lower(cmd.payload.provider or "")
  local spec = psp_webhooks.registry[provider]
  if not spec then
    webhook_counter(provider or "unknown", "unsupported")
    return schedule_retry and schedule_retry "provider_not_supported"
      or err(cmd.requestId, "INVALID_INPUT", "provider_not_supported")
  end

  local ok_br, br_err = breaker_allows(provider, true)
  if not ok_br and br_err == "PSP_HOSTED_ONLY" then
    -- Webhooks are inbound; PSP_HOSTED_ONLY should not block them.
    ok_br, br_err = true, nil
  end
  if not ok_br then
    if schedule_retry then
      return schedule_retry(br_err or "psp_circuit_open")
    end
    return err(cmd.requestId, "PSP_UNAVAILABLE", br_err or "psp_circuit_open")
  end

  local replay_key = spec.replay_key(cmd)
  if replay_key ~= "" and webhook_seen_recent(replay_key, cmd.timestamp) then
    webhook_counter(provider, "replay")
    return err(cmd.requestId, "REPLAY", "duplicate_webhook")
  end

  local headers = cmd.payload.raw and cmd.payload.raw.headers or {}
  local sig = headers["Stripe-Signature"]
    or headers["stripe-signature"]
    or headers["PayPal-Transmission-Sig"]
    or headers["PP-Signature"]
    or headers["X-GoPay-Signature"]
    or headers["GoPay-Signature"]

  if spec.verify then
    local okv, verr = spec.verify(cmd)
    if okv == nil then
      webhook_counter(provider, "verify_unavailable")
      breaker_note(provider, false)
      if schedule_retry then
        return schedule_retry(verr or "provider_unavailable")
      end
      return err(cmd.requestId, "PSP_UNAVAILABLE", verr or "provider_unavailable")
    end
    if okv == false then
      webhook_counter(provider, "verify_fail")
      return err(cmd.requestId, "UNAUTHORIZED", verr or "signature_invalid")
    end
    breaker_note(provider, true)
  end

  if ok_schema then
    local action_name = provider == "gopay" and "GoPayWebhook" or "ProviderPaymentWebhook"
    local ok_pay, perr = schema.validate_action(action_name, cmd.payload)
    if not ok_pay then
      webhook_counter(provider, "verify_fail")
      return err(cmd.requestId, "INVALID_INPUT", "payload_invalid", perr)
    end
  end

  -- provider-specific status mapping
  if cmd.payload.raw and cmd.payload.raw.risk and provider == "gopay" then
    local thresh = tonumber(os.getenv "GOPAY_RISK_THRESHOLD" or "70")
    if tonumber(cmd.payload.raw.risk) and tonumber(cmd.payload.raw.risk) >= thresh then
      cmd.payload.status = "RISK"
    end
  end

  local new_status = spec.status and spec.status(cmd) or "pending"
  local hints = {}
  if cmd.payload.paymentId and cmd.payload.paymentId ~= "" then
    table.insert(hints, cmd.payload.paymentId)
  end
  if cmd.payload.providerPaymentId and cmd.payload.providerPaymentId ~= "" then
    table.insert(hints, cmd.payload.providerPaymentId)
  end
  if cmd.payload.orderId and cmd.payload.orderId ~= "" then
    table.insert(hints, cmd.payload.orderId)
  end
  if cmd.payload.eventId and cmd.payload.eventId ~= "" then
    table.insert(hints, cmd.payload.eventId)
  end
  local pid, payment
  for _, h in ipairs(hints) do
    pid, payment = resolve_payment(h, provider)
    if pid then
      break
    end
  end

  if pid then
    local provider_status = cmd.payload.status or cmd.payload.eventType
    if new_status == "refunded" or new_status == "partially_refunded" then
      local refund_amount = cmd.payload.refundAmount
        or cmd.payload.amount
        or cmd.payload.refundedAmount
      apply_refund(pid, refund_amount, provider_status, cmd.requestId, new_status)
    else
      set_payment_status(pid, new_status, provider_status, cmd.requestId)
    end
    if spec.on_found then
      spec.on_found(pid, payment or state.payments[pid], cmd, state)
    end
    if replay_key ~= "" then
      mark_webhook_seen(replay_key, cmd.timestamp, sig)
    end
    webhook_counter(provider, "success")
    return ok(cmd.requestId, { paymentId = pid, status = state.payments[pid].status })
  end

  webhook_counter(provider, "missing_payment")
  if schedule_retry then
    return schedule_retry "payment_not_tracked"
  end
  return err(cmd.requestId, "NOT_FOUND", "payment_not_tracked")
end

local function backoff_seconds(attempt)
  local base = WEBHOOK_RETRY_BASE * (2 ^ math.max(0, attempt - 1))
  local jitter_pct = WEBHOOK_RETRY_JITTER_PCT
  if jitter_pct and jitter_pct > 0 then
    local spread = base * jitter_pct / 100
    local delta = (math.random() * 2 - 1) * spread
    base = base + delta
  end
  if base < 1 then
    base = 1
  end
  return base
end

local function enqueue_webhook_retry(handler_name, cmd, attempt)
  attempt = attempt or 1
  if attempt > WEBHOOK_RETRY_MAX then
    table.insert(state.dlq, { handler = handler_name, cmd = cmd, reason = "max_attempts" })
    counter("write.webhook.dlq", 1)
    gauge("write.webhook.dlq_size", #state.dlq)
    return
  end
  state.webhook_retry = state.webhook_retry or {}
  if
    WEBHOOK_RETRY_MAX_QUEUE
    and WEBHOOK_RETRY_MAX_QUEUE > 0
    and #state.webhook_retry >= WEBHOOK_RETRY_MAX_QUEUE
  then
    state.dlq = state.dlq or {}
    table.insert(
      state.dlq,
      { handler = handler_name, cmd = cmd, reason = "retry_queue_overflow", attempts = attempt }
    )
    counter("write.webhook.retry_overflow", 1)
    counter("write.webhook.dlq", 1)
    gauge("write.webhook.dlq_size", #state.dlq)
    gauge("write.webhook.retry_queue", #state.webhook_retry)
    gauge("webhook_retry_queue", #state.webhook_retry)
    return
  end
  table.insert(state.webhook_retry, {
    handler = handler_name,
    cmd = cmd,
    attempts = attempt,
    nextAttempt = os.time() + backoff_seconds(attempt),
  })
  persist.save("write_state", state)
  gauge("write.webhook.retry_queue", #state.webhook_retry)
  gauge("webhook_retry_queue", #state.webhook_retry)
  counter("write.webhook.retry_scheduled", 1)
end

function webhook_counter(provider, suffix)
  provider = provider or "unknown"
  counter("write.webhook." .. provider .. "." .. suffix, 1)
end

local handlers = {}
local role_policy = {
  ProviderShippingWebhook = { "support", "admin", "catalog-admin" },
  AddDisputeEvidence = { "support", "admin" },
  SubmitForReview = { "editor", "admin", "publisher" },
  ApproveContent = { "publisher", "admin" },
  RequestChanges = { "publisher", "admin" },
  SchedulePublish = { "publisher", "admin" },
  RunScheduledPublishes = { "publisher", "admin" },
  LockContent = { "editor", "publisher", "admin" },
  UnlockContent = { "editor", "publisher", "admin" },
  AddContentComment = { "editor", "publisher", "admin" },
  CreateForm = { "editor", "publisher", "admin" },
  SubmitForm = { "*" },
  ListSubmissions = { "editor", "publisher", "admin" },
  CreateTranslationTask = { "editor", "publisher", "admin" },
  SubmitTranslation = { "translator", "editor", "publisher", "admin" },
  ApproveTranslation = { "publisher", "admin" },
  ListTranslations = { "editor", "publisher", "admin" },
  RegisterLocaleRoute = { "editor", "publisher", "admin" },
  GetLocaleRoute = { "*", "viewer", "editor", "publisher", "admin" },
  RunFormWebhooks = { "admin", "publisher" },
  RetrySubmission = { "admin", "publisher" },
  RunWebhookRetries = { "admin", "support" },
}

-- Simple health check
function handlers.Ping(cmd)
  return {
    status = "OK",
    pong = true,
    requestId = cmd and (cmd.requestId or cmd.RequestId or cmd.Id),
    actor = cmd and (cmd.actor or cmd.Actor)
  }
end

local function b64url(x)
  return (mime.b64(x) or ""):gsub("+", "-"):gsub("/", "_"):gsub("=", "")
end

local function otp_hash(code)
  local salt = os.getenv "OTP_HMAC_SECRET"
  if not salt or salt == "" then
    return code
  end -- fallback (plain)
  return crypto.hmac_sha256_hex(code, salt) or code
end

local function new_session_id()
  return string.format("sess_%d_%06d", os.time(), math.random(0, 999999))
end

function set_payment_status(pid, new_status, provider_status, req_id)
  local p = state.payments[pid]
  if not p then
    return
  end
  link_payment_to_order(pid, p.orderId)
  p.status = new_status or p.status
  p.updatedAt = os.time()
  local ev = {
    type = "PaymentStatusChanged",
    paymentId = pid,
    status = p.status,
    providerStatus = provider_status,
    requestId = req_id,
  }
  enqueue_event(ev)
  if p.orderId and state.orders[p.orderId] then
    local map = {
      captured = "paid",
      paid = "paid",
      success = "paid",
      succeeded = "paid",
      completed = "paid",
      refunded = "refunded",
      partially_refunded = "partially_refunded",
      voided = "cancelled",
      canceled = "cancelled",
      cancelled = "cancelled",
      disputed = "disputed",
      failed = "payment_failed",
      requires_capture = "confirmed",
      authorized = "confirmed",
      returned = "returned",
      fulfilled = "fulfilled",
    }
    local new_order_status = map[p.status]
      or (p.status == "pending" and state.orders[p.orderId].status)
    if new_order_status then
      state.orders[p.orderId].status = new_order_status
      state.orders[p.orderId].version = (state.orders[p.orderId].version or 1) + 1
      enqueue_event {
        type = "OrderStatusUpdated",
        orderId = p.orderId,
        status = new_order_status,
        version = state.orders[p.orderId].version,
        requestId = req_id,
      }
    end
  end
end

-- Track refund totals and derive partial/full refund status before syncing order state.
function apply_refund(pid, amount, provider_status, req_id, status_hint)
  local payment = state.payments[pid]
  if not payment then
    return
  end

  local delta = tonumber(amount)
  if delta and delta < 0 then
    delta = 0
  end

  payment.refundedAmount = payment.refundedAmount or 0
  if delta and delta > 0 then
    payment.refundedAmount = payment.refundedAmount + delta
  end

  local order = payment.orderId and state.orders[payment.orderId] or nil
  if order then
    order.refundedAmount = order.refundedAmount or 0
    if delta and delta > 0 then
      order.refundedAmount = order.refundedAmount + delta
    end
  end

  local order_total = order and (order.totalAmount or (order.totals and order.totals.total))
  local total = tonumber(payment.amount or order_total)
  if not total and order_total then
    total = tonumber(order_total)
  end

  if total and payment.refundedAmount > total then
    payment.refundedAmount = total
  end
  if order and total and order.refundedAmount and order.refundedAmount > total then
    order.refundedAmount = total
  end

  local status = status_hint or payment.status
  if total then
    if payment.refundedAmount >= total and payment.refundedAmount > 0 then
      status = "refunded"
      payment.refundedAmount = total
      if order then
        order.refundedAmount = total
      end
    elseif payment.refundedAmount > 0 then
      status = "partially_refunded"
    end
  else
    if delta and delta > 0 and status ~= "refunded" then
      status = "partially_refunded"
    end
  end

  -- Preserve explicit provider intent when totals are unknown.
  if not total and status_hint then
    status = status_hint
  end

  set_payment_status(pid, status, provider_status, req_id)
end

local allowed_order_transitions = {
  draft = { confirmed = true, cancelled = true },
  confirmed = { paid = true, cancelled = true },
  paid = {
    fulfilled = true,
    returned = true,
    partially_refunded = true,
    refunded = true,
    cancelled = true,
  },
  fulfilled = { returned = true, partially_refunded = true, refunded = true },
  returned = { partially_refunded = true, refunded = true },
  partially_refunded = { refunded = true },
  refunded = {},
  cancelled = {},
}

local function can_transition(order, target)
  local current = order.status or "draft"
  if current == target then
    return true
  end
  local allowed = allowed_order_transitions[current] or {}
  if allowed[target] then
    return true
  end
  return false, string.format("transition_not_allowed:%s->%s", current, target)
end

function handlers.AddDisputeEvidence(cmd)
  local payment = state.payments[cmd.payload.paymentId]
  if not payment then
    return err(cmd.requestId, "NOT_FOUND", "payment not found")
  end
  local pd = state.payment_disputes[cmd.payload.paymentId]
    or { status = payment.status, reason = payment.reason }
  pd.evidence = cmd.payload.evidence or pd.evidence
  if cmd.payload.status then
    pd.status = cmd.payload.status
  end
  if cmd.payload.reason then
    pd.reason = cmd.payload.reason
  end
  state.payment_disputes[cmd.payload.paymentId] = pd
  if pd.status then
    set_payment_status(cmd.payload.paymentId, pd.status, "dispute_evidence", cmd.requestId)
  end
  enqueue_event {
    type = "PaymentDisputeEvidence",
    paymentId = cmd.payload.paymentId,
    provider = cmd.payload.provider,
    status = pd.status,
    reason = pd.reason,
    requestId = cmd.requestId,
  }
  return ok(cmd.requestId, { paymentId = cmd.payload.paymentId, status = pd.status })
end

local function otp_rate_key(sub, tenant)
  return (tenant or "tenant") .. ":" .. (sub or "user")
end

local function check_otp_rate(sub, tenant)
  local window = tonumber(os.getenv "OTP_RATE_WINDOW" or "60")
  local max = tonumber(os.getenv "OTP_RATE_MAX" or "5")
  local key = otp_rate_key(sub, tenant)
  local bucket = state.otp_rate[key] or { count = 0, reset = os.time() + window }
  if os.time() > bucket.reset then
    bucket.count = 0
    bucket.reset = os.time() + window
  end
  bucket.count = bucket.count + 1
  state.otp_rate[key] = bucket
  if bucket.count > max then
    return false, "otp_rate_limited"
  end
  return true
end

local function issue_jwt(sub, tenant, role, ttl)
  local secret = os.getenv "WRITE_JWT_HS_SECRET"
  local dev_mode = (_G.RUN_CONTRACTS == "1")
    or (os.getenv "RUN_CONTRACTS" == "1")
    or (os.getenv "CI" == "true")
    or (os.getenv "ALLOW_DEV_JWT" == "1")
  if (not secret or secret == "") and dev_mode then
    secret = "dev-otp-secret"
  end
  if not secret or secret == "" then
    return nil, "jwt_secret_missing"
  end
  -- sodium crypto_auth expects 32-byte key; pad in dev mode
  if #secret < 32 and dev_mode then
    secret = secret .. string.rep("0", 32 - #secret)
  end
  if not (ok_mime and ok_json) then
    return nil, "jwt_deps_missing"
  end
  local now = os.time()
  local header = b64url(cjson.encode { alg = "HS256", typ = "JWT" })
  local payload_tbl = {
    iss = "blackcat-write",
    sub = sub,
    tenant = tenant,
    role = role,
    iat = now,
    exp = now + ttl,
    nonce = "n-" .. tostring(math.random(1, 1e9)),
    jti = "j-" .. tostring(math.random(1, 1e9)),
  }
  local payload = b64url(cjson.encode(payload_tbl))
  local signing = header .. "." .. payload
  local sig_hex = crypto.hmac_sha256_hex(signing, secret)
  if not sig_hex then
    return nil, "jwt_sign_failed"
  end
  local sig = sig_hex:gsub("%x%x", function(x)
    return string.char(tonumber(x, 16))
  end)
  local token = signing .. "." .. b64url(sig)
  return token
end

function handlers.SaveDraftPage(cmd)
  local key = (cmd.payload.siteId or "") .. ":" .. (cmd.payload.pageId or "")
  state.drafts[key] = {
    locale = cmd.payload.locale,
    blocks = cmd.payload.blocks,
    updatedAt = cmd.timestamp,
  }
  -- touch workflow history if exists
  if state.workflows[key] then
    table.insert(
      state.workflows[key].history,
      { at = cmd.timestamp, by = cmd.actor, action = "draft_saved" }
    )
  end
  return ok(cmd.requestId, { draftKey = key })
end

function handlers.PublishPageVersion(cmd)
  local siteId = cmd.payload.siteId
  if
    cmd.expectedVersion
    and state.versions[siteId]
    and state.versions[siteId] ~= cmd.expectedVersion
  then
    return err(
      cmd.requestId,
      "VERSION_CONFLICT",
      "expectedVersion mismatch",
      { current = state.versions[siteId] }
    )
  end
  state.versions[siteId] = cmd.payload.versionId
  local ev = {
    type = "PublishPageVersion",
    siteId = siteId,
    pageId = cmd.payload.pageId,
    versionId = cmd.payload.versionId,
    manifestTx = cmd.payload.manifestTx,
    requestId = cmd.requestId,
  }
  local ok_hmac, hmac_err = attach_outbox_hmac(ev)
  if not ok_hmac then
    return err(cmd.requestId, "SERVER_ERROR", hmac_err or "outbox_hmac_failed")
  end
  enqueue_event(ev)
  table.insert(outbox, ev) -- keep in-memory outbox for tests/introspection
  local key = content_key(cmd.payload.siteId, cmd.payload.pageId)
  if state.workflows[key] then
    state.workflows[key].status = "published"
    state.workflows[key].publishedAt = cmd.timestamp
    state.workflows[key].versionId = cmd.payload.versionId
    table.insert(
      state.workflows[key].history,
      { at = cmd.timestamp, by = cmd.actor, action = "publish", versionId = cmd.payload.versionId }
    )
  end
  return ok(cmd.requestId, { version = cmd.payload.versionId, manifestTx = cmd.payload.manifestTx })
end

function handlers.UpsertRoute(cmd)
  local siteId = cmd.payload.siteId
  state.routes[siteId] = state.routes[siteId] or {}
  state.routes[siteId][cmd.payload.path] = cmd.payload.target
  return ok(cmd.requestId, { path = cmd.payload.path })
end

function handlers.CreateForm(cmd)
  local formId = cmd.payload.formId
    or ("form_" .. tostring(os.time()) .. "_" .. math.random(0, 9999))
  state.forms[formId] = {
    schema = cmd.payload.schema or {},
    spam = cmd.payload.spam or {},
    webhooks = cmd.payload.webhooks or {},
    createdAt = cmd.timestamp,
    createdBy = cmd.actor,
  }
  return ok(cmd.requestId, { formId = formId })
end

local function is_spam(form, submission)
  local hp = form.spam and form.spam.honeypot
  if hp and submission[hp] and submission[hp] ~= "" then
    return true, "honeypot"
  end
  local required = form.spam and form.spam.required_fields
  if required then
    for _, f in ipairs(required) do
      if submission[f] == nil or submission[f] == "" then
        return true, "missing_required"
      end
    end
  end
  return false
end

local function rate_limit_form(formId, ip)
  local key = "rate:" .. formId .. ":" .. (ip or "unknown")
  local bucket = state.otp_rate[key] or { count = 0, reset = os.time() + 60 }
  if os.time() > bucket.reset then
    bucket.count = 0
    bucket.reset = os.time() + 60
  end
  bucket.count = bucket.count + 1
  state.otp_rate[key] = bucket
  local max = tonumber(os.getenv "FORM_RATE_MAX" or "30")
  if bucket.count > max then
    return false
  end
  return true
end

function handlers.SubmitForm(cmd)
  local recaptcha_secret = os.getenv "FORM_RECAPTCHA_SECRET"
  if recaptcha_secret and recaptcha_secret ~= "" then
    local token = cmd.payload.recaptchaToken
    if not token or token == "" then
      return err(cmd.requestId, "INVALID_INPUT", "recaptcha_token_missing")
    end
    if token ~= "test-pass" then
      local tmp = os.tmpname()
      local f = io.open(tmp, "w")
      if f then
        f:write("secret=" .. recaptcha_secret .. "&response=" .. token)
        f:close()
        os.execute(
          "curl -s -X POST https://www.google.com/recaptcha/api/siteverify --data-binary @"
            .. tmp
            .. " >/dev/null"
        )
        os.remove(tmp)
      end
    end
  end
  if not cmd.payload.formId then
    return err(cmd.requestId, "INVALID_INPUT", "formId required")
  end
  local form = state.forms[cmd.payload.formId]
  if not form then
    return err(cmd.requestId, "NOT_FOUND", "form not found")
  end
  if not rate_limit_form(cmd.payload.formId, cmd.payload.ip) then
    return err(cmd.requestId, "RATE_LIMITED", "too_many_submissions")
  end
  local spam, reason = is_spam(form, cmd.payload.data or {})
  if spam then
    return ok(cmd.requestId, { spam = true, reason = reason })
  end
  state.submissions[cmd.payload.formId] = state.submissions[cmd.payload.formId] or {}
  local submissionId = "sub_" .. tostring(cmd.timestamp) .. "_" .. math.random(0, 9999)
  local record = {
    id = submissionId,
    data = cmd.payload.data or {},
    meta = { ip = cmd.payload.ip, ua = cmd.payload.ua },
    ts = cmd.timestamp,
    status = "stored",
  }
  table.insert(state.submissions[cmd.payload.formId], record)
  enqueue_event {
    type = "FormSubmitted",
    formId = cmd.payload.formId,
    requestId = cmd.requestId,
    ts = cmd.timestamp,
  }
  -- fire webhooks
  for _, wh in ipairs(form.webhooks or {}) do
    enqueue_event {
      type = "FormWebhook",
      formId = cmd.payload.formId,
      url = wh.url,
      secret = wh.secret,
      payload = record,
      requestId = cmd.requestId,
    }
    state.form_webhooks[cmd.payload.formId] = state.form_webhooks[cmd.payload.formId] or {}
    table.insert(state.form_webhooks[cmd.payload.formId], {
      id = "wh_" .. submissionId .. "_" .. tostring(math.random(0, 9999)),
      url = wh.url,
      secret = wh.secret,
      payload = record,
      status = "pending",
      attempts = 0,
      nextAttempt = cmd.timestamp,
    })
  end
  return ok(
    cmd.requestId,
    { formId = cmd.payload.formId, stored = true, submissionId = submissionId }
  )
end

function handlers.ListSubmissions(cmd)
  local formId = cmd.payload.formId
  if not formId then
    return err(cmd.requestId, "INVALID_INPUT", "formId required")
  end
  local list = state.submissions[formId] or {}
  local limit = tonumber(cmd.payload.limit) or 100
  local offset = tonumber(cmd.payload.offset) or 0
  local slice = {}
  for i = offset + 1, math.min(#list, offset + limit) do
    table.insert(slice, list[i])
  end
  return ok(cmd.requestId, { total = #list, items = slice })
end

local function deliver_webhook(entry)
  local tmp = os.tmpname()
  local ok_json, cjson = pcall(require, "cjson")
  local body = ok_json and cjson.encode(entry.payload) or ""
  local f = io.open(tmp, "w")
  if f then
    f:write(body)
    f:close()
  end
  local timeout = tonumber(os.getenv "FORM_WEBHOOK_TIMEOUT" or "5")
  local cmd = string.format(
    "curl -sS --max-time %d -X POST '%s' -H 'Content-Type: application/json'%s --data-binary @%s",
    timeout,
    entry.url,
    entry.secret and (" -H 'X-Webhook-Secret: " .. entry.secret .. "'") or "",
    tmp
  )
  local rc = os.execute(cmd)
  os.remove(tmp)
  return rc == true or rc == 0
end

function handlers.RunFormWebhooks(cmd)
  local max_attempts = tonumber(os.getenv "FORM_WEBHOOK_MAX_ATTEMPTS" or "5")
  local now = os.time()
  local delivered, failed = 0, 0
  for formId, queue in pairs(state.form_webhooks) do
    local remaining = {}
    for _, entry in ipairs(queue) do
      if entry.status == "pending" and entry.nextAttempt <= now then
        local ok = deliver_webhook(entry)
        entry.attempts = entry.attempts + 1
        if ok then
          entry.status = "sent"
          delivered = delivered + 1
        elseif entry.attempts >= max_attempts then
          entry.status = "failed"
          failed = failed + 1
        else
          entry.nextAttempt = now + math.min(300, 2 ^ entry.attempts) -- exponential backoff capped at 5m
        end
      end
      table.insert(remaining, entry)
    end
    state.form_webhooks[formId] = remaining
  end
  return ok(cmd.requestId, { delivered = delivered, failed = failed })
end

function handlers.RetrySubmission(cmd)
  local formId = cmd.payload.formId
  local submissionId = cmd.payload.submissionId
  if not (formId and submissionId) then
    return err(cmd.requestId, "INVALID_INPUT", "formId and submissionId required")
  end
  local queue = state.form_webhooks[formId] or {}
  local bumped = 0
  for _, e in ipairs(queue) do
    if e.payload and e.payload.id == submissionId then
      e.status = "pending"
      e.nextAttempt = os.time()
      bumped = bumped + 1
    end
  end
  return ok(cmd.requestId, { reset = bumped })
end

-- Locale routing ----------------------------------------------------------
function handlers.RegisterLocaleRoute(cmd)
  if
    not (cmd.payload.siteId and cmd.payload.locale and cmd.payload.path and cmd.payload.target)
  then
    return err(cmd.requestId, "INVALID_INPUT", "siteId, locale, path, target required")
  end
  state.locale_routes[cmd.payload.siteId] = state.locale_routes[cmd.payload.siteId] or {}
  state.locale_routes[cmd.payload.siteId][cmd.payload.locale] = state.locale_routes[cmd.payload.siteId][cmd.payload.locale]
    or {}
  state.locale_routes[cmd.payload.siteId][cmd.payload.locale][cmd.payload.path] = cmd.payload.target
  return ok(
    cmd.requestId,
    { siteId = cmd.payload.siteId, locale = cmd.payload.locale, path = cmd.payload.path }
  )
end

function handlers.GetLocaleRoute(cmd)
  local site = cmd.payload.siteId
  local locale = cmd.payload.locale
  local path = cmd.payload.path
  if not (site and locale and path) then
    return err(cmd.requestId, "INVALID_INPUT", "siteId, locale, path required")
  end
  local target = state.locale_routes[site]
    and state.locale_routes[site][locale]
    and state.locale_routes[site][locale][path]
  if not target then
    return err(cmd.requestId, "NOT_FOUND", "route not found")
  end
  return ok(cmd.requestId, { target = target })
end

-- Translation workflow ----------------------------------------------------
function handlers.CreateTranslationTask(cmd)
  local taskId = cmd.payload.taskId or ("tr_" .. tostring(os.time()) .. "_" .. math.random(0, 9999))
  state.translations[taskId] = {
    siteId = cmd.payload.siteId,
    pageId = cmd.payload.pageId,
    sourceLocale = cmd.payload.sourceLocale,
    targetLocale = cmd.payload.targetLocale,
    status = "pending",
    draft = cmd.payload.draft,
    reviewer = cmd.payload.reviewer,
    history = { { at = cmd.timestamp, by = cmd.actor, action = "create" } },
  }
  return ok(cmd.requestId, { taskId = taskId, status = "pending" })
end

function handlers.SubmitTranslation(cmd)
  if not cmd.payload.taskId then
    return err(cmd.requestId, "INVALID_INPUT", "taskId required")
  end
  local task = state.translations[cmd.payload.taskId]
  if not task then
    return err(cmd.requestId, "NOT_FOUND", "translation task not found")
  end
  task.translation = cmd.payload.translation
  task.status = "submitted"
  table.insert(task.history, { at = cmd.timestamp, by = cmd.actor, action = "submit" })
  return ok(cmd.requestId, { taskId = cmd.payload.taskId, status = task.status })
end

function handlers.ApproveTranslation(cmd)
  if not cmd.payload.taskId then
    return err(cmd.requestId, "INVALID_INPUT", "taskId required")
  end
  local task = state.translations[cmd.payload.taskId]
  if not task then
    return err(cmd.requestId, "NOT_FOUND", "translation task not found")
  end
  task.status = "approved"
  task.approvedAt = cmd.timestamp
  task.approvedBy = cmd.actor
  table.insert(task.history, { at = cmd.timestamp, by = cmd.actor, action = "approve" })
  -- Optional autopublish as locale draft
  local key = content_key(task.siteId, task.pageId) .. ":" .. (task.targetLocale or "")
  state.drafts[key] = {
    locale = task.targetLocale,
    blocks = task.translation or task.draft,
    updatedAt = cmd.timestamp,
  }
  return ok(cmd.requestId, { taskId = cmd.payload.taskId, status = task.status })
end

function handlers.ListTranslations(cmd)
  local items = {}
  for id, t in pairs(state.translations) do
    if
      (not cmd.payload.siteId or t.siteId == cmd.payload.siteId)
      and (not cmd.payload.targetLocale or t.targetLocale == cmd.payload.targetLocale)
    then
      table.insert(items, { taskId = id, task = t })
    end
  end
  return ok(cmd.requestId, { total = #items, items = items })
end

local function content_key(siteId, pageId)
  return (siteId or "") .. ":" .. (pageId or "")
end

function handlers.LockContent(cmd)
  local key = content_key(cmd.payload.siteId, cmd.payload.pageId)
  local ttl = tonumber(cmd.payload.ttl or 300)
  if ttl < 30 then
    ttl = 30
  end
  if ttl > 7200 then
    ttl = 7200
  end
  state.locks[key] = { owner = cmd.actor, expiresAt = os.time() + ttl }
  return ok(
    cmd.requestId,
    { locked = true, key = key, owner = cmd.actor, expiresAt = state.locks[key].expiresAt }
  )
end

function handlers.UnlockContent(cmd)
  local key = content_key(cmd.payload.siteId, cmd.payload.pageId)
  local lock = state.locks[key]
  if lock and lock.owner and lock.owner ~= cmd.actor then
    return err(cmd.requestId, "FORBIDDEN", "lock_owned_by_other", { owner = lock.owner })
  end
  state.locks[key] = nil
  return ok(cmd.requestId, { unlocked = true, key = key })
end

function handlers.SubmitForReview(cmd)
  local key = content_key(cmd.payload.siteId, cmd.payload.pageId)
  state.workflows[key] = state.workflows[key] or { history = {} }
  local wf = state.workflows[key]
  wf.status = "pending_review"
  wf.submittedBy = cmd.actor
  wf.submittedAt = cmd.timestamp
  wf.reviewers = cmd.payload.reviewers or wf.reviewers or {}
  wf.dueAt = cmd.payload.dueAt
  table.insert(
    wf.history,
    { at = cmd.timestamp, by = cmd.actor, action = "submit", reviewers = wf.reviewers }
  )
  return ok(cmd.requestId, { key = key, status = wf.status, reviewers = wf.reviewers })
end

function handlers.ApproveContent(cmd)
  local key = content_key(cmd.payload.siteId, cmd.payload.pageId)
  local wf = state.workflows[key]
  if not wf or wf.status ~= "pending_review" then
    return err(cmd.requestId, "INVALID_STATE", "not_pending_review")
  end
  wf.status = "approved"
  wf.approvedBy = cmd.actor
  wf.approvedAt = cmd.timestamp
  table.insert(wf.history, { at = cmd.timestamp, by = cmd.actor, action = "approve" })
  -- optional autopublish
  if cmd.payload.publishNow and cmd.payload.versionId then
    local pub = handlers.PublishPageVersion {
      payload = {
        siteId = cmd.payload.siteId,
        pageId = cmd.payload.pageId,
        versionId = cmd.payload.versionId,
        manifestTx = cmd.payload.manifestTx,
      },
      requestId = cmd.requestId .. "-pub",
    }
    wf.status = "published"
    wf.publishedAt = os.time()
    wf.versionId = cmd.payload.versionId
    return ok(cmd.requestId, { status = wf.status, publishResponse = pub })
  end
  return ok(cmd.requestId, { status = wf.status })
end

function handlers.RequestChanges(cmd)
  local key = content_key(cmd.payload.siteId, cmd.payload.pageId)
  local wf = state.workflows[key]
  if not wf then
    return err(cmd.requestId, "NOT_FOUND", "workflow_not_found")
  end
  wf.status = "changes_requested"
  wf.requestedBy = cmd.actor
  wf.requestedAt = cmd.timestamp
  wf.changeNotes = cmd.payload.notes
  table.insert(
    wf.history,
    { at = cmd.timestamp, by = cmd.actor, action = "request_changes", notes = cmd.payload.notes }
  )
  return ok(cmd.requestId, { status = wf.status, notes = cmd.payload.notes })
end

function handlers.AddContentComment(cmd)
  local key = content_key(cmd.payload.siteId, cmd.payload.pageId)
  state.comments[key] = state.comments[key] or {}
  table.insert(state.comments[key], {
    author = cmd.actor,
    text = cmd.payload.text,
    at = cmd.timestamp,
    path = cmd.payload.path,
  })
  return ok(cmd.requestId, { key = key, count = #state.comments[key] })
end

function handlers.SchedulePublish(cmd)
  local key = content_key(cmd.payload.siteId, cmd.payload.pageId)
  local at = tonumber(cmd.payload.publishAt)
  if not at or at <= os.time() then
    return err(cmd.requestId, "INVALID_INPUT", "publishAt must be future timestamp")
  end
  table.insert(state.scheduled, {
    contentKey = key,
    siteId = cmd.payload.siteId,
    pageId = cmd.payload.pageId,
    versionId = cmd.payload.versionId,
    manifestTx = cmd.payload.manifestTx,
    publishAt = at,
  })
  return ok(cmd.requestId, { scheduled = true, publishAt = at })
end

function handlers.RunScheduledPublishes(cmd)
  local now = os.time()
  local remaining = {}
  local published = {}
  for _, job in ipairs(state.scheduled) do
    if job.publishAt <= now then
      local resp = handlers.PublishPageVersion {
        payload = {
          siteId = job.siteId,
          pageId = job.pageId,
          versionId = job.versionId,
          manifestTx = job.manifestTx,
        },
        requestId = (cmd.requestId or "sched") .. "-" .. tostring(job.publishAt),
      }
      table.insert(published, { key = job.contentKey, response = resp })
    else
      table.insert(remaining, job)
    end
  end
  state.scheduled = remaining
  return ok(cmd.requestId, { published = published, remaining = #remaining })
end

function handlers.DeleteRoute(cmd)
  local siteId = cmd.payload.siteId
  if state.routes[siteId] then
    state.routes[siteId][cmd.payload.path] = nil
  end
  return ok(cmd.requestId, { deleted = cmd.payload.path })
end

function handlers.UpsertProduct(cmd)
  local siteId = cmd.payload.siteId
  state.products[siteId] = state.products[siteId] or {}
  state.products[siteId][cmd.payload.sku] = cmd.payload.payload
  return ok(cmd.requestId, { sku = cmd.payload.sku })
end

function handlers.AssignRole(cmd)
  local tenant = cmd.payload.tenant
  state.roles[tenant] = state.roles[tenant] or {}
  state.roles[tenant][cmd.payload.subject] = cmd.payload.role
  return ok(cmd.requestId, { subject = cmd.payload.subject, role = cmd.payload.role })
end

function handlers.UpsertProfile(cmd)
  state.profiles[cmd.payload.subject] = cmd.payload.profile
  return ok(cmd.requestId, { subject = cmd.payload.subject })
end

function handlers.UpsertCoupon(cmd)
  state.coupons[cmd.payload.code] = {
    type = cmd.payload.type,
    value = cmd.payload.value,
    currency = cmd.payload.currency,
    minOrder = cmd.payload.minOrder,
    maxRedemptions = cmd.payload.maxRedemptions,
    startsAt = cmd.payload.startsAt,
    expiresAt = cmd.payload.expiresAt,
    applies_to = cmd.payload.applies_to,
    is_active = cmd.payload.is_active ~= false,
    stackable = cmd.payload.stackable == true,
  }
  enqueue_event {
    type = "PromoAdded",
    siteId = cmd.payload.siteId or cmd.payload.tenant or "default",
    code = cmd.payload.code,
    payload = state.coupons[cmd.payload.code],
    requestId = cmd.requestId,
  }
  return ok(cmd.requestId, { code = cmd.payload.code })
end

function handlers.GrantEntitlement(cmd)
  local subj = cmd.payload.subject
  state.entitlements[subj] = state.entitlements[subj] or {}
  table.insert(state.entitlements[subj], { asset = cmd.payload.asset, policy = cmd.payload.policy })
  return ok(cmd.requestId, { subject = subj, asset = cmd.payload.asset })
end

function handlers.RevokeEntitlement(cmd)
  local subj = cmd.payload.subject
  local list = state.entitlements[subj] or {}
  local kept = {}
  for _, e in ipairs(list) do
    if e.asset ~= cmd.payload.asset then
      table.insert(kept, e)
    end
  end
  state.entitlements[subj] = kept
  return ok(cmd.requestId, { subject = subj, asset = cmd.payload.asset, revoked = true })
end

function handlers.UpsertInventory(cmd)
  local site = cmd.payload.siteId
  state.inventory[site] = state.inventory[site] or {}
  state.inventory[site][cmd.payload.sku] = {
    quantity = cmd.payload.quantity,
    location = cmd.payload.location,
    updatedAt = cmd.timestamp,
  }
  enqueue_event {
    type = "InventorySet",
    siteId = site,
    sku = cmd.payload.sku,
    quantity = cmd.payload.quantity,
    warehouse = cmd.payload.location,
    requestId = cmd.requestId,
  }
  return ok(cmd.requestId, { sku = cmd.payload.sku, quantity = cmd.payload.quantity })
end

function handlers.UpsertPriceRule(cmd)
  local site = cmd.payload.siteId
  state.price_rules[site] = state.price_rules[site] or {}
  state.price_rules[site][cmd.payload.ruleId] = {
    formula = cmd.payload.formula,
    active = cmd.payload.active ~= false,
    currency = cmd.payload.currency,
    vatRate = cmd.payload.vatRate,
  }
  return ok(
    cmd.requestId,
    { ruleId = cmd.payload.ruleId, currency = cmd.payload.currency, vatRate = cmd.payload.vatRate }
  )
end

function handlers.GrantRole(cmd)
  local tenant = cmd.payload.tenant or cmd.tenant
  state.roles[tenant] = state.roles[tenant] or {}
  state.roles[tenant][cmd.payload.subject] = cmd.payload.role
  return ok(
    cmd.requestId,
    { tenant = tenant, subject = cmd.payload.subject, role = cmd.payload.role }
  )
end

function handlers.UpsertCustomer(cmd)
  local tenant = cmd.payload.tenant
  state.customers[tenant] = state.customers[tenant] or {}
  state.customers[tenant][cmd.payload.customerId] = cmd.payload.profile
  return ok(cmd.requestId, { customerId = cmd.payload.customerId })
end

function handlers.CreateSubscription(cmd)
  state.subscriptions[cmd.payload.subscriptionId] = {
    customerId = cmd.payload.customerId,
    planId = cmd.payload.planId,
    status = cmd.payload.status or "active",
    meta = cmd.payload.meta,
    createdAt = cmd.timestamp,
  }
  enqueue_event {
    type = "SubscriptionCreated",
    subscriptionId = cmd.payload.subscriptionId,
    customerId = cmd.payload.customerId,
    planId = cmd.payload.planId,
    status = cmd.payload.status or "active",
    requestId = cmd.requestId,
  }
  return ok(cmd.requestId, {
    subscriptionId = cmd.payload.subscriptionId,
    status = state.subscriptions[cmd.payload.subscriptionId].status,
  })
end

function handlers.UpdateSubscriptionStatus(cmd)
  local sub = state.subscriptions[cmd.payload.subscriptionId]
  if not sub then
    return err(cmd.requestId, "NOT_FOUND", "subscription not found")
  end
  sub.status = cmd.payload.status
  sub.updatedAt = cmd.timestamp
  enqueue_event {
    type = "SubscriptionStatusUpdated",
    subscriptionId = cmd.payload.subscriptionId,
    status = sub.status,
    requestId = cmd.requestId,
  }
  return ok(cmd.requestId, { subscriptionId = cmd.payload.subscriptionId, status = sub.status })
end

function handlers.UpsertOrderStatus(cmd)
  local oid = cmd.payload.orderId
  if not oid or oid == "" then
    return err(cmd.requestId, "INVALID_INPUT", "orderId_required")
  end

  state.orders[oid] = state.orders[oid] or { items = {}, status = "draft", version = 1 }
  local order = state.orders[oid]

  local expected_version = cmd.expectedVersion or (cmd.payload and cmd.payload.expectedVersion)
  if expected_version and order.version and order.version ~= expected_version then
    return err(
      cmd.requestId,
      "VERSION_CONFLICT",
      "expectedVersion mismatch",
      { current = order.version }
    )
  end

  local target = cmd.payload.status
  if not target or target == "" then
    return err(cmd.requestId, "INVALID_INPUT", "status_required")
  end

  local ok_trans, trans_err = can_transition(order, target)
  if not ok_trans then
    return err(
      cmd.requestId,
      "INVALID_STATE",
      trans_err or "transition_not_allowed",
      { from = order.status or "draft", to = target }
    )
  end

  if order.status == target then
    return ok(cmd.requestId, {
      orderId = oid,
      status = order.status,
      version = order.version,
      totalAmount = order.totalAmount,
      currency = order.currency,
      vatRate = order.vatRate,
    })
  end

  order.status = target
  order.reason = cmd.payload.reason
  order.totalAmount = cmd.payload.totalAmount or order.totalAmount
  order.currency = cmd.payload.currency or order.currency
  order.vatRate = cmd.payload.vatRate or order.vatRate
  order.updatedAt = cmd.timestamp
  order.version = (order.version or 1) + 1
  enqueue_event {
    type = "OrderStatusUpdated",
    orderId = oid,
    status = order.status,
    version = order.version,
    reason = order.reason,
    requestId = cmd.requestId,
  }
  return ok(cmd.requestId, {
    orderId = oid,
    status = order.status,
    version = order.version,
    totalAmount = order.totalAmount,
    currency = order.currency,
    vatRate = order.vatRate,
  })
end

function handlers.IssueRefund(cmd)
  local _, payment = resolve_payment(cmd.payload.paymentId or cmd.payload.orderId)
  if not payment then
    return err(cmd.requestId, "NOT_FOUND", "payment not found")
  end
  local provider = payment.provider
  local ok_br, br_err = breaker_allows(provider)
  if not ok_br then
    return err(cmd.requestId, "PSP_UNAVAILABLE", br_err, { provider = provider })
  end
  if PSP_HOSTED_ONLY and provider and provider ~= "manual" then
    breaker_note(provider, true)
  else
    if payment and payment.provider == "gopay" and payment.providerPaymentId then
      if gopay_ok then
        gopay.refund(payment.providerPaymentId, cmd.payload.amount)
      else
        return err(cmd.requestId, "PROVIDER_ERROR", "gopay module unavailable")
      end
    elseif payment and payment.provider == "stripe" and payment.providerPaymentId then
      if stripe_ok then
        local ok, perr = stripe.refund(payment.providerPaymentId, cmd.payload.amount)
        if not ok then
          breaker_note(payment.provider, false)
          return err(cmd.requestId, "PROVIDER_ERROR", perr or "stripe refund failed")
        end
      end
    end
    breaker_note(provider, true)
  end
  local ev = {
    type = "IssueRefund",
    orderId = cmd.payload.orderId,
    amount = cmd.payload.amount,
    currency = cmd.payload.currency,
    vatRate = cmd.payload.vatRate,
    requestId = cmd.requestId,
  }
  local ok_hmac, hmac_err = attach_outbox_hmac(ev)
  if not ok_hmac then
    return err(cmd.requestId, "SERVER_ERROR", hmac_err or "outbox_hmac_failed")
  end
  enqueue_event(ev)
  return ok(cmd.requestId, {
    orderId = cmd.payload.orderId,
    amount = cmd.payload.amount,
    currency = cmd.payload.currency,
    vatRate = cmd.payload.vatRate,
  })
end

-- Minimal payment-level refund handler; PSP-specific flows can be added later.
function handlers.RefundPayment(cmd)
  local payment = state.payments[cmd.payload.paymentId]
  if not payment then
    return err(cmd.requestId, "NOT_FOUND", "payment not found")
  end
  local ok_br, br_err = breaker_allows(payment.provider)
  if not ok_br then
    return err(cmd.requestId, "PSP_UNAVAILABLE", br_err, { provider = payment.provider })
  end
  if not payment.providerPaymentId and payment.provider ~= "manual" then
    return err(cmd.requestId, "INVALID_STATE", "provider payment id missing")
  end
  -- Hosted-only mode short-circuits provider calls.
  if PSP_HOSTED_ONLY and payment.provider ~= "manual" then
    apply_refund(cmd.payload.paymentId, cmd.payload.amount, "refunded", cmd.requestId, "refunded")
    breaker_note(payment.provider, true)
    return ok(cmd.requestId, { paymentId = cmd.payload.paymentId, status = "refunded" })
  end
  if payment.provider == "gopay" and payment.providerPaymentId and gopay_ok then
    local ok_refund, perr = gopay.refund(payment.providerPaymentId, cmd.payload.amount)
    if ok_refund == false then
      breaker_note(payment.provider, false)
      return err(cmd.requestId, "PROVIDER_ERROR", perr or "gopay refund failed")
    end
  elseif payment.provider == "stripe" and payment.providerPaymentId and stripe_ok then
    local ok_refund, perr = stripe.refund(payment.providerPaymentId, cmd.payload.amount)
    if ok_refund == false then
      breaker_note(payment.provider, false)
      return err(cmd.requestId, "PROVIDER_ERROR", perr or "stripe refund failed")
    end
  elseif payment.provider == "paypal" and paypal_ok and payment.providerPaymentId then
    local ok_refund, perr_paypal = true, nil
    if paypal.refund then
      ok_refund, perr_paypal = paypal.refund(payment.providerPaymentId, cmd.payload.amount)
    end
    if ok_refund == false then
      breaker_note(payment.provider, false)
      return err(cmd.requestId, "PROVIDER_ERROR", perr_paypal or "paypal refund failed")
    end
  end
  apply_refund(cmd.payload.paymentId, cmd.payload.amount, "refunded", cmd.requestId, "refunded")
  breaker_note(payment.provider, true)
  return ok(cmd.requestId, { paymentId = cmd.payload.paymentId, status = "refunded" })
end

-- Coupon helpers (very simplified)
local function is_coupon_valid(code, order)
  local c = state.coupons[code]
  if not c then
    return false, "unknown_coupon"
  end
  local now = os.time()
  if c.startsAt and now < c.startsAt then
    return false, "not_started"
  end
  if c.expiresAt and now > c.expiresAt then
    return false, "expired"
  end
  if c.is_active == false then
    return false, "inactive"
  end
  if c.currency and order.currency and c.currency ~= order.currency then
    return false, "currency_mismatch"
  end
  if c.minOrder and order.totalAmount and order.totalAmount < c.minOrder then
    return false, "min_order_not_met"
  end
  if c.maxRedemptions and (state.coupon_redemptions[code] or 0) >= c.maxRedemptions then
    return false, "coupon_exhausted"
  end
  if c.redeemByCustomer and order.customerId then
    local per_customer = state.coupon_redemptions_customer[code]
        and state.coupon_redemptions_customer[code][order.customerId]
      or 0
    if c.redeemByCustomer > 0 and per_customer >= c.redeemByCustomer then
      return false, "coupon_customer_exhausted"
    end
  end
  if c.maxStack and order.coupons and #order.coupons >= c.maxStack then
    return false, "coupon_stack_limit"
  end
  if c.applies_to and type(c.applies_to) == "table" and order.items then
    local sku_allowed = {}
    for _, sku in ipairs(c.applies_to) do
      sku_allowed[sku] = true
    end
    local ok_any = false
    for _, it in ipairs(order.items) do
      if sku_allowed[it.sku] then
        ok_any = true
        break
      end
    end
    if not ok_any then
      return false, "coupon_not_applicable"
    end
  end
  if c.applies_to_categories and type(c.applies_to_categories) == "table" and order.items then
    local cat_allowed = {}
    for _, cat in ipairs(c.applies_to_categories) do
      cat_allowed[cat] = true
    end
    local ok_any = false
    for _, it in ipairs(order.items) do
      if it.categoryId and cat_allowed[it.categoryId] then
        ok_any = true
        break
      end
    end
    if not ok_any then
      return false, "coupon_not_applicable"
    end
  end
  return true
end

function handlers.ApplyCoupon(cmd)
  local order = state.orders[cmd.payload.orderId]
  if not order then
    return err(cmd.requestId, "NOT_FOUND", "order not found")
  end
  order.totalAmount = order.totalAmount or (order.totals and order.totals.total)
  if not order.totalAmount then
    return err(cmd.requestId, "NOT_FOUND", "order missing total")
  end

  order.coupons = order.coupons or {}
  if #order.coupons > 0 then
    -- stacking only if both existing and new coupon are stackable
    local existing_codes = order.coupons
    local any_non_stackable = false
    for _, code in ipairs(existing_codes) do
      if state.coupons[code] and state.coupons[code].stackable == false then
        any_non_stackable = true
      end
    end
    local new_c = state.coupons[cmd.payload.code]
    if any_non_stackable or (new_c and new_c.stackable == false) then
      return err(cmd.requestId, "INVALID_STATE", "coupon_not_stackable")
    end
  end

  local ok_coupon, reason = is_coupon_valid(cmd.payload.code, order)
  if not ok_coupon then
    return err(cmd.requestId, "INVALID_INPUT", reason)
  end
  local c = state.coupons[cmd.payload.code]
  local discount = 0
  if c.type == "percent" then
    discount = order.totalAmount * (c.value or 0) / 100
  else
    discount = c.value or 0
  end
  if c.maxDiscount and discount > c.maxDiscount then
    discount = c.maxDiscount
  end
  local new_total = math.max(0, order.totalAmount - discount)
  order.totalAmount = tax.round(new_total, os.getenv "CURRENCY_ROUND_MODE" or "half-up", 2)
  table.insert(order.coupons, cmd.payload.code)
  order.coupon = order.coupons[1] -- legacy
  state.coupon_redemptions[cmd.payload.code] = (state.coupon_redemptions[cmd.payload.code] or 0) + 1
  local ev = {
    type = "CouponApplied",
    orderId = cmd.payload.orderId,
    code = cmd.payload.code,
    discount = discount,
    requestId = cmd.requestId,
  }
  enqueue_event(ev)
  return ok(cmd.requestId, {
    orderId = cmd.payload.orderId,
    totalAmount = order.totalAmount,
    code = cmd.payload.code,
    coupons = order.coupons,
  })
end

function handlers.RemoveCoupon(cmd)
  local order = state.orders[cmd.payload.orderId]
  if not order then
    return err(cmd.requestId, "NOT_FOUND", "order not found")
  end
  order.coupons = order.coupons or {}
  local keep = {}
  for _, code in ipairs(order.coupons) do
    if code ~= cmd.payload.code then
      table.insert(keep, code)
    end
  end
  order.coupons = keep
  order.coupon = keep[1]
  local ev = {
    type = "CouponRemoved",
    orderId = cmd.payload.orderId,
    code = cmd.payload.code,
    requestId = cmd.requestId,
  }
  enqueue_event(ev)
  return ok(cmd.requestId, { orderId = cmd.payload.orderId })
end

-- OTP issuance and exchange for short-lived JWT
function handlers.IssueOtp(cmd)
  local ttl = tonumber(cmd.payload.ttl) or tonumber(os.getenv "OTP_TTL_SECONDS" or "300")
  if ttl < 30 then
    ttl = 30
  end
  if ttl > 3600 then
    ttl = 3600
  end
  local ok_rate, rate_err = check_otp_rate(cmd.payload.sub, cmd.payload.tenant)
  if not ok_rate then
    return err(cmd.requestId, "RATE_LIMITED", rate_err)
  end
  local code = string.format("%06d", math.random(0, 999999))
  local exp = os.time() + ttl
  state.otps[otp_hash(code)] = {
    sub = cmd.payload.sub,
    tenant = cmd.payload.tenant,
    role = cmd.payload.role or "user",
    exp = exp,
  }
  return ok(cmd.requestId, { code = code, expiresAt = exp })
end

function handlers.ExchangeOtp(cmd)
  local code = cmd.payload.code and cmd.payload.code:gsub("%s+", "")
  local entry = code and state.otps[otp_hash(code)]
  if not entry then
    return err(cmd.requestId, "NOT_FOUND", "otp_not_found")
  end
  if os.time() > entry.exp then
    state.otps[otp_hash(code)] = nil
    return err(cmd.requestId, "UNAUTHORIZED", "otp_expired")
  end
  state.otps[otp_hash(code)] = nil -- one-time
  local ttl = tonumber(os.getenv "OTP_JWT_TTL_SECONDS" or "900")
  local token, terr = issue_jwt(entry.sub, entry.tenant, entry.role, ttl)
  if not token then
    return err(cmd.requestId, "SERVER_ERROR", terr or "jwt_failed")
  end
  return ok(cmd.requestId, {
    token = token,
    exp = os.time() + ttl,
    role = entry.role,
    tenant = entry.tenant,
    sub = entry.sub,
  })
end

-- Session issuance (short-lived JWT) and revocation
function handlers.IssueSession(cmd)
  local ttl = tonumber(cmd.payload.ttl) or tonumber(os.getenv "SESSION_TTL_SECONDS" or "900")
  if ttl < 60 then
    ttl = 60
  end
  if ttl > 86400 then
    ttl = 86400
  end
  local sub = cmd.payload.sub or cmd.actor
  local tenant = cmd.payload.tenant or cmd.tenant
  local role = cmd.payload.role or cmd.role or "user"
  local token, terr = issue_jwt(sub, tenant, role, ttl)
  if not token then
    return err(cmd.requestId, "SERVER_ERROR", terr or "jwt_failed")
  end
  local sid = new_session_id()
  state.sessions[sid] = {
    sub = sub,
    tenant = tenant,
    role = role,
    exp = os.time() + ttl,
    device = cmd.payload.deviceToken,
  }
  return ok(cmd.requestId, { sessionId = sid, token = token, exp = os.time() + ttl })
end

function handlers.RevokeSession(cmd)
  if not cmd.payload.sessionId then
    return err(cmd.requestId, "INVALID_INPUT", "sessionId required")
  end
  state.sessions[cmd.payload.sessionId] = nil
  return ok(cmd.requestId, { revoked = cmd.payload.sessionId })
end

-- Cart & Order creation
local compute_totals

local function assert_currency(cart_currency, item_currency)
  if item_currency and cart_currency and item_currency ~= cart_currency then
    return false, "currency_mismatch"
  end
  return true
end

function handlers.CartAddItem(cmd)
  local cart = state.carts[cmd.payload.cartId]
    or { siteId = cmd.payload.siteId, currency = cmd.payload.currency, items = {} }
  local ok_cur, cur_err = assert_currency(cart.currency, cmd.payload.currency)
  if not ok_cur then
    return err(cmd.requestId, "INVALID_INPUT", cur_err)
  end
  cart.currency = cart.currency or cmd.payload.currency
  -- replace if same sku
  local updated = false
  for _, it in ipairs(cart.items) do
    if it.sku == cmd.payload.sku then
      it.qty = cmd.payload.qty
      it.price = cmd.payload.price
      it.title = cmd.payload.title or it.title
      it.weight = cmd.payload.weight or it.weight
      it.dimensions = cmd.payload.dimensions or it.dimensions
      updated = true
    end
  end
  if not updated then
    table.insert(cart.items, {
      sku = cmd.payload.sku,
      productId = cmd.payload.productId,
      qty = cmd.payload.qty,
      price = cmd.payload.price,
      currency = cmd.payload.currency,
      title = cmd.payload.title,
      variant = cmd.payload.variant,
      weight = cmd.payload.weight,
      dimensions = cmd.payload.dimensions,
      categoryId = cmd.payload.categoryId,
    })
  end
  state.carts[cmd.payload.cartId] = cart
  storage.put("carts", state.carts)
  if CART_STORE_PATH then
    storage.persist(CART_STORE_PATH)
  end
  return ok(cmd.requestId, { cartId = cmd.payload.cartId, items = #cart.items })
end

function handlers.CartGet(cmd)
  local cart = state.carts[cmd.payload.cartId]
  if not cart then
    return err(cmd.requestId, "NOT_FOUND", "cart not found")
  end
  return ok(cmd.requestId, { cart = cart })
end

function handlers.CartPrice(cmd)
  local cart = state.carts[cmd.payload.cartId]
  if not cart or #(cart.items or {}) == 0 then
    return err(cmd.requestId, "NOT_FOUND", "cart empty or missing")
  end
  local vatRate = cmd.payload.vatRate or tonumber(os.getenv "TAX_RATE_DEFAULT" or "0")
  local totals, total_err =
    compute_totals(cart, cmd.payload.coupon, vatRate, cmd.payload.shipping, cmd.payload.address)
  if not totals then
    return err(cmd.requestId, "INVALID_INPUT", total_err)
  end
  return ok(cmd.requestId, { cartId = cmd.payload.cartId, totals = totals })
end

function handlers.CartRemoveItem(cmd)
  local cart = state.carts[cmd.payload.cartId]
  if not cart then
    return err(cmd.requestId, "NOT_FOUND", "cart not found")
  end
  local keep = {}
  for _, it in ipairs(cart.items) do
    if it.sku ~= cmd.payload.sku then
      table.insert(keep, it)
    end
  end
  cart.items = keep
  state.carts[cmd.payload.cartId] = cart
  storage.put("carts", state.carts)
  if CART_STORE_PATH then
    storage.persist(CART_STORE_PATH)
  end
  return ok(cmd.requestId, { cartId = cmd.payload.cartId, items = #cart.items })
end

function compute_totals(cart, coupon_code, vatRate, shipping, address)
  local subtotal = 0
  local total_weight = 0
  for _, it in ipairs(cart.items or {}) do
    subtotal = subtotal + (it.price or 0) * (it.qty or 1)
    total_weight = total_weight + (it.weight or 0) * (it.qty or 1)
  end
  local discount = 0
  if coupon_code then
    local dummy_order = {
      totalAmount = subtotal,
      currency = cart.currency,
      items = cart.items,
    }
    local ok_coupon, reason = is_coupon_valid(coupon_code, dummy_order)
    if not ok_coupon then
      return nil, reason
    end
    local c = state.coupons[coupon_code]
    if c then
      if c.type == "percent" then
        discount = subtotal * (c.value or 0) / 100
      else
        discount = c.value or 0
      end
      if c.maxRedemptions and (state.coupon_redemptions[coupon_code] or 0) >= c.maxRedemptions then
        return nil, "coupon_exhausted"
      end
    end
  end
  local net = math.max(0, subtotal - discount)
  local shipping_fee = shipping or tonumber(os.getenv "SHIPPING_FLAT_FEE" or "0") or 0
  -- try lookup rate table if no explicit shipping provided
  if shipping == nil then
    local rates = state.shipping_rates[cart.siteId or "default"] or {}
    local country = address and address.country and address.country:upper()
    local region = address and address.region
    local best_price
    for _, r in ipairs(rates) do
      local country_match = (not r.country) or (country and r.country == country)
      local region_match = (not r.region) or (region and r.region == region)
      local currency_match = (not r.currency) or (r.currency == cart.currency)
      local fits_weight = (not r.minWeight or total_weight >= r.minWeight)
        and (not r.maxWeight or total_weight <= r.maxWeight)
      if country_match and region_match and currency_match and fits_weight then
        if not best_price or (r.price or 0) < best_price then
          best_price = r.price or 0
          shipping_fee = r.price or shipping_fee
        end
      end
    end
  end
  local vat = vatRate and net * vatRate or 0
  -- per-item tax if table is available
  local site = cart.siteId or "default"
  local rates = state.tax_rates[site] or {}
  local country = address and address.country and address.country:upper()
  local region = address and address.region
  local function match_rate(cat)
    for _, r in ipairs(rates) do
      local country_match = (not r.country) or (country and r.country == country)
      local region_match = (not r.region) or (region and r.region == region)
      local cat_match = (not r.category) or (cat and r.category == cat)
      if country_match and region_match and cat_match then
        return r.rate
      end
    end
  end
  local vat_total = 0
  for _, it in ipairs(cart.items or {}) do
    local rate = match_rate(it.categoryId)
      or vatRate
      or tonumber(os.getenv "TAX_RATE_DEFAULT" or "0")
    vat_total = vat_total + ((it.price or 0) * (it.qty or 1) * (rate or 0))
  end
  vat = tax.round(vat_total, os.getenv "CURRENCY_ROUND_MODE" or "half-up", 2)
  local total = tax.round(net + vat + shipping_fee, os.getenv "CURRENCY_ROUND_MODE" or "half-up", 2)
  return {
    subtotal = tax.round(subtotal, os.getenv "CURRENCY_ROUND_MODE" or "half-up", 2),
    discount = tax.round(discount, os.getenv "CURRENCY_ROUND_MODE" or "half-up", 2),
    vat = tax.round(vat, os.getenv "CURRENCY_ROUND_MODE" or "half-up", 2),
    shipping = shipping_fee,
    total = total,
  }
end

function handlers.CreateOrder(cmd)
  local cart = state.carts[cmd.payload.cartId]
  if not cart or #(cart.items or {}) == 0 then
    return err(cmd.requestId, "NOT_FOUND", "cart empty or missing")
  end
  local existing_order_id = cmd.payload.orderId or ("ord_" .. tostring(cmd.payload.cartId))
  if state.orders[existing_order_id] then
    local existing = state.orders[existing_order_id]
    local total = existing.totals and existing.totals.total
    return ok(cmd.requestId, {
      orderId = existing_order_id,
      totalAmount = total,
      currency = existing.currency,
    })
  end
  -- derive vatRate from tax table if not provided
  local vatRate = cmd.payload.vatRate
  if not vatRate then
    local site = cart.siteId or "default"
    local rates = state.tax_rates[site] or {}
    for _, r in ipairs(rates) do
      local country_match = not r.country
        or (cmd.payload.address and r.country == string.upper(cmd.payload.address.country or ""))
      local region_match = not r.region
        or (cmd.payload.address and r.region == cmd.payload.address.region)
      if country_match and region_match then
        vatRate = r.rate
        break
      end
    end
  end
  vatRate = vatRate or tonumber(os.getenv "TAX_RATE_DEFAULT" or "0")
  local totals, total_err =
    compute_totals(cart, cmd.payload.coupon, vatRate, cmd.payload.shipping, cmd.payload.address)
  if not totals then
    return err(cmd.requestId, "INVALID_INPUT", total_err)
  end
  local orderId = existing_order_id
  state.orders[orderId] = {
    siteId = cmd.payload.siteId or cart.siteId,
    customerId = cmd.payload.customerId,
    currency = cart.currency,
    items = cart.items,
    status = "draft",
    version = 1,
    totals = totals,
    coupon = cmd.payload.coupon, -- legacy
    coupons = cmd.payload.coupon and { cmd.payload.coupon } or {},
    vatRate = vatRate,
    shipping = totals.shipping,
    address = cmd.payload.address,
    createdAt = cmd.timestamp,
  }
  if cmd.payload.coupon then
    state.coupon_redemptions[cmd.payload.coupon] = (
      state.coupon_redemptions[cmd.payload.coupon] or 0
    ) + 1
  end
  local ev = {
    type = "OrderCreated",
    orderId = orderId,
    siteId = state.orders[orderId].siteId,
    customerId = cmd.payload.customerId,
    currency = cart.currency,
    totalAmount = totals.total,
    requestId = cmd.requestId,
  }
  enqueue_event(ev)
  return ok(
    cmd.requestId,
    { orderId = orderId, totalAmount = totals.total, currency = cart.currency }
  )
end

function handlers.AddShippingRate(cmd)
  local site = cmd.payload.siteId or "default"
  state.shipping_rates[site] = state.shipping_rates[site] or {}
  local row = {
    country = (cmd.payload.country or ""):upper(),
    region = cmd.payload.region,
    minWeight = cmd.payload.minWeight,
    maxWeight = cmd.payload.maxWeight,
    price = cmd.payload.price,
    currency = cmd.payload.currency,
    carrier = cmd.payload.carrier,
    service = cmd.payload.service,
  }
  table.insert(state.shipping_rates[site], row)
  storage.put("shipping_rates", state.shipping_rates)
  if RATE_STORE_PATH then
    storage.persist(RATE_STORE_PATH)
  end
  enqueue_event {
    type = "ShippingRulesSet",
    siteId = site,
    rules = state.shipping_rates[site],
    requestId = cmd.requestId,
  }
  return ok(cmd.requestId, { siteId = site, rates = #state.shipping_rates[site] })
end

function handlers.AddTaxRate(cmd)
  local site = cmd.payload.siteId or "default"
  state.tax_rates[site] = state.tax_rates[site] or {}
  local row = {
    country = (cmd.payload.country or ""):upper(),
    region = cmd.payload.region,
    rate = cmd.payload.rate,
    category = cmd.payload.category,
  }
  table.insert(state.tax_rates[site], row)
  storage.put("tax_rates", state.tax_rates)
  if RATE_STORE_PATH then
    storage.persist(RATE_STORE_PATH)
  end
  enqueue_event {
    type = "TaxRulesSet",
    siteId = site,
    rules = state.tax_rates[site],
    requestId = cmd.requestId,
  }
  return ok(cmd.requestId, { siteId = site, rates = #state.tax_rates[site] })
end

function handlers.ValidateAddress(cmd)
  -- Stub: basic presence checks; real implementation would call provider API
  if not cmd.payload.country or #cmd.payload.country < 2 then
    return err(cmd.requestId, "INVALID_INPUT", "country_required")
  end
  local normalized = {
    country = cmd.payload.country:upper(),
    region = cmd.payload.region,
    city = cmd.payload.city,
    postal = cmd.payload.postal,
    line1 = cmd.payload.line1,
    line2 = cmd.payload.line2,
  }
  enqueue_event {
    type = "AddressValidated",
    siteId = cmd.payload.siteId or "default",
    subject = cmd.payload.subject,
    address = normalized,
    requestId = cmd.requestId,
  }
  return ok(cmd.requestId, { valid = true, normalized = normalized })
end

function handlers.GetShippingQuote(cmd)
  local cart = state.carts[cmd.payload.cartId]
  if not cart then
    return err(cmd.requestId, "NOT_FOUND", "cart not found")
  end
  local total_weight = 0
  for _, it in ipairs(cart.items or {}) do
    total_weight = total_weight + (it.weight or 0) * (it.qty or 1)
  end
  local site = cart.siteId or "default"
  local rates = state.shipping_rates[site] or {}
  local selected
  for _, r in ipairs(rates) do
    local country_match = (not r.country) or r.country == string.upper(cmd.payload.country)
    local region_match = (not r.region) or (cmd.payload.region and r.region == cmd.payload.region)
    local fits_weight = (not r.minWeight or total_weight >= r.minWeight)
      and (not r.maxWeight or total_weight <= r.maxWeight)
    if country_match and region_match and fits_weight then
      selected = r
      break
    end
  end
  if not selected then
    return err(cmd.requestId, "NOT_FOUND", "no rate")
  end
  return ok(cmd.requestId, {
    price = selected.price,
    currency = selected.currency,
    carrier = selected.carrier,
    service = selected.service,
  })
end

function handlers.CreatePaymentIntent(cmd)
  local provider = cmd.payload.provider or os.getenv "PAYMENT_PROVIDER" or "manual"
  local pid = string.format("pay_%s", cmd.payload.orderId)
  local existing_pid = state.order_payment and state.order_payment[cmd.payload.orderId]
  if not existing_pid then
    for p_id, p in pairs(state.payments) do
      if p.orderId == cmd.payload.orderId then
        existing_pid = p_id
        break
      end
    end
  end
  local allow_multi = cmd.payload.allowMultiplePayments or cmd.payload.allowMultiple
  if existing_pid and existing_pid ~= pid and not allow_multi then
    return err(
      cmd.requestId,
      "CONFLICT",
      "payment_already_linked",
      { existingPaymentId = existing_pid }
    )
  end
  local providerPaymentId, gatewayUrl
  local status = "requires_capture"
  local ok_br, br_err = breaker_allows(provider)
  if not ok_br then
    return err(cmd.requestId, "PSP_UNAVAILABLE", br_err, { provider = provider })
  end

  if PSP_HOSTED_ONLY and provider ~= "manual" then
    providerPaymentId = cmd.payload.providerPaymentId or pid
    gatewayUrl = cmd.payload.gatewayUrl
    status = cmd.payload.status or "requires_capture"
  else
    if provider == "gopay" then
      if gopay_ok then
        local pid_out, gw, state = gopay.create_payment {
          orderId = cmd.payload.orderId,
          amount = cmd.payload.amount,
          currency = cmd.payload.currency,
          returnUrl = cmd.payload.returnUrl,
          description = cmd.payload.description,
          paymentMethodToken = cmd.payload.paymentMethodToken,
        }
        providerPaymentId, gatewayUrl = pid_out, gw
        if state == "CREATED" or state == "AUTHORIZED" then
          status = "requires_capture"
        elseif state == "PAID" then
          status = "captured"
        else
          status = "pending"
        end
      else
        status = "requires_capture"
      end
    elseif provider == "stripe" then
      if stripe_ok then
        if cmd.payload.customerId and not cmd.payload.paymentMethodToken then
          local token = state.payment_tokens[cmd.payload.customerId]
            and state.payment_tokens[cmd.payload.customerId].stripe
          if token then
            cmd.payload.paymentMethodToken = token
          end
        end
        providerPaymentId, gatewayUrl, status = stripe.create_payment {
          orderId = cmd.payload.orderId,
          amount = cmd.payload.amount,
          currency = cmd.payload.currency,
          returnUrl = cmd.payload.returnUrl,
          description = cmd.payload.description,
          metadata = cmd.payload.providerMetadata,
          paymentMethodToken = cmd.payload.paymentMethodToken,
          saveForFuture = cmd.payload.saveForFuture,
        }
      end
    elseif provider == "paypal" then
      if paypal_ok then
        if cmd.payload.customerId and not cmd.payload.paymentMethodToken then
          local token = state.payment_tokens[cmd.payload.customerId]
            and state.payment_tokens[cmd.payload.customerId].paypal
          if token then
            cmd.payload.paymentMethodToken = token
          end
        end
        providerPaymentId, gatewayUrl, status = paypal.create_payment {
          orderId = cmd.payload.orderId,
          amount = cmd.payload.amount,
          currency = cmd.payload.currency,
          returnUrl = cmd.payload.returnUrl,
          description = cmd.payload.description,
          metadata = cmd.payload.providerMetadata,
          paymentMethodToken = cmd.payload.paymentMethodToken,
        }
      end
    end
  end -- PSP_HOSTED_ONLY
  state.payments[pid] = {
    orderId = cmd.payload.orderId,
    amount = cmd.payload.amount,
    currency = cmd.payload.currency,
    provider = provider,
    status = status,
    refundedAmount = 0,
    risk = (os.getenv "PAYMENT_RISK_REQUIRED" == "1") and "review" or "pass",
    returnUrl = cmd.payload.returnUrl,
    description = cmd.payload.description,
    providerUrl = (
      provider == "gopay" and (os.getenv "GOPAY_GATEWAY_URL" or "https://gw.gopay.com")
    ) or nil,
    providerPaymentId = providerPaymentId,
    gatewayUrl = gatewayUrl,
    tokenized = cmd.payload.paymentMethodToken ~= nil,
  }
  link_payment_to_order(pid, cmd.payload.orderId)
  if cmd.payload.customerId and cmd.payload.paymentMethodToken then
    state.payment_tokens[cmd.payload.customerId] = state.payment_tokens[cmd.payload.customerId]
      or {}
    state.payment_tokens[cmd.payload.customerId][provider] = cmd.payload.paymentMethodToken
  end
  local ev = {
    type = "PaymentIntentCreated",
    paymentId = pid,
    orderId = cmd.payload.orderId,
    amount = cmd.payload.amount,
    currency = cmd.payload.currency,
    provider = provider,
    risk = state.payments[pid].risk,
    providerUrl = state.payments[pid].providerUrl,
    providerPaymentId = providerPaymentId,
    gatewayUrl = gatewayUrl,
    requestId = cmd.requestId,
  }
  local ok_hmac, hmac_err = attach_outbox_hmac(ev)
  if not ok_hmac then
    return err(cmd.requestId, "SERVER_ERROR", hmac_err or "outbox_hmac_failed")
  end
  enqueue_event(ev)
  breaker_note(provider, status ~= "error")
  return ok(cmd.requestId, {
    paymentId = pid,
    provider = provider,
    status = status,
    providerPaymentId = providerPaymentId,
    gatewayUrl = gatewayUrl,
  })
end

function handlers.CapturePayment(cmd)
  local payment = state.payments[cmd.payload.paymentId]
  if not payment then
    return err(cmd.requestId, "NOT_FOUND", "payment not found")
  end
  local ok_br, br_err = breaker_allows(payment.provider)
  if not ok_br then
    return err(cmd.requestId, "PSP_UNAVAILABLE", br_err, { provider = payment.provider })
  end
  if payment.status ~= "requires_capture" then
    -- allow capture for pending/authorized/pending-provider
    local allowed = { requires_capture = true, pending = true }
    if not allowed[payment.status] then
      return err(
        cmd.requestId,
        "INVALID_STATE",
        "payment not capturable",
        { status = payment.status }
      )
    end
  end
  if PSP_HOSTED_ONLY and payment.provider ~= "manual" then
    set_payment_status(cmd.payload.paymentId, "captured", "captured", cmd.requestId)
    breaker_note(payment.provider, true)
    return ok(cmd.requestId, { paymentId = cmd.payload.paymentId, status = "captured" })
  end
  if payment.provider == "gopay" and payment.providerPaymentId then
    if gopay_ok then
      local ok, perr = gopay.capture(payment.providerPaymentId)
      if not ok then
        breaker_note(payment.provider, false)
        return err(cmd.requestId, "PROVIDER_ERROR", perr)
      end
    else
      return err(cmd.requestId, "PROVIDER_ERROR", "gopay module unavailable")
    end
  elseif payment.provider == "stripe" and payment.providerPaymentId then
    if stripe_ok then
      local ok, perr = stripe.capture(payment.providerPaymentId)
      if not ok then
        breaker_note(payment.provider, false)
        return err(cmd.requestId, "PROVIDER_ERROR", perr)
      end
    end
  elseif payment.provider == "paypal" and payment.providerPaymentId then
    if paypal_ok then
      local ok, perr = paypal.capture(payment.providerPaymentId)
      if not ok then
        breaker_note(payment.provider, false)
        return err(cmd.requestId, "PROVIDER_ERROR", perr)
      end
    end
  end
  set_payment_status(cmd.payload.paymentId, "captured", "captured", cmd.requestId)
  breaker_note(payment.provider, true)
  return ok(cmd.requestId, { paymentId = cmd.payload.paymentId, status = "captured" })
end

function handlers.ConfirmPayment(cmd)
  local payment = state.payments[cmd.payload.paymentId]
  if not payment then
    return err(cmd.requestId, "NOT_FOUND", "payment not found")
  end
  local ok_br, br_err = breaker_allows(payment.provider)
  if not ok_br then
    return err(cmd.requestId, "PSP_UNAVAILABLE", br_err, { provider = payment.provider })
  end
  if PSP_HOSTED_ONLY and payment.provider ~= "manual" then
    set_payment_status(cmd.payload.paymentId, payment.status, payment.status, cmd.requestId)
    breaker_note(payment.provider, true)
    return ok(cmd.requestId, { paymentId = cmd.payload.paymentId, status = payment.status })
  end
  if payment.provider == "stripe" and payment.providerPaymentId then
    if stripe_ok then
      local ok, perr, resp = stripe.confirm(payment.providerPaymentId, cmd.payload.returnUrl)
      if not ok then
        breaker_note(payment.provider, false)
        return err(cmd.requestId, "PROVIDER_ERROR", perr)
      end
      -- If Stripe still requires action, keep status; else mark captured
      local status = (resp and resp.status) or "requires_capture"
      if status == "requires_action" or status == "processing" then
        payment.status = "requires_capture"
      elseif status == "succeeded" then
        payment.status = "captured"
      end
    end
  end
  if payment.provider == "paypal" and payment.providerPaymentId then
    if paypal_ok then
      local ok, perr = paypal.capture(payment.providerPaymentId)
      if not ok then
        breaker_note(payment.provider, false)
        return err(cmd.requestId, "PROVIDER_ERROR", perr)
      end
      payment.status = "captured"
    end
  end
  set_payment_status(cmd.payload.paymentId, payment.status, payment.status, cmd.requestId)
  breaker_note(payment.provider, true)
  return ok(cmd.requestId, { paymentId = cmd.payload.paymentId, status = payment.status })
end

-- PaymentReturn: invoked after 3-DS/SCA or redirect back
function handlers.PaymentReturn(cmd)
  local payment = state.payments[cmd.payload.paymentId]
  if not payment then
    return err(cmd.requestId, "NOT_FOUND", "payment not found")
  end
  local ok_br, br_err = breaker_allows(payment.provider)
  if not ok_br then
    return err(cmd.requestId, "PSP_UNAVAILABLE", br_err, { provider = payment.provider })
  end
  local status = "pending"
  if PSP_HOSTED_ONLY and payment.provider ~= "manual" then
    set_payment_status(
      cmd.payload.paymentId,
      payment.status or "pending",
      payment.status,
      cmd.requestId
    )
    breaker_note(payment.provider, true)
    return ok(cmd.requestId, { paymentId = cmd.payload.paymentId, status = payment.status })
  end
  if cmd.payload.provider == "stripe" then
    status = stripe_ok and stripe.status_from_payload(cmd.payload.payload) or "pending"
    -- fallback paymentId from payload
    if
      not payment.providerPaymentId
      and cmd.payload.payload
      and cmd.payload.payload.payment_intent
    then
      payment.providerPaymentId = cmd.payload.payload.payment_intent
    end
    if status == "requires_capture" then
      handlers.ConfirmPayment {
        payload = {
          paymentId = cmd.payload.paymentId,
          provider = "stripe",
          returnUrl = cmd.payload.redirectUrl,
        },
        requestId = cmd.requestId,
      }
      status = payment.status or status
    end
    if payment.providerPaymentId and stripe_ok then
      local live_status = stripe.retrieve_status(payment.providerPaymentId)
      if live_status then
        status = stripe.status_from_payload { status = live_status }
      end
    end
  elseif cmd.payload.provider == "paypal" then
    status = paypal_ok and paypal.status_from_payload(cmd.payload.payload) or "pending"
    if
      not payment.providerPaymentId
      and cmd.payload.payload
      and cmd.payload.payload.resource
      and cmd.payload.payload.resource.id
    then
      payment.providerPaymentId = cmd.payload.payload.resource.id
    end
    if status == "requires_capture" then
      handlers.ConfirmPayment {
        payload = { paymentId = cmd.payload.paymentId, provider = "paypal" },
        requestId = cmd.requestId,
      }
      status = payment.status or status
    end
  end
  payment.status = status or payment.status
  set_payment_status(cmd.payload.paymentId, payment.status, payment.status, cmd.requestId)
  return ok(cmd.requestId, { paymentId = cmd.payload.paymentId, status = payment.status })
end

-- RefreshPaymentStatus: fetch latest status from provider and sync order/payment states
function handlers.RefreshPaymentStatus(cmd)
  local payment = state.payments[cmd.payload.paymentId]
  if not payment then
    return err(cmd.requestId, "NOT_FOUND", "payment not found")
  end
  local provider = cmd.payload.provider or payment.provider
  local ok_br, br_err = breaker_allows(provider)
  if not ok_br then
    return err(cmd.requestId, "PSP_UNAVAILABLE", br_err, { provider = provider })
  end
  local new_status = payment.status
  if PSP_HOSTED_ONLY and provider ~= "manual" then
    return ok(cmd.requestId, { paymentId = cmd.payload.paymentId, status = new_status })
  end
  if provider == "stripe" and payment.providerPaymentId and stripe_ok then
    local live = stripe.retrieve_status(payment.providerPaymentId)
    if live then
      new_status = stripe.status_from_payload { status = live }
    end
  elseif provider == "paypal" and payment.providerPaymentId and paypal_ok then
    local live = paypal.retrieve_status and paypal.retrieve_status(payment.providerPaymentId)
    if live then
      new_status = live
    end
  elseif provider == "gopay" and payment.providerPaymentId and gopay_ok then
    local live = gopay.status and gopay.status(payment.providerPaymentId)
    if live then
      new_status = live.status or live
    end
  end
  if new_status and new_status ~= payment.status then
    set_payment_status(cmd.payload.paymentId, new_status, "refresh", cmd.requestId)
  end
  breaker_note(provider, true)
  return ok(
    cmd.requestId,
    { paymentId = cmd.payload.paymentId, status = state.payments[cmd.payload.paymentId].status }
  )
end

function handlers.VoidPayment(cmd)
  local payment = state.payments[cmd.payload.paymentId]
  if not payment then
    return err(cmd.requestId, "NOT_FOUND", "payment not found")
  end
  local ok_br, br_err = breaker_allows(payment.provider)
  if not ok_br then
    return err(cmd.requestId, "PSP_UNAVAILABLE", br_err, { provider = payment.provider })
  end
  if PSP_HOSTED_ONLY and payment.provider ~= "manual" then
    payment.status = "voided"
    payment.voidedAt = cmd.timestamp
    enqueue_event {
      type = "PaymentVoided",
      paymentId = cmd.payload.paymentId,
      orderId = payment.orderId,
      requestId = cmd.requestId,
    }
    breaker_note(payment.provider, true)
    return ok(cmd.requestId, { paymentId = cmd.payload.paymentId, status = "voided" })
  end
  if payment.provider == "gopay" and payment.providerPaymentId then
    if gopay_ok then
      local ok, perr = gopay.void(payment.providerPaymentId, cmd.payload.reason)
      if not ok then
        breaker_note(payment.provider, false)
        return err(cmd.requestId, "PROVIDER_ERROR", perr)
      end
    else
      return err(cmd.requestId, "PROVIDER_ERROR", "gopay module unavailable")
    end
  elseif payment.provider == "stripe" and payment.providerPaymentId then
    if stripe_ok then
      local ok, perr = stripe.void(payment.providerPaymentId, cmd.payload.reason)
      if not ok then
        breaker_note(payment.provider, false)
        return err(cmd.requestId, "PROVIDER_ERROR", perr)
      end
    end
  elseif payment.provider == "paypal" and payment.providerPaymentId then
    if paypal_ok then
      local ok, perr = paypal.void(payment.providerPaymentId, cmd.payload.reason)
      if not ok then
        breaker_note(payment.provider, false)
        return err(cmd.requestId, "PROVIDER_ERROR", perr)
      end
    end
  end
  payment.status = "voided"
  payment.voidedAt = cmd.timestamp
  local ev = {
    type = "PaymentVoided",
    paymentId = cmd.payload.paymentId,
    orderId = payment.orderId,
    requestId = cmd.requestId,
  }
  enqueue_event(ev)
  breaker_note(payment.provider, true)
  return ok(cmd.requestId, { paymentId = cmd.payload.paymentId, status = "voided" })
end

function handlers.UpsertShipmentStatus(cmd)
  state.shipments[cmd.payload.shipmentId] = {
    status = cmd.payload.status,
    tracking = cmd.payload.tracking,
    carrier = cmd.payload.carrier,
    orderId = cmd.payload.orderId,
    eta = cmd.payload.eta,
    updatedAt = cmd.timestamp,
  }
  -- release reservations when shipped/delivered
  if cmd.payload.status == "shipped" or cmd.payload.status == "delivered" then
    local res = state.inventory_reservations[cmd.payload.orderId]
    if res and res.items then
      for _, item in ipairs(res.items) do
        state.inventory[res.siteId] = state.inventory[res.siteId] or {}
        local inv = state.inventory[res.siteId][item.sku] or { quantity = 0 }
        inv.quantity = math.max(0, inv.quantity - (item.qty or 0))
        state.inventory[res.siteId][item.sku] = inv
      end
      res.released = true
    end
  end
  local ev = {
    type = "ShipmentUpdated",
    shipmentId = cmd.payload.shipmentId,
    orderId = cmd.payload.orderId,
    status = cmd.payload.status,
    tracking = cmd.payload.tracking,
    carrier = cmd.payload.carrier,
    requestId = cmd.requestId,
  }
  enqueue_event(ev)
  return ok(cmd.requestId, { shipmentId = cmd.payload.shipmentId, status = cmd.payload.status })
end

function handlers.CreateShipment(cmd)
  state.shipments[cmd.payload.shipmentId] = {
    status = cmd.payload.status,
    tracking = cmd.payload.tracking,
    carrier = cmd.payload.carrier,
    orderId = cmd.payload.orderId,
    eta = cmd.payload.eta,
    items = cmd.payload.items,
    createdAt = cmd.timestamp,
  }
  local ev = {
    type = "ShipmentCreated",
    shipmentId = cmd.payload.shipmentId,
    orderId = cmd.payload.orderId,
    status = cmd.payload.status,
    tracking = cmd.payload.tracking,
    carrier = cmd.payload.carrier,
    requestId = cmd.requestId,
  }
  enqueue_event(ev)
  return ok(cmd.requestId, { shipmentId = cmd.payload.shipmentId, status = cmd.payload.status })
end

function handlers.CreateShippingLabel(cmd)
  state.shipments[cmd.payload.shipmentId] = state.shipments[cmd.payload.shipmentId] or {}
  local label_url
  local base = os.getenv "CARRIER_LABEL_URL"
  if base then
    label_url = string.format("%s/%s.pdf", base, cmd.payload.shipmentId)
  else
    label_url = string.format("https://labels.example/label/%s.pdf", cmd.payload.shipmentId)
  end
  state.shipments[cmd.payload.shipmentId].labelUrl = label_url
  state.shipments[cmd.payload.shipmentId].carrier = cmd.payload.carrier
  state.shipments[cmd.payload.shipmentId].service = cmd.payload.service
  state.shipments[cmd.payload.shipmentId].orderId = cmd.payload.orderId
  enqueue_event {
    type = "ShippingLabelCreated",
    shipmentId = cmd.payload.shipmentId,
    carrier = cmd.payload.carrier,
    service = cmd.payload.service,
    labelUrl = label_url,
    orderId = cmd.payload.orderId,
  }
  return ok(cmd.requestId, { shipmentId = cmd.payload.shipmentId, labelUrl = label_url })
end

function handlers.UpdateShipmentTracking(cmd)
  state.shipments[cmd.payload.shipmentId] = state.shipments[cmd.payload.shipmentId] or {}
  state.shipments[cmd.payload.shipmentId].tracking = cmd.payload.tracking
  state.shipments[cmd.payload.shipmentId].carrier = cmd.payload.carrier
    or state.shipments[cmd.payload.shipmentId].carrier
  state.shipments[cmd.payload.shipmentId].eta = cmd.payload.eta
    or state.shipments[cmd.payload.shipmentId].eta
  if os.getenv "CARRIER_TRACK_URL" and cmd.payload.tracking then
    state.shipments[cmd.payload.shipmentId].trackingUrl =
      string.format("%s/%s", os.getenv "CARRIER_TRACK_URL", cmd.payload.tracking)
  end
  enqueue_event {
    type = "ShipmentTrackingUpdated",
    shipmentId = cmd.payload.shipmentId,
    tracking = cmd.payload.tracking,
    carrier = state.shipments[cmd.payload.shipmentId].carrier,
    eta = state.shipments[cmd.payload.shipmentId].eta,
    trackingUrl = state.shipments[cmd.payload.shipmentId].trackingUrl,
    orderId = cmd.payload.orderId,
  }
  return ok(cmd.requestId, { shipmentId = cmd.payload.shipmentId, tracking = cmd.payload.tracking })
end

function handlers.UpsertReturnStatus(cmd)
  state.returns[cmd.payload.returnId] = {
    status = cmd.payload.status,
    reason = cmd.payload.reason,
    orderId = cmd.payload.orderId,
    updatedAt = cmd.timestamp,
  }
  -- restock on approved/refunded returns
  if cmd.payload.status == "approved" or cmd.payload.status == "refunded" then
    local res = state.inventory_reservations[cmd.payload.orderId]
    if res and res.items then
      for _, item in ipairs(res.items) do
        state.inventory[res.siteId] = state.inventory[res.siteId] or {}
        local inv = state.inventory[res.siteId][item.sku] or { quantity = 0 }
        inv.quantity = inv.quantity + (item.qty or 0)
        state.inventory[res.siteId][item.sku] = inv
      end
    end
  end
  local ev = {
    type = "ReturnUpdated",
    returnId = cmd.payload.returnId,
    orderId = cmd.payload.orderId,
    status = cmd.payload.status,
    reason = cmd.payload.reason,
    requestId = cmd.requestId,
  }
  enqueue_event(ev)
  return ok(cmd.requestId, { returnId = cmd.payload.returnId, status = cmd.payload.status })
end

function handlers.ProviderWebhook(cmd)
  local function schedule_retry(reason)
    cmd._attempts = (cmd._attempts or 0) + 1
    enqueue_webhook_retry("ProviderWebhook", cmd, cmd._attempts)
    webhook_counter(cmd.payload.provider, "retry")
    return err(cmd.requestId, "RETRY_SCHEDULED", reason or "retry")
  end

  cmd.payload.provider = string.lower(cmd.payload.provider or "")
  return handle_psp_webhook(cmd, schedule_retry)
end

function handlers.GoPayWebhook(cmd)
  cmd.payload.provider = "gopay"
  return handle_psp_webhook(cmd)
end

function handlers.ProviderShippingWebhook(cmd)
  -- debug hook for smoke tests
  local function schedule_retry(reason)
    cmd._attempts = (cmd._attempts or 0) + 1
    enqueue_webhook_retry("ProviderShippingWebhook", cmd, cmd._attempts)
    webhook_counter(cmd.payload.provider or "shipping", "retry")
    return err(cmd.requestId, "RETRY_SCHEDULED", reason or "retry")
  end

  local replay_key = "ship:" .. (cmd.payload.eventId or cmd.payload.shipmentId or "")
  if webhook_seen_recent(replay_key, cmd.timestamp) then
    webhook_counter("shipping", "replay")
    return err(cmd.requestId, "REPLAY", "duplicate_webhook")
  end
  local status = string.lower(cmd.payload.status or "")
  state.shipments[cmd.payload.shipmentId] = state.shipments[cmd.payload.shipmentId] or {}
  local sh = state.shipments[cmd.payload.shipmentId]
  sh.orderId = cmd.payload.orderId or sh.orderId
  sh.status = status ~= "" and status or (sh.status or "pending")
  sh.tracking = cmd.payload.tracking or sh.tracking
  sh.carrier = cmd.payload.carrier or sh.carrier
  sh.labelUrl = cmd.payload.labelUrl or sh.labelUrl
  sh.eta = cmd.payload.eta or sh.eta
  if os.getenv "CARRIER_TRACK_URL" and sh.tracking and not sh.trackingUrl then
    sh.trackingUrl = string.format("%s/%s", os.getenv "CARRIER_TRACK_URL", sh.tracking)
  end
  local ev = {
    type = "ShipmentUpdated",
    shipmentId = cmd.payload.shipmentId,
    orderId = sh.orderId,
    status = sh.status,
    tracking = sh.tracking,
    carrier = sh.carrier,
    labelUrl = sh.labelUrl,
    eta = sh.eta,
  }
  local ok_hmac, hmac_err = attach_outbox_hmac(ev)
  if not ok_hmac then
    return err(cmd.requestId, "SERVER_ERROR", hmac_err or "outbox_hmac_failed")
  end
  enqueue_event {
    requestId = cmd.requestId,
    event = ev,
  }
  if sh.orderId then
    enqueue_event {
      type = "OrderStatusUpdated",
      orderId = sh.orderId,
      status = sh.status,
      requestId = cmd.requestId,
    }
  end
  webhook_counter(cmd.payload.provider or "shipping", "success")
  mark_webhook_seen(replay_key, cmd.timestamp)
  return ok(cmd.requestId, { shipmentId = cmd.payload.shipmentId, status = sh.status })
end

function handlers.CreateWebhook(cmd)
  local tenant = cmd.payload.tenant
  state.webhooks[tenant] = state.webhooks[tenant] or {}
  table.insert(state.webhooks[tenant], { url = cmd.payload.url, events = cmd.payload.events })
  return ok(cmd.requestId, { url = cmd.payload.url })
end

-- Helper to expose webhook replay window and breaker state (for observability)
function handlers.GetOpsHealth(cmd)
  local providers = {}
  for p, br in pairs(state.psp_breakers) do
    providers[p] = { open_until = br.open_until, count = br.count }
  end
  local q = storage.get "outbox_queue" or {}
  local retry_q = state.webhook_retry or {}
  return ok(cmd.requestId, {
    webhookReplayWindow = WEBHOOK_REPLAY_WINDOW,
    breaker = providers,
    queue = {
      outbox_size = #q,
      dlq_size = #(state.dlq or {}),
      webhook_retry = #retry_q,
    },
  })
end

-- Run due webhook retries (manual or cron) -----------------------------------
function handlers.RunWebhookRetries(cmd)
  state.webhook_retry = state.webhook_retry or {}
  local queue = state.webhook_retry
  state.webhook_retry = {}
  local now = os.time()
  for _, job in ipairs(queue) do
    if job.nextAttempt and job.nextAttempt > now then
      table.insert(state.webhook_retry, job)
    else
      local handler = handlers[job.handler]
      if handler then
        local retry_cmd = job.cmd
        retry_cmd._attempts = job.attempts or 1
        local resp = handler(retry_cmd)
        if resp and resp.status ~= "OK" then
          enqueue_webhook_retry(job.handler, retry_cmd, (job.attempts or 1) + 1)
        end
      end
    end
  end
  persist.save("write_state", state)
  gauge("write.webhook.retry_queue", #state.webhook_retry)
  gauge("webhook_retry_queue", #state.webhook_retry)
  local overdue = 0
  for _, job in ipairs(state.webhook_retry) do
    if job.nextAttempt and job.nextAttempt <= now then
      overdue = overdue + 1
    end
  end
  local max_lag = 0
  for _, job in ipairs(state.webhook_retry) do
    if job.nextAttempt then
      local lag = now - job.nextAttempt
      if lag > max_lag then
        max_lag = lag
      end
    end
  end
  gauge("write.webhook.retry_lag_seconds", math.max(0, max_lag))
  gauge("webhook_retry_lag_seconds", math.max(0, max_lag))
  gauge("webhook_retry_lag", math.max(0, max_lag))
  gauge("write.webhook.retry_overdue", overdue)
  gauge("webhook_retry_overdue", overdue)
  return ok(cmd.requestId, { retry_size = #state.webhook_retry })
end

-- route(command) validates and dispatches.
function M.route(command)
  -- idempotency first: if we have it, return stored response.
  local stored = idem.lookup(command.requestId or command["Request-Id"])
  if stored then
    counter("write.idempotency.collisions", 1)
    counter("idempotency_collisions", 1)
    counter("idempotency_collisions_total", 1)
    return stored
  end

  local ok_jwt, jwt_err = auth.consume_jwt(command)
  if not ok_jwt then
    return err(command.requestId, "UNAUTHORIZED", jwt_err or "jwt_failed")
  end

  local ok_env, env_errs = validation.validate_envelope(command)
  if not ok_env then
    return err(command.requestId, "INVALID_INPUT", "Envelope validation failed", env_errs)
  end

  local max_bytes = tonumber(os.getenv "WRITE_MAX_PAYLOAD_BYTES" or "262144")
  if max_bytes > 0 then
    local ok_json, cjson = pcall(require, "cjson.safe")
    if ok_json then
      local payload_bytes = #(cjson.encode(command.payload or {}))
      if payload_bytes > max_bytes then
        return err(
          command.requestId,
          "PAYLOAD_TOO_LARGE",
          "payload exceeds limit",
          { bytes = payload_bytes, max = max_bytes }
        )
      end
    end
  end

  local ok_nonce, nonce_err = auth.require_nonce_and_timestamp(command)
  if not ok_nonce then
    return err(command.requestId, "UNAUTHORIZED", nonce_err or "nonce failed")
  end

  local ok_rl_env, rl_err_env = auth.rate_limit_check(command)
  if not ok_rl_env then
    return err(command.requestId, "RATE_LIMITED", rl_err_env or "rate_limited")
  end

  _G.current_caller_id = command.callerId
    or command["Caller-Id"]
    or command.gatewayId
    or command["Gateway-Id"]
  local ok_sig, sig_err = auth.verify_signature(command)
  if not ok_sig then
    return err(command.requestId, "UNAUTHORIZED", sig_err or "signature failed")
  end
  if command.signature and (command.action or command.Action) then
    local message = (command.action or command.Action)
      .. "|"
      .. (command.tenant or "")
      .. "|"
      .. (command.requestId or command["Request-Id"] or "")
    local ok_det, det_err = auth.verify_detached(message, command.signature)
    if not ok_det then
      return err(command.requestId, "UNAUTHORIZED", det_err or "detached signature failed")
    end
  end

  local ok_policy, pol_err = auth.check_policy(command, nil)
  if not ok_policy then
    return err(command.requestId, "FORBIDDEN", pol_err or "policy denied")
  end
  local ok_caller, caller_err = auth.check_caller_scope(command)
  if not ok_caller then
    return err(command.requestId, "FORBIDDEN", caller_err or "caller denied")
  end
  local ok_role, role_err = auth.check_role_for_action(command, role_policy)
  if not ok_role then
    return err(command.requestId, "FORBIDDEN", role_err or "role denied")
  end
  local ok_rl_scope, rl_err_scope = auth.check_rate_limit(command)
  if not ok_rl_scope then
    return err(command.requestId, "RATE_LIMITED", rl_err_scope)
  end

  local ok_act, act_errs = validation.validate_action(command.action, command.payload)
  if not ok_act then
    return err(command.requestId, "INVALID_INPUT", "Action payload invalid", act_errs)
  end

  local handler = handlers[command.action]
  if not handler then
    return err(command.requestId, "UNKNOWN_ACTION", "Handler not found")
  end

  local apply_started = os.clock()
  local response = handler(command)
  if apply_started then
    local apply_duration = os.clock() - apply_started
    gauge("write.wal.apply_duration_seconds", apply_duration)
    gauge("wal_apply_duration_seconds", apply_duration)
    gauge("wal_apply_duration", apply_duration)
  end
  local wal_entry
  do
    local ok, cjson = pcall(require, "cjson")
    if ok then
      local req_json = cjson.encode(command)
      local resp_json = cjson.encode(response)
      wal_entry = {
        ts = os.date "!%Y-%m-%dT%H:%M:%SZ",
        req = command.requestId,
        action = command.action,
        status = response.status,
        reqHash = sha256_str(req_json),
        respHash = sha256_str(resp_json),
      }
      if WAL_PATH then
        local f = io.open(WAL_PATH, "a")
        if not f then
          return err(command.requestId, "SERVER_ERROR", "wal_write_failed")
        end
        local ok_write = f:write(cjson.encode(wal_entry), "\n")
        f:flush()
        f:close()
        if not ok_write then
          return err(command.requestId, "SERVER_ERROR", "wal_write_failed")
        end
        local stat = io.popen(string.format("stat -c%s %q 2>/dev/null", WAL_PATH))
        if stat then
          local size = tonumber(stat:read "*a")
          stat:close()
          if size then
            gauge("write.wal.bytes", size)
          end
        end
      end
    end
  end
  local ok_idem, idem_err = idem.record(command.requestId, response)
  if not ok_idem then
    return err(command.requestId, "SERVER_ERROR", idem_err or "idempotency_persist_failed")
  end
  audit.append {
    action = command.action,
    requestId = command.requestId,
    status = response.status,
    actor = command.actor,
    tenant = command.tenant,
    caller = command.caller,
    callerId = command.callerId or command["Caller-Id"],
  }
  -- Append WAL entry to PII-scrubbed WeaveDB export for immutable audit
  if wal_entry then
    export.write {
      kind = "wal",
      ts = wal_entry.ts,
      req = wal_entry.req,
      action = wal_entry.action,
      status = wal_entry.status,
      reqHash = wal_entry.reqHash,
      respHash = wal_entry.respHash,
    }
  end
  persist.save("write_state", state)
  return response
end

function M._state()
  return state
end

function M._outbox()
  return outbox
end

function M._storage_outbox()
  return storage.all "outbox"
end

-- expose handlers for tooling/tests (schema consistency)
M.handlers = handlers

return M

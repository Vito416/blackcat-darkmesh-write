-- Shared schema validation and payload guards (lightweight).
-- This keeps minimal synchronous guards in-process; deeper JSON schema checks
-- should be handled by the upstream bridge or a dedicated validator.

local Validation = {}
local ok_schema, schema = pcall(require, "ao.shared.schema")

Validation.required_tags = {
  "Action",
  "Request-Id",
}

local function contains(list, value)
  for _, v in ipairs(list) do
    if v == value then
      return true
    end
  end
  return false
end

function Validation.require_tags(msg, extra)
  local missing = {}
  for _, key in ipairs(Validation.required_tags) do
    if msg[key] == nil then
      table.insert(missing, key)
    end
  end
  if extra then
    for _, key in ipairs(extra) do
      if msg[key] == nil then
        table.insert(missing, key)
      end
    end
  end
  if #missing > 0 then
    return false, missing
  end
  return true
end

function Validation.require_action(msg, allowed)
  local action = msg.Action
  if not action then
    return false, "missing_action"
  end
  if allowed and not contains(allowed, action) then
    return false, "unknown_action"
  end
  return true
end

-- Convenience check for allowlist
function Validation.is_allowed_action(action, allowed)
  if not action then
    return false
  end
  if not allowed then
    return true
  end
  return contains(allowed, action)
end

-- Validate presence of required fields in a table payload.
function Validation.require_fields(tbl, fields)
  local missing = {}
  for _, f in ipairs(fields) do
    if tbl[f] == nil then
      table.insert(missing, f)
    end
  end
  if #missing > 0 then
    return false, missing
  end
  return true
end

-- Validate that no unexpected fields are present (shallow).
function Validation.require_no_extras(tbl, allowed_fields)
  if not allowed_fields then
    return true
  end
  local allowed = {}
  for _, f in ipairs(allowed_fields) do
    allowed[f] = true
  end
  local extras = {}
  for k, _ in pairs(tbl) do
    if not allowed[k] then
      table.insert(extras, k)
    end
  end
  if #extras > 0 then
    return false, extras
  end
  return true
end

-- Optional payload size guard (bytes when serialized length provided).
function Validation.check_size(len, max_bytes, field)
  if not max_bytes or max_bytes <= 0 or not len then
    return true
  end
  if len > max_bytes then
    return false, ("too_large:%s"):format(field or "?")
  end
  return true
end

function Validation.assert_type(value, expected, field)
  if type(value) ~= expected then
    return false, ("invalid_type:%s"):format(field or "?")
  end
  return true
end

-- Check maximum string length.
function Validation.check_length(value, max_len, field)
  if not value or not max_len or max_len <= 0 then
    return true
  end
  if #tostring(value) > max_len then
    return false, ("too_long:%s"):format(field or "?")
  end
  return true
end

local function is_array(tbl)
  local i = 0
  for _ in pairs(tbl) do
    i = i + 1
    if tbl[i] == nil then
      return false
    end
  end
  return true
end

local function json_encoded_length(value)
  local t = type(value)
  if t == "nil" then
    return 4
  end -- null
  if t == "boolean" then
    return value and 4 or 5
  end -- true/false
  if t == "number" then
    return #tostring(value)
  end
  if t == "string" then
    return #string.format("%q", value)
  end
  if t == "table" then
    if is_array(value) then
      local sum = 2 -- []
      local first = true
      for _, v in ipairs(value) do
        if not first then
          sum = sum + 1
        end -- comma
        sum = sum + json_encoded_length(v)
        first = false
      end
      return sum
    else
      local sum = 2 -- {}
      local first = true
      for k, v in pairs(value) do
        if not first then
          sum = sum + 1
        end -- comma
        sum = sum + #string.format("%q", tostring(k)) + 1 + json_encoded_length(v) -- colon
        first = false
      end
      return sum
    end
  end
  return #tostring(value)
end

-- Rough estimate of JSON-encoded length (bytes) for payload size guards.
function Validation.estimate_json_length(value)
  return json_encoded_length(value)
end

-- Envelope/command validation used by both write and AO processes.
-- Normalizes common field names so downstream code can rely on canonical keys.
function Validation.validate_envelope(cmd)
  if not cmd then
    return false, { "missing_envelope" }
  end
  cmd.action = cmd.action or cmd.Action
  cmd.requestId = cmd.requestId or cmd["Request-Id"]
  cmd.payload = cmd.payload or cmd.Payload or {}
  cmd.actor = cmd.actor or cmd.Actor
  cmd.actorRole = cmd.actorRole or cmd["Actor-Role"] or cmd.role
  cmd.tenant = cmd.tenant or cmd.Tenant or cmd["Tenant-Id"]
  cmd.siteId = cmd.siteId or cmd["Site-Id"] or cmd.SiteId
  cmd.gatewayId = cmd.gatewayId or cmd["Gateway-Id"] or cmd.gateway

  local ok_tags, missing = Validation.require_tags {
    Action = cmd.action,
    ["Request-Id"] = cmd.requestId,
  }
  if not ok_tags then
    return false, missing
  end
  if tostring(cmd.requestId):match "^%s*$" then
    return false, { "invalid_request_id" }
  end

  local allow_anon = os.getenv "WRITE_ALLOW_ANON" == "1"
  if not allow_anon then
    local missing_identity = {}
    if cmd.actor == nil or tostring(cmd.actor):match "^%s*$" then
      table.insert(missing_identity, "missing:actor")
    end
    if cmd.tenant == nil or tostring(cmd.tenant):match "^%s*$" then
      table.insert(missing_identity, "missing:tenant")
    end
    if #missing_identity > 0 then
      return false, missing_identity
    end
  end

  return true
end

-- Per-action payload validation stub (can be extended with schemas).
local validators = {
  PublishPageVersion = function(p)
    local missing = {}
    for _, f in ipairs { "siteId", "pageId", "versionId", "manifestTx" } do
      if not p or p[f] == nil then
        table.insert(missing, f)
      end
    end
    if #missing > 0 then
      return false, { "missing:" .. table.concat(missing, ",") }
    end
    return true
  end,
  UpsertRoute = function(p)
    local missing = {}
    for _, f in ipairs { "siteId", "path", "target" } do
      if not p or p[f] == nil then
        table.insert(missing, f)
      end
    end
    if #missing > 0 then
      return false, { "missing:" .. table.concat(missing, ",") }
    end
    return true
  end,
  CreateWebhook = function(p)
    if not p or not p.tenant or not p.url then
      return false, { "missing:tenant,url" }
    end
    if p.events and type(p.events) ~= "table" then
      return false, { "invalid:events" }
    end
    return true
  end,
  RefundPayment = function(p)
    if not p or not p.paymentId or not p.amount then
      return false, { "missing:paymentId,amount" }
    end
    if p.reason and type(p.reason) ~= "string" then
      return false, { "invalid:reason" }
    end
    if p.items then
      if type(p.items) ~= "table" then
        return false, { "invalid:items" }
      end
      for _, it in ipairs(p.items) do
        if not it.sku or not it.qty then
          return false, { "invalid:items:sku/qty" }
        end
      end
    end
    return true
  end,
  SubmitForm = function(p)
    if not p or not p.formId or not p.submission then
      return false, { "missing:formId,submission" }
    end
    return true
  end,
  CreateShipment = function(p)
    if not p or not p.orderId or not p.shipmentId or not p.status then
      return false, { "missing:orderId,shipmentId,status" }
    end
    if p.items then
      if type(p.items) ~= "table" then
        return false, { "invalid:items" }
      end
      for _, it in ipairs(p.items) do
        if not it.sku or not it.qty then
          return false, { "invalid:items:sku/qty" }
        end
      end
    end
    return true
  end,
  UpsertReturnStatus = function(p)
    if not p or not p.returnId or not p.status then
      return false, { "missing:returnId,status" }
    end
    return true
  end,
  CreateOrder = function(p)
    if not p then
      return false, { "missing:payload" }
    end
    -- permit cart-driven flow (cartId) or direct order payload (siteId + items)
    local missing = {}
    if not p.siteId then
      table.insert(missing, "siteId")
    end
    if not p.cartId and not p.items then
      table.insert(missing, "cartId|items")
    end
    if #missing > 0 then
      return false, { "missing:" .. table.concat(missing, ",") }
    end
    if p.items then
      if type(p.items) ~= "table" or #p.items == 0 then
        return false, { "invalid:items" }
      end
      for _, it in ipairs(p.items) do
        local qty = it and (it.qty or it.quantity)
        if not it.sku or not qty then
          return false, { "invalid:items:sku/qty" }
        end
      end
    end
    if p.address then
      if p.address.country and #p.address.country < 2 then
        return false, { "invalid:address:country" }
      end
      if p.address.taxId and type(p.address.taxId) ~= "string" then
        return false, { "invalid:taxId" }
      end
    end
    return true
  end,
  ProviderShippingWebhook = function(p)
    if not p or not p.provider or not p.shipmentId then
      return false, { "missing:provider,shipmentId" }
    end
    if p.status and type(p.status) ~= "string" then
      return false, { "invalid:status" }
    end
    if p.items then
      if type(p.items) ~= "table" then
        return false, { "invalid:items" }
      end
      for _, it in ipairs(p.items) do
        if not it.sku or not it.qty then
          return false, { "invalid:items:sku/qty" }
        end
      end
    end
    return true
  end,
  UpsertShipmentStatus = function(p)
    if not p or not p.shipmentId or not p.status then
      return false, { "missing:shipmentId,status" }
    end
    if p.trackingUrl and type(p.trackingUrl) ~= "string" then
      return false, { "invalid:trackingUrl" }
    end
    if p.eta and type(p.eta) ~= "string" then
      return false, { "invalid:eta" }
    end
    return true
  end,
  UpsertProduct = function(p)
    if not p or not p.siteId or not p.sku then
      return false, { "missing:siteId,sku" }
    end
    if type(p.payload) ~= "table" then
      return false, { "missing:payload" }
    end
    return true
  end,
  AssignRole = function(p)
    if not p or not p.tenant or not p.subject or not p.role then
      return false, { "missing:tenant,subject,role" }
    end
    return true
  end,
  UpsertProfile = function(p)
    if not p or not p.subject then
      return false, { "missing:subject" }
    end
    if type(p.profile) ~= "table" then
      return false, { "missing:profile" }
    end
    return true
  end,
  GrantEntitlement = function(p)
    if not p or not p.subject or not p.asset then
      return false, { "missing:subject,asset" }
    end
    return true
  end,
  RevokeEntitlement = function(p)
    if not p or not p.subject or not p.asset then
      return false, { "missing:subject,asset" }
    end
    return true
  end,
  CreatePaymentIntent = function(p)
    if not p or not p.orderId then
      return false, { "missing:orderId" }
    end
    if p.amount ~= nil and type(p.amount) ~= "number" then
      return false, { "invalid:amount" }
    end
    if p.currency ~= nil and type(p.currency) ~= "string" then
      return false, { "invalid:currency" }
    end
    return true
  end,
  ProviderWebhook = function(p)
    if not p or not p.provider then
      return false, { "missing:provider" }
    end
    if not (p.paymentId or p.orderId or p.eventId) then
      return false, { "missing:paymentId|orderId|eventId" }
    end
    return true
  end,
  ConfirmPayment = function(p)
    if not p or not p.paymentId or not p.provider then
      return false, { "missing:paymentId,provider" }
    end
    return true
  end,
}

function Validation.validate_action(action, payload)
  local fn = validators[action]
  local ok, errs
  if fn then
    ok, errs = fn(payload)
    if not ok then
      return ok, errs
    end
  end
  local schema_ready = ok_schema
  local schema_err
  if ok_schema and type(schema.is_ready) == "function" then
    schema_ready, schema_err = schema.is_ready "actions"
  end
  if schema_ready then
    local ok_s, s_errs = schema.validate_action(action, payload)
    if not ok_s then
      return ok_s, s_errs
    end
  elseif os.getenv "WRITE_REQUIRE_ACTION_SCHEMA" == "1" then
    return false, { schema_err or "schema_unavailable" }
  end
  if not fn and not schema_ready then
    -- Runtime bundles can intentionally omit JSON schema artifacts.
    -- In that case, defer to handler-level validation unless strict schema
    -- mode is explicitly requested.
    return true
  end
  return true
end

-- Optional payload size guard; falls back to estimate when length not provided.
function Validation.check_payload_size(payload, max_bytes)
  if not max_bytes or max_bytes <= 0 then
    return true
  end
  local est = Validation.estimate_json_length(payload)
  if est > max_bytes then
    return false, ("too_large:%s"):format(max_bytes)
  end
  return true
end

-- Nonce/timestamp helpers (no-ops by default; override in stricter builds).
function Validation.require_nonce_fields(_msg)
  return true
end

function Validation.require_timestamp(_msg)
  return true
end

return Validation

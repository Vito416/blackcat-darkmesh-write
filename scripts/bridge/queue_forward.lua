#!/usr/bin/env lua
-- File queue forwarder: reads persisted outbox and WAL, appends to queue, retries HTTP delivery.

local storage = require("ao.shared.storage")
local bridge = require("ao.shared.bridge")
local cjson = require("cjson")
local queue_path = os.getenv("AO_QUEUE_PATH") or "dev/outbox-queue.ndjson"
local log_path = os.getenv("AO_QUEUE_LOG_PATH") or "dev/queue-log.ndjson"
local max_retries = tonumber(os.getenv("AO_QUEUE_MAX_RETRIES") or "5")
local outbox_path = os.getenv("WRITE_OUTBOX_PATH")
local outbox_hmac_secret = os.getenv("OUTBOX_HMAC_SECRET")
local strict_outbox_hmac = os.getenv("WRITE_STRICT_OUTBOX_HMAC") == "1"
local outbox_hmac_mode = os.getenv("WRITE_OUTBOX_HMAC_MODE") or "full" -- full|legacy
local crypto = require("ao.shared.crypto")
local metrics_ok, metrics = pcall(require, "ao.shared.metrics")
local function m_counter(name, value)
  if metrics_ok and metrics and metrics.counter then metrics.counter(name, value or 1) end
end

local function ensure_dir(path)
  local dir = path:match("(.+)/[^/]+$")
  if dir then os.execute(string.format('mkdir -p "%s"', dir)) end
end

local function load_queue()
  local entries = {}
  local f = io.open(queue_path, "r")
  if not f then return entries end
  for line in f:lines() do
    local ok, val = pcall(cjson.decode, line)
    if ok and val then table.insert(entries, val) end
  end
  f:close()
  return entries
end

local function sha256_str(str)
  local tmp = os.tmpname()
  local f = io.open(tmp, "w"); if not f then return nil end
  f:write(str); f:close()
  local p = io.popen("sha256sum " .. tmp .. " 2>/dev/null")
  local out = p and p:read("*a") or ""
  if p then p:close() end
  os.remove(tmp)
  return out:match("^(%w+)")
end

local function is_array(tbl)
  if type(tbl) ~= "table" then return false end
  local max = 0
  local count = 0
  for k, _ in pairs(tbl) do
    if type(k) ~= "number" then return false end
    if k > max then max = k end
    count = count + 1
  end
  return max == count
end

local function stable_encode(val)
  local t = type(val)
  if t == "nil" then return "null" end
  if t == "boolean" or t == "number" then return tostring(val) end
  if t == "string" then return cjson.encode(val) end -- reuse string escaping
  if t == "table" then
    if is_array(val) then
      local parts = {}
      for i = 1, #val do
        table.insert(parts, stable_encode(val[i]))
      end
      return "[" .. table.concat(parts, ",") .. "]"
    else
      local keys = {}
      for k in pairs(val) do table.insert(keys, k) end
      table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
      local parts = {}
      for _, k in ipairs(keys) do
        table.insert(parts, cjson.encode(tostring(k)) .. ":" .. stable_encode(val[k]))
      end
      return "{" .. table.concat(parts, ",") .. "}"
    end
  end
  return "null"
end

local function stable_encode_without_hmac(ev)
  if type(ev) ~= "table" then return stable_encode(ev) end
  local copy = {}
  for k, v in pairs(ev) do
    if k ~= "hmac" then copy[k] = v end
  end
  return stable_encode(copy)
end

local function append_log(entry)
  ensure_dir(log_path)
  local f = io.open(log_path, "a")
  if not f then return end
  f:write(cjson.encode(entry))
  f:write("\n")
  f:close()
end

local function save_queue(entries)
  ensure_dir(queue_path)
  local f = assert(io.open(queue_path, "w"))
  for _, ev in ipairs(entries) do
    f:write(cjson.encode(ev))
    f:write("\n")
  end
  f:close()
end

-- Seed queue from persisted outbox (if provided)
if outbox_path then
  storage.load(outbox_path)
end
local outbox = storage.all("outbox")

local queue = load_queue()
for _, ev in ipairs(outbox) do
  table.insert(queue, ev)
end

local delivered = {}
local remaining = {}
for _, ev in ipairs(queue) do
  ev.attempts = (ev.attempts or 0) + 1
  local req_hash = sha256_str(cjson.encode(ev))
  if outbox_hmac_secret then
    if strict_outbox_hmac and not ev.hmac then
      m_counter("write_outbox_hmac_missing_total", 1)
      append_log({ ts = os.date("!%Y-%m-%dT%H:%M:%SZ"), requestId = ev.requestId, status = "hmac_missing" })
      io.stderr:write(string.format("hmac missing for requestId=%s (strict mode)\n", tostring(ev.requestId)))
      goto skip
    end
    if ev.hmac then
      local msg
      if outbox_hmac_mode == "legacy" then
        msg = (ev.siteId or "") .. "|" .. (ev.pageId or ev.orderId or "") .. "|" .. (ev.versionId or ev.amount or "")
      else
        msg = stable_encode_without_hmac(ev)
      end
      local expected = crypto.hmac_sha256_hex(msg, outbox_hmac_secret)
      if expected and expected:lower() ~= tostring(ev.hmac):lower() then
        m_counter("write_outbox_hmac_mismatch_total", 1)
        append_log({ ts = os.date("!%Y-%m-%dT%H:%M:%SZ"), requestId = ev.requestId, status = "hmac_mismatch" })
        io.stderr:write(string.format("hmac mismatch for requestId=%s\n", tostring(ev.requestId)))
        goto skip
      end
    end
  end
  local ok, status, resp_hash = bridge.forward_event(ev)
  append_log({
    ts = os.date("!%Y-%m-%dT%H:%M:%SZ"),
    requestId = ev.requestId,
    action = ev.type,
    attempt = ev.attempts,
    ok = ok,
    status = status,
    reqHash = req_hash,
    respHash = resp_hash,
  })
  if ok then
    table.insert(delivered, ev)
  else
    if ev.attempts < max_retries then
      table.insert(remaining, ev)
    else
      io.stderr:write(string.format("dropping after %d attempts requestId=%s\n", ev.attempts, tostring(ev.requestId)))
    end
    io.stderr:write(string.format("deliver failed (%s) for requestId=%s\n", tostring(status), tostring(ev.requestId)))
  end
  ::skip::
end

save_queue(remaining)
print(string.format("[queue] delivered=%d pending=%d", #delivered, #remaining))

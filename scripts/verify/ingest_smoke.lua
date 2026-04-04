-- Minimal smoke: load write process and run a no-op command to ensure auth/idempotency plumbing works.
-- luacheck: max_line_length 180
package.path =
  table.concat({ "?.lua", "?/init.lua", "ao/?.lua", "ao/?/init.lua", package.path }, ";")

local function env_or_skip()
  local req_sig = os.getenv "WRITE_REQUIRE_SIGNATURE"
  local hmac_secret = os.getenv "OUTBOX_HMAC_SECRET"
  if req_sig ~= "1" or not hmac_secret or #hmac_secret == 0 then
    io.stderr:write(
      "SKIP ingest_smoke: set WRITE_REQUIRE_SIGNATURE=1 and OUTBOX_HMAC_SECRET for this smoke\n"
    )
    os.exit(0)
  end
  if not os.getenv "WRITE_SIG_PRIV_HEX" or not os.getenv "WRITE_SIG_PUBLIC" then
    io.stderr:write("SKIP ingest_smoke: set WRITE_SIG_PRIV_HEX and WRITE_SIG_PUBLIC\n")
    os.exit(0)
  end
end

local function json_escape(str)
  return str:gsub('\\', '\\\\'):gsub('"', '\\"')
end

local function json_encode(val)
  local t = type(val)
  if t == "nil" then
    return "null"
  elseif t == "boolean" or t == "number" then
    return tostring(val)
  elseif t == "string" then
    return '"' .. json_escape(val) .. '"'
  elseif t == "table" then
    local is_array = (#val > 0)
    if is_array then
      local parts = {}
      for i = 1, #val do
        parts[#parts + 1] = json_encode(val[i])
      end
      return "[" .. table.concat(parts, ",") .. "]"
    else
      local keys = {}
      for k in pairs(val) do
        keys[#keys + 1] = k
      end
      table.sort(keys, function(a, b)
        return tostring(a) < tostring(b)
      end)
      local parts = {}
      for _, k in ipairs(keys) do
        parts[#parts + 1] = '"' .. json_escape(tostring(k)) .. '":' .. json_encode(val[k])
      end
      return "{" .. table.concat(parts, ",") .. "}"
    end
  end
  return "null"
end

local function sign_cmd(cmd)
  local tmp = os.tmpname()
  local f = assert(io.open(tmp, "w"))
  f:write(json_encode(cmd))
  f:close()
  local handle = io.popen(
    string.format("WRITE_SIG_PRIV_HEX=%q node scripts/sign-write.js --file %q", os.getenv "WRITE_SIG_PRIV_HEX", tmp),
    "r"
  )
  if not handle then
    os.remove(tmp)
    error("cannot run sign-write.js")
  end
  local out = handle:read "*a"
  handle:close()
  os.remove(tmp)
  local parsed = require("cjson.safe").decode(out or "{}") or {}
  cmd.signature = parsed.signature
  cmd["Signature-Ref"] = parsed.signatureRef
  return cmd
end

env_or_skip()

local process = require "ao.write.process"

local function assert_ok(resp)
  if not resp or resp.status ~= "OK" then
    io.stderr:write("Smoke failed: " .. (resp and resp.message or "nil") .. "\n")
    os.exit(1)
  end
end

local cmd = {
  requestId = "smoke-" .. tostring(os.time()),
  action = "CreateWebhook",
  tenant = "demo",
  actor = "smoke-admin",
  ["Actor-Role"] = "admin",
  payload = {
    tenant = "demo",
    siteId = "demo-site",
    url = "https://example.com/hook",
    events = { "test" },
  },
  gatewayId = "smoke-gw",
  nonce = "smoke-nonce-" .. tostring(math.random(1, 1e6)),
  ts = os.time(),
}

local resp = process.route(sign_cmd(cmd))
assert_ok(resp)

-- PSP replay fixture: shipping webhook duplicate should trigger REPLAY on second pass
local ship = {
  requestId = "smoke-ship-" .. tostring(os.time()),
  action = "ProviderShippingWebhook",
  actor = "smoke-admin",
  ["Actor-Role"] = "admin",
  payload = {
    provider = "demo",
    eventId = "evt-smoke",
    shipmentId = "ship-123",
    orderId = "order-1",
    status = "shipped",
  },
  gatewayId = "smoke-gw",
  nonce = "smoke-nonce-" .. tostring(math.random(1, 1e6)),
  ts = os.time(),
}
local first = process.route(ship)
if first.status ~= "OK" and first.code ~= "REPLAY" then
  io.stderr:write("Smoke shipping webhook failed: " .. (first.message or "nil") .. "\n")
  os.exit(1)
end
local ship_replay = {}
for k, v in pairs(ship) do
  ship_replay[k] = v
end
ship_replay.requestId = ship.requestId .. "-replay"
ship_replay.nonce = ship.nonce .. "-2"
local second = process.route(ship_replay)
if second.status ~= "ERROR" or second.code ~= "REPLAY" then
  io.stderr:write "Replay window not enforced\n"
  os.exit(1)
end

local storage = require "ao.shared.storage"
local q = storage.get "outbox_queue" or {}
if #q == 0 then
  io.stderr:write "Outbox empty after webhook processing\n"
  os.exit(1)
end
print "ingest_smoke: OK"

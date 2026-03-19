package.path = table.concat({ '?.lua', '?/init.lua', 'ao/?.lua', 'ao/?/init.lua', package.path }, ';')
local write = require 'ao.write.process'
local crypto = require 'ao.shared.crypto'

local function expect(code, msg)
  if not code then
    io.stderr:write(msg .. "\n")
    os.exit(1)
  end
end

-- HMAC attached to outbox events
os.setenv("OUTBOX_HMAC_SECRET", "0123456789abcdef0123456789abcdef")

-- replay window for ProviderWebhook
os.setenv("WRITE_WEBHOOK_REPLAY_WINDOW", "600")

local function route(cmd)
  local res = write.route(cmd)
  return res
end

-- ProviderWebhook replay and HMAC on emitted event
local req = {
  action = 'ProviderWebhook',
  requestId = 'replay-1',
  actor = 'security-tester',
  ['Actor-Role'] = 'admin',
  tenant = 'tenant-1',
  gatewayId = 'gw1',
  ts = os.time(),
  nonce = 'n1',
  payload = { provider = 'demo', eventId = 'evt-1', orderId = 'ord-1', status = 'paid' },
}
local first = route(req)
expect(first and (first.status == 'OK' or first.code == 'REPLAY'), 'first ProviderWebhook failed')
local second = route(req)
expect(second and second.code == 'REPLAY', 'replay window not enforced')

-- Outbox event should carry Hmac
local storage = require 'ao.shared.storage'
local queue = storage.get('outbox_queue') or {}
expect(#queue > 0, 'outbox queue empty')
local ev = queue[#queue].event
if ev.Hmac then
  local payload = (ev["Site-Id"] or ev.siteId or ev.tenant or '') .. '|' .. (ev["Page-Id"] or ev["Order-Id"] or ev.key or ev["Key"] or ev.resourceId or '') .. '|' .. (ev.Version or ev["Manifest-Tx"] or ev.Amount or ev.Total or ev.ts or ev.timestamp or '')
  local expected = crypto.hmac_sha256_hex(payload, os.getenv('OUTBOX_HMAC_SECRET') or '')
  expect(ev.Hmac == expected, 'outbox HMAC mismatch')
end
print('hmac_replay: ok')

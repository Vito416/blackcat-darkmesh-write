-- luacheck: max_line_length 260
package.path =
  table.concat({ "?.lua", "?/init.lua", "ao/?.lua", "ao/?/init.lua", package.path }, ";")
local write = require "ao.write.process"
local crypto = require "ao.shared.crypto"
local storage = require "ao.shared.storage"

local function ok(res)
  return res and res.status == "OK"
end

-- build cart and order
local cart = write.route {
  Action = "CartAddItem",
  ["Request-Id"] = "eo-1",
  ["Actor-Role"] = "admin",
  nonce = "ne1",
  ts = os.time(),
  payload = {
    cartId = "cart_eo",
    siteId = "s1",
    currency = "USD",
    sku = "sku-eo",
    qty = 1,
    price = 1000,
  },
}
assert(ok(cart), "cart add failed")
local order = write.route {
  Action = "CreateOrder",
  ["Request-Id"] = "eo-2",
  ["Actor-Role"] = "admin",
  nonce = "ne2",
  ts = os.time(),
  payload = { orderId = "ord_eo", cartId = "cart_eo", siteId = "s1", currency = "USD" },
}
assert(ok(order), "order failed")
-- publish page version
local pub = write.route {
  Action = "PublishPageVersion",
  ["Request-Id"] = "eo-3",
  ["Actor-Role"] = "admin",
  nonce = "ne3",
  ts = os.time(),
  payload = { siteId = "s1", pageId = "home", versionId = "v1", manifestTx = "tx-eo" },
}
assert(ok(pub), "publish failed")

-- simulate outbox HMAC verification
local queue = storage.get "outbox_queue" or {}
assert(#queue > 0, "outbox empty")
for _, entry in ipairs(queue) do
  local ev = entry.event
  if ev.Hmac then
    local payload = (ev["Site-Id"] or ev.siteId or ev.tenant or "")
      .. "|"
      .. (ev["Page-Id"] or ev["Order-Id"] or ev.key or ev["Key"] or ev.resourceId or "")
      .. "|"
      .. (ev.Version or ev["Manifest-Tx"] or ev.Amount or ev.Total or ev.ts or ev.timestamp or "")
    local expected = crypto.hmac_sha256_hex(payload, os.getenv "OUTBOX_HMAC_SECRET" or "")
    assert(ev.Hmac == expected, "HMAC mismatch")
  end
end
print "publish_outbox_mock_ao: ok"
-- luacheck: max_line_length 260

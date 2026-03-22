-- luacheck: max_line_length 260
local home = os.getenv "HOME" or ""
package.path = table.concat({
  home .. "/.luarocks/share/lua/5.4/?.lua",
  home .. "/.luarocks/share/lua/5.4/?/init.lua",
  "?.lua",
  "?/init.lua",
  "ao/?.lua",
  "ao/?/init.lua",
  package.path,
}, ";")
package.cpath = table.concat({
  home .. "/.luarocks/lib/lua/5.4/?.so",
  package.cpath,
}, ";")

-- test-local env override without mutating os.getenv (luacheck-friendly)
-- expects OUTBOX_HMAC_SECRET to decode to 32 raw bytes; use 64-char hex here
local overrides = {
  OUTBOX_HMAC_SECRET = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
}
-- ensure early env lookups see the override
_G.OUTBOX_HMAC_SECRET = overrides.OUTBOX_HMAC_SECRET

local function getenv(k)
  if overrides[k] ~= nil then
    return overrides[k]
  end
  return os.getenv(k)
end

local write = require "ao.write.process"
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
    local auth = require "ao.shared.auth"
    local expected = auth.compute_outbox_hmac(ev, getenv "OUTBOX_HMAC_SECRET" or "")
    assert(expected, "HMAC compute failed")
    assert(ev.Hmac == expected, "HMAC mismatch")
  end
end
print "publish_outbox_mock_ao: ok"
-- luacheck: max_line_length 260

local write = require "ao.write.process"
local ingest = require "ao.ingest.apply"
local storage = require "ao.shared.storage"

local function send(msg)
  return write.route(msg)
end

local function apply_events()
  local out = storage.get("outbox_queue") or {}
  for _, ev in ipairs(out) do
    ingest.apply(ev.event or ev)
  end
end

-- Order + inventory + promo + session flow
local req_id = 0
local function rid()
  req_id = req_id + 1
  return "rid-" .. req_id
end

send { Action = "SetInventory", ["Request-Id"] = rid(), ["Actor-Role"] = "catalog-admin", ["Site-Id"] = "s1", Sku = "sku1", Quantity = 5 }
send { Action = "UpsertInventory", ["Request-Id"] = rid(), ["Actor-Role"] = "catalog-admin", payload = { siteId = "s1", sku = "sku1", quantity = 5, location = "wh1" } }
send { Action = "UpsertCoupon", ["Request-Id"] = rid(), ["Actor-Role"] = "catalog-admin", payload = { siteId = "s1", code = "PROMO10", type = "percent", value = 10, currency = "EUR" } }
send { Action = "CartAddItem", ["Request-Id"] = rid(), ["Actor-Role"] = "support", payload = { cartId = "c1", siteId = "s1", currency = "EUR", sku = "sku1", qty = 1, price = 100 } }
local order_resp = send {
  Action = "CreateOrder",
  ["Request-Id"] = rid(),
  ["Actor-Role"] = "support",
  payload = { cartId = "c1", siteId = "s1", customerId = "cust-hash" },
}
local order_id = (order_resp.payload or {}).orderId or "ord_c1"
send {
  Action = "UpsertOrderStatus",
  ["Request-Id"] = rid(),
  ["Actor-Role"] = "support",
  payload = { orderId = order_id, status = "paid" },
}

apply_events()

local catalog = require "ao.catalog.process"
local function assert_ok(resp)
  assert(resp.status == "OK", resp.message or "expected OK")
  return resp.payload
end

assert(assert_ok(catalog.route { Action = "GetInventory", ["Request-Id"] = rid(), ["Actor-Role"] = "support", ["Site-Id"] = "s1", Sku = "sku1" }).total == 5)
assert(assert_ok(catalog.route { Action = "GetOrder", ["Request-Id"] = rid(), ["Actor-Role"] = "support", ["Order-Id"] = order_id }).order.status == "paid")

print("ingest_smoke: ok")

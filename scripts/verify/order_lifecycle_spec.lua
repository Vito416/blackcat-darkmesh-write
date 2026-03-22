local process = require "ao.write.process"

local function now()
  return os.date "!%Y-%m-%dT%H:%M:%SZ"
end

local function ok(res, msg)
  assert(res.status == "OK", (msg or "expected OK") .. (" got %s"):format(res.status))
end

-- seed cart before any CreateOrder
local state = process._state()
state.carts["cart-1"] =
  { siteId = "s1", currency = "USD", items = { { sku = "s", qty = 1, price = 10 } } }

local res = process.route {
  action = "CreateOrder",
  requestId = "ord-1",
  actor = "user",
  tenant = "t1",
  role = "admin",
  nonce = "n1",
  timestamp = now(),
  signatureRef = "sig",
  payload = {
    orderId = "ord-1",
    siteId = "s1",
    currency = "USD",
    cartId = "cart-1",
    address = { country = "US" },
  },
}
ok(res, "create order")
local oid = res.payload.orderId

-- confirmed -> paid -> fulfilled valid path
ok(
  process.route {
    action = "UpsertOrderStatus",
    requestId = "ord-3",
    actor = "user",
    tenant = "t1",
    role = "admin",
    nonce = "n3",
    timestamp = now(),
    signatureRef = "sig",
    payload = { orderId = oid, status = "confirmed" },
  },
  "confirm"
)
ok(
  process.route {
    action = "UpsertOrderStatus",
    requestId = "ord-4",
    actor = "user",
    tenant = "t1",
    role = "admin",
    nonce = "n4",
    timestamp = now(),
    signatureRef = "sig",
    payload = { orderId = oid, status = "paid" },
  },
  "paid"
)
ok(
  process.route {
    action = "UpsertOrderStatus",
    requestId = "ord-5",
    actor = "user",
    tenant = "t1",
    role = "admin",
    nonce = "n5",
    timestamp = now(),
    signatureRef = "sig",
    payload = { orderId = oid, status = "fulfilled" },
  },
  "fulfilled"
)

-- invalid transition should fail: fulfilled -> confirmed
local invalid = process.route {
  action = "UpsertOrderStatus",
  requestId = "ord-6",
  actor = "user",
  tenant = "t1",
  role = "admin",
  nonce = "n6",
  timestamp = now(),
  signatureRef = "sig",
  payload = { orderId = oid, status = "confirmed" },
}
assert(invalid.status ~= "OK" and invalid.code == "INVALID_STATE", "invalid transition must fail")

print "order_lifecycle_spec: ok"

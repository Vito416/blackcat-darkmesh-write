local process = require "ao.write.process"

local state = process._state()
local seq = 0

local function reset()
  seq = 0
  state.orders = {}
  state.carts = {
    ["cart-1"] = {
      siteId = "site-1",
      currency = "USD",
      items = { { sku = "sku-1", qty = 1, price = 10 } },
    },
  }
end

local function run(action, payload, req)
  seq = seq + 1
  local reqId = req or ("req-" .. action .. "-" .. tostring(seq))
  return process.route {
    action = action,
    requestId = reqId,
    actor = "tester",
    role = "admin",
    tenant = "tenant-1",
    timestamp = tostring(os.time()),
    nonce = "n-" .. tostring(seq),
    signatureRef = "sig-" .. reqId,
    payload = payload,
  }
end

local function assert_ok(resp)
  assert(
    resp and resp.status == "OK",
    ("expected OK, got %s"):format(resp and resp.status or "nil")
  )
end

local function assert_err(resp, code)
  assert(
    resp and resp.status == "ERROR",
    ("expected ERROR, got %s"):format(resp and resp.status or "nil")
  )
  if code then
    assert(resp.code == code, ("expected code %s, got %s"):format(code, resp.code or "nil"))
  end
end

local function run_lifecycle()
  reset()
  local create = run(
    "CreateOrder",
    {
      cartId = "cart-1",
      customerId = "cust-1",
      siteId = "site-1",
      currency = "USD",
      orderId = "order-1",
    }
  )
  assert_ok(create)
  local orderId = create.payload.orderId
  local order = state.orders[orderId]
  assert(order.status == "draft", "initial status should be draft")
  assert(order.version == 1, "initial version should be 1")

  local bad = run("UpsertOrderStatus", { orderId = orderId, status = "fulfilled" })
  assert_err(bad, "INVALID_STATE")

  local confirm =
    run("UpsertOrderStatus", { orderId = orderId, status = "confirmed", expectedVersion = 1 })
  assert_ok(confirm)
  assert(state.orders[orderId].status == "confirmed")
  assert(state.orders[orderId].version == 2)

  local paid = run("UpsertOrderStatus", { orderId = orderId, status = "paid", expectedVersion = 2 })
  assert_ok(paid)
  assert(state.orders[orderId].status == "paid")
  assert(state.orders[orderId].version == 3)

  local fulfilled =
    run("UpsertOrderStatus", { orderId = orderId, status = "fulfilled", expectedVersion = 3 })
  assert_ok(fulfilled)
  assert(state.orders[orderId].status == "fulfilled")
  assert(state.orders[orderId].version == 4)

  local returned =
    run("UpsertOrderStatus", { orderId = orderId, status = "returned", expectedVersion = 4 })
  assert_ok(returned)
  assert(state.orders[orderId].status == "returned")
  assert(state.orders[orderId].version == 5)

  local refunded =
    run("UpsertOrderStatus", { orderId = orderId, status = "refunded", expectedVersion = 5 })
  assert_ok(refunded)
  assert(state.orders[orderId].status == "refunded")
  assert(state.orders[orderId].version == 6)

  local conflict =
    run("UpsertOrderStatus", { orderId = orderId, status = "refunded", expectedVersion = 1 })
  assert_err(conflict, "VERSION_CONFLICT")
end

run_lifecycle()

print "order lifecycle spec OK"

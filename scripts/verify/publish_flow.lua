package.path = table.concat({ '?.lua', '?/init.lua', 'ao/?.lua', 'ao/?/init.lua', package.path }, ';')
local write = require 'ao.write.process'

local function ok(res) return res and res.status == 'OK' end

-- Cart -> CreateOrder -> PublishPageVersion basic path
local cart_add = write.route({
  Action = 'CartAddItem',
  ['Request-Id'] = 'pf-0',
  ['Actor-Role'] = 'admin',
  nonce = 'npf0',
  ts = os.time(),
  payload = { cartId = 'cart_pf', siteId = 's1', currency = 'USD', sku = 'sku1', qty = 1, price = 1234 },
})
assert(ok(cart_add), 'CartAddItem failed')

local create = write.route({
  Action = 'CreateOrder',
  ['Request-Id'] = 'pf-1',
  ['Actor-Role'] = 'admin',
  nonce = 'npf1',
  ts = os.time(),
  payload = { orderId = 'ord_pf', cartId = 'cart_pf', siteId = 's1', total = 1234, currency = 'USD' },
})
assert(ok(create), 'CreateOrder failed')

local publish = write.route({
  Action = 'PublishPageVersion',
  ['Request-Id'] = 'pf-2',
  ['Actor-Role'] = 'admin',
  nonce = 'npf2',
  ts = os.time(),
  payload = { siteId = 's1', pageId = 'home', versionId = 'vpf', manifestTx = 'txpf' },
})
assert(ok(publish), 'PublishPageVersion failed')
print('publish_flow: ok')

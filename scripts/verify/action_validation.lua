-- luacheck: max_line_length 200
package.path = table.concat({ '?.lua', '?/init.lua', 'ao/?.lua', 'ao/?/init.lua', package.path }, ';')
local write = require 'ao.write.process'

local function expect_error(res)
  return res and res.status == 'ERROR'
end

local bad = write.route({ Action = 'PublishPageVersion', ['Request-Id'] = 'v1', ['Actor-Role'] = 'admin', nonce = 'n1', ts = os.time() })
assert(expect_error(bad), 'missing payload should error')

local ok = write.route({
  Action = 'PublishPageVersion',
  ['Request-Id'] = 'v2',
  ['Actor-Role'] = 'admin',
  actor = 'validator',
  tenant = 'tenant-1',
  nonce = 'n2',
  ts = os.time(),
  payload = { siteId = 's1', pageId = 'p1', versionId = 'v1', manifestTx = 'tx123' },
})
assert(ok.status == 'OK', 'publish validation should pass')

local bad_route = write.route({
  Action = 'UpsertRoute',
  ['Request-Id'] = 'v3',
  ['Actor-Role'] = 'admin',
  actor = 'validator',
  tenant = 'tenant-1',
  nonce = 'n3',
  ts = os.time(),
  payload = { siteId = 's1' },
})
assert(expect_error(bad_route), 'missing path/target should error')

local good_route = write.route({
  Action = 'UpsertRoute',
  ['Request-Id'] = 'v4',
  ['Actor-Role'] = 'admin',
  actor = 'validator',
  tenant = 'tenant-1',
  nonce = 'n4',
  ts = os.time(),
  payload = { siteId = 's1', path = '/p', target = 'page:p1' },
})
assert(good_route.status == 'OK', 'route validation should pass')

local bad_pay = write.route({
  Action = 'CreatePaymentIntent',
  ['Request-Id'] = 'v5',
  ['Actor-Role'] = 'admin',
  nonce = 'n5',
  ts = os.time(),
  payload = { orderId = 'o1' },
})
assert(expect_error(bad_pay), 'missing amount/currency should error')

local ok_pay = write.route({
  Action = 'CreatePaymentIntent',
  ['Request-Id'] = 'v6',
  ['Actor-Role'] = 'admin',
  nonce = 'n6',
  ts = os.time(),
  payload = { orderId = 'o1', amount = 1000, currency = 'USD' },
})
assert(ok_pay.status == 'OK', 'payment intent should pass')

local bad_provider = write.route({
  Action = 'ProviderWebhook',
  ['Request-Id'] = 'v7',
  ['Actor-Role'] = 'ops',
  nonce = 'n7',
  ts = os.time(),
  payload = { provider = 'stripe', eventType = 'payment', orderId = nil },
})
assert(expect_error(bad_provider), 'provider webhook needs target ids')

print('action_validation: ok')
-- luacheck: max_line_length 200
-- luacheck: max_line_length 200

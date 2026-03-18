package.path = table.concat({ '?.lua', '?/init.lua', 'ao/?.lua', 'ao/?/init.lua', package.path }, ';')
local write = require 'ao.write.process'

local function ok(res) return res and res.status == 'OK' end

-- CreateOrder -> PublishPageVersion basic path
local create = write.route({
  Action = 'CreateOrder',
  ['Request-Id'] = 'pf-1',
  ['Actor-Role'] = 'admin',
  nonce = 'npf1',
  ts = os.time(),
  payload = { orderId = 'ord_pf', siteId = 's1', total = 1234, currency = 'USD' },
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

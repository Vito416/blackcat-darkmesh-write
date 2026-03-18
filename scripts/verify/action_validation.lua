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
  nonce = 'n2',
  ts = os.time(),
  payload = { siteId = 's1', pageId = 'p1', versionId = 'v1', manifestTx = 'tx123' },
})
assert(ok.status == 'OK', 'publish validation should pass')

local bad_route = write.route({
  Action = 'UpsertRoute',
  ['Request-Id'] = 'v3',
  ['Actor-Role'] = 'admin',
  nonce = 'n3',
  ts = os.time(),
  payload = { siteId = 's1' },
})
assert(expect_error(bad_route), 'missing path/target should error')

local good_route = write.route({
  Action = 'UpsertRoute',
  ['Request-Id'] = 'v4',
  ['Actor-Role'] = 'admin',
  nonce = 'n4',
  ts = os.time(),
  payload = { siteId = 's1', path = '/p', target = 'page:p1' },
})
assert(good_route.status == 'OK', 'route validation should pass')
print('action_validation: ok')

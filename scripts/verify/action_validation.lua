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
print('action_validation: ok')
